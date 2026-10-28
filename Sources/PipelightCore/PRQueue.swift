import Foundation

/// A PR someone asked the app to keep an eye on: when its checks finish, it says so once (a
/// notification plus a dot on the menu bar icon) and leaves the queue when the PR is merged or closed.
public struct QueuedPR: Codable, Equatable, Sendable {
    public var ref: PRRef
    public var title: String
    public var author: String
    public var url: String
    public var addedAt: Date
    public var headSha: String
    public var checks: RunState?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// "<head sha>:<passed|failed>" of the last result announced, so each result of each push is
    /// announced once, and a re-run that flips it is announced again.
    public var announced: String?
    /// A result came in since the menu was last opened.
    public var unseen = false

    /// Starts watching. A result that's already there counts as announced: whoever added the PR saw it.
    public init(pr: PullRequest, repo: String, workflow: String?, now: Date) {
        ref = PRRef(repo: repo, number: pr.number)
        title = pr.title
        author = pr.author
        url = pr.url.isEmpty ? ref.url : pr.url
        addedAt = now
        headSha = pr.headSha
        apply(ChecksSummary(checks: pr.checks, workflow: workflow))
        announced = resultKey
    }

    /// Takes in a fresh look at the PR. Returns the notification to post when its checks just finished.
    public mutating func update(with pr: PullRequest, workflow: String?) -> Notice? {
        title = pr.title
        author = pr.author
        headSha = pr.headSha
        apply(ChecksSummary(checks: pr.checks, workflow: workflow))
        guard let key = resultKey, key != announced else { return nil }
        let fixed = announced?.hasSuffix(":\(RunState.failed.rawValue)") == true && checks == .passed
        announced = key
        unseen = true
        return Notice(queued: self, fixed: fixed)
    }

    private mutating func apply(_ summary: ChecksSummary) {
        checks = summary.state
        startedAt = summary.startedAt
        finishedAt = summary.finishedAt
    }

    private var resultKey: String? {
        guard let checks, checks == .passed || checks == .failed else { return nil }
        return "\(headSha):\(checks.rawValue)"
    }
}

extension Notice {
    /// "✅ orodruin-3 #5586 passou", for a PR in the queue. Always posted, with sound: someone asked for it.
    init(queued pr: QueuedPR, fixed: Bool) {
        let failed = pr.checks == .failed
        kind = failed ? .failed : fixed ? .fixed : .passed
        fromQueue = true
        title = failed ? "❌ \(pr.ref.shortName) quebrou" : fixed ? "✅ \(pr.ref.shortName) voltou a passar" : "✅ \(pr.ref.shortName) passou"
        var took: String?
        if let start = pr.startedAt, let end = pr.finishedAt {
            took = "CI em \(Format.duration(end.timeIntervalSince(start)))"
        }
        subtitle = [pr.author.isEmpty ? nil : "PR de \(pr.author)", took].compactMap { $0 }.joined(separator: " · ")
        body = pr.title
        url = pr.url
        identifier = "pr-\(pr.ref.id)-\(pr.announced ?? "")"
    }
}
