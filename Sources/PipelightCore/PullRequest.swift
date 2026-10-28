import Foundation

/// A pull request as `gh pr view --json <PullRequest.ghFields>` prints it.
public struct PullRequest: Decodable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    public var author: String
    /// OPEN, MERGED or CLOSED.
    public var state: String
    public var isDraft: Bool
    public var headSha: String
    public var checks: [Check]

    public static let ghFields = "number,title,url,author,state,isDraft,headRefOid,statusCheckRollup"

    enum CodingKeys: String, CodingKey {
        case number, title, url, author, state, isDraft, headRefOid, statusCheckRollup
    }

    struct Login: Decodable { let login: String }

    public init(
        number: Int, title: String, url: String = "", author: String = "", state: String = "OPEN",
        isDraft: Bool = false, headSha: String, checks: [Check]
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.headSha = headSha
        self.checks = checks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        author = try c.decodeIfPresent(Login.self, forKey: .author)?.login ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "OPEN"
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        headSha = try c.decodeIfPresent(String.self, forKey: .headRefOid) ?? ""
        checks = try c.decodeIfPresent([Check].self, forKey: .statusCheckRollup) ?? []
    }

    public static func decode(_ data: Data) throws -> PullRequest {
        try ghDecoder.decode(PullRequest.self, from: data)
    }

    public var isOpen: Bool { state == "OPEN" }
}

/// One entry of a PR's check rollup: a GitHub Actions job (CheckRun) or a commit status from
/// another service (StatusContext), folded into the same shape.
public struct Check: Decodable, Equatable, Sendable {
    public var name: String
    /// nil for commit statuses, which don't come from a workflow.
    public var workflowName: String?
    /// QUEUED, IN_PROGRESS, WAITING, PENDING, REQUESTED or COMPLETED.
    public var status: String
    /// SUCCESS, FAILURE, CANCELLED, SKIPPED… once COMPLETED.
    public var conclusion: String
    public var startedAt: Date?
    public var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", name, workflowName, status, conclusion, startedAt, completedAt, context, state
    }

    public init(
        name: String, workflowName: String? = nil, status: String = "COMPLETED", conclusion: String = "SUCCESS",
        startedAt: Date? = nil, completedAt: Date? = nil
    ) {
        self.name = name
        self.workflowName = workflowName
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = Self.real(try c.decodeIfPresent(Date.self, forKey: .startedAt))
        completedAt = Self.real(try c.decodeIfPresent(Date.self, forKey: .completedAt))
        if try c.decodeIfPresent(String.self, forKey: .typename) == "StatusContext" {
            name = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
            workflowName = nil
            switch try c.decodeIfPresent(String.self, forKey: .state) ?? "" {
            case "PENDING", "EXPECTED":
                status = "IN_PROGRESS"
                conclusion = ""
            case "SUCCESS":
                status = "COMPLETED"
                conclusion = "SUCCESS"
            default:
                status = "COMPLETED"
                conclusion = "FAILURE"
            }
        } else {
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            let workflow = try c.decodeIfPresent(String.self, forKey: .workflowName)
            workflowName = workflow?.isEmpty == false ? workflow : nil
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "COMPLETED"
            conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion) ?? ""
        }
    }

    /// gh prints 0001-01-01T00:00:00Z for "not yet".
    private static func real(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    public var state: RunState {
        switch status {
        case "COMPLETED":
            switch conclusion {
            case "SUCCESS": return .passed
            case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ERROR": return .failed
            case "CANCELLED": return .cancelled
            case "ACTION_REQUIRED": return .waiting
            default: return .neutral
            }
        case "QUEUED", "REQUESTED", "PENDING": return .queued
        case "WAITING": return .waiting
        default: return .running
        }
    }
}

/// What a PR's checks add up to.
public struct ChecksSummary: Equatable, Sendable {
    /// nil while the PR has no (matching) checks yet, e.g. right after a push.
    public var state: RunState?
    public var startedAt: Date?
    /// When the last check finished; nil while something still runs.
    public var finishedAt: Date?

    /// With a workflow name, only that workflow's jobs count, so CodeQL, linters and bots don't
    /// decide whether "the CI" passed. A workflow given as a file name (ci.yml) or id can't be matched
    /// against the rollup, so then every check counts.
    public init(checks: [Check], workflow: String?) {
        let byName = workflow.flatMap { Self.matchesByName($0) ? $0.lowercased() : nil }
        // A re-run or a second event leaves older entries for the same job: keep the newest.
        var latest: [String: Check] = [:]
        for check in checks where byName == nil || check.workflowName?.lowercased() == byName {
            let key = "\(check.workflowName ?? "")/\(check.name)"
            if let current = latest[key], (current.startedAt ?? .distantPast) > (check.startedAt ?? .distantPast) {
                continue
            }
            latest[key] = check
        }
        let relevant = Array(latest.values)
        let states = relevant.map(\.state)
        if relevant.isEmpty {
            state = nil
        } else if states.contains(.running) {
            state = .running
        } else if states.contains(.waiting) {
            state = .waiting
        } else if states.contains(.queued) {
            state = .queued
        } else if states.contains(.failed) {
            state = .failed
        } else if states.allSatisfy({ $0 == .cancelled }) {
            state = .cancelled
        } else {
            state = .passed
        }
        startedAt = relevant.compactMap(\.startedAt).min()
        finishedAt = state?.isActive == false ? relevant.compactMap(\.completedAt).max() : nil
    }

    private static func matchesByName(_ workflow: String) -> Bool {
        let lowered = workflow.lowercased()
        return !(lowered.hasSuffix(".yml") || lowered.hasSuffix(".yaml") || lowered.allSatisfy(\.isNumber))
    }
}

/// "owner/name#123": which PR, without anything about it.
public struct PRRef: Hashable, Codable, Sendable {
    public var repo: String
    public var number: Int

    public init(repo: String, number: Int) {
        self.repo = repo
        self.number = number
    }

    public var id: String { "\(repo.lowercased())#\(number)" }
    public var url: String { "https://github.com/\(repo)/pull/\(number)" }
    /// "orodruin-3 #5586".
    public var shortName: String { "\(repo.split(separator: "/").last.map(String.init) ?? repo) #\(number)" }

    /// The first PR in `text`: a github.com/owner/name/pull/123 link (any tab of it, inside any
    /// message) or "owner/name#123".
    public static func find(in text: String) -> PRRef? {
        let patterns = [#"github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)"#, #"(?<![\w./-])([\w.-]+)/([\w.-]+)#(\d+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let owner = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text),
                  let number = Range(match.range(at: 3), in: text).flatMap({ Int(text[$0]) })
            else { continue }
            return PRRef(repo: "\(text[owner])/\(text[name])", number: number)
        }
        return nil
    }
}

/// A PR offered in "Adicionar PR à fila", as `gh search prs --json <PRCandidate.ghFields>` prints it.
public struct PRCandidate: Decodable, Equatable, Sendable {
    public var ref: PRRef
    public var title: String
    public var author: String
    public var isDraft: Bool
    public var updatedAt: Date

    public static let ghFields = "number,title,repository,author,isDraft,updatedAt"

    enum CodingKeys: String, CodingKey { case number, title, repository, author, isDraft, updatedAt }
    struct Repository: Decodable { let nameWithOwner: String }

    public init(ref: PRRef, title: String, author: String, isDraft: Bool = false, updatedAt: Date) {
        self.ref = ref
        self.title = title
        self.author = author
        self.isDraft = isDraft
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = PRRef(repo: try c.decode(Repository.self, forKey: .repository).nameWithOwner,
                    number: try c.decode(Int.self, forKey: .number))
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(PullRequest.Login.self, forKey: .author)?.login ?? ""
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public static func decodeList(_ data: Data) throws -> [PRCandidate] {
        try ghDecoder.decode([PRCandidate].self, from: data)
    }
}

let ghDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()
