import Foundation

/// A PR waiting to be published, that is, merged into its base branch. While a run goes on there
/// (someone else's deploy), it waits. When the run ends, the app says so: a notification plus a dot on
/// the menu bar icon, colored by the PR's own CI. The dot stays until the PR leaves the queue (merged
/// or closed) or another run takes the branch.
public struct QueuedPR: Codable, Equatable, Sendable {
    public var ref: PRRef
    public var title: String
    public var author: String
    public var url: String
    public var addedAt: Date
    /// The branch the PR merges into. nil in queues saved before the app asked, until the next look.
    public var base: String?
    /// Whether a run was going on the base branch at the last look; nil until that's known.
    public var baseBusy: Bool?
    public var headSha: String
    public var checks: RunState?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// "<head sha>:<passed|failed>" of the last result of the PR's CI announced, so each result of
    /// each push is announced once, and a re-run that flips it is announced again.
    public var announced: String?

    /// What the dot says once the base branch is free.
    public enum Signal: Comparable, Sendable {
        /// The PR's CI still runs (or hasn't started): wait a bit more.
        case checksRunning
        /// The PR's CI broke or was cancelled: fix it before merging.
        case checksFailed
        /// The PR's CI passed: merge it.
        case ready

        /// The dot of the menu bar: the most actionable one in the queue.
        public static func strongest(in queue: [QueuedPR]) -> Signal? {
            queue.compactMap(\.signal).max()
        }
    }

    /// nil while the base branch is busy (or not known yet): nothing to do but wait.
    public var signal: Signal? {
        guard baseBusy == false else { return nil }
        switch checks {
        case .passed: return .ready
        case .failed, .cancelled: return .checksFailed
        default: return .checksRunning
        }
    }

    /// Starts watching. A result of the PR's CI that's already there counts as announced: whoever
    /// added the PR saw it. `baseStatus` is the base branch's, when the app already knows it.
    public init(pr: PullRequest, repo: String, workflow: String?, baseStatus: BranchStatus?, now: Date) {
        ref = PRRef(repo: repo, number: pr.number)
        title = pr.title
        author = pr.author
        url = pr.url.isEmpty ? ref.url : pr.url
        addedAt = now
        base = pr.baseBranch
        baseBusy = baseStatus?.isActive
        headSha = pr.headSha
        apply(ChecksSummary(checks: pr.checks, workflow: workflow))
        announced = resultKey
    }

    /// Takes in a fresh look at the PR and at its base branch (nil when the branch couldn't be seen).
    /// Returns the notification to post: the base branch just got free, or, while it's free, the PR's
    /// CI just finished.
    public mutating func update(with pr: PullRequest, baseStatus: BranchStatus?, workflow: String?) -> Notice? {
        title = pr.title
        author = pr.author
        headSha = pr.headSha
        if pr.baseBranch != base {
            // Retargeted (or saved before the base was known): the old branch's runs say nothing here.
            base = pr.baseBranch
            baseBusy = nil
        }
        apply(ChecksSummary(checks: pr.checks, workflow: workflow))
        let wasBusy = baseBusy
        if let baseStatus {
            baseBusy = baseStatus.isActive
        }
        guard baseBusy == false else { return nil }
        let key = resultKey
        if wasBusy == true {
            announced = key ?? announced
            return Notice(freed: self, run: baseStatus?.headline)
        }
        guard let key, key != announced else { return nil }
        let fixed = announced?.hasSuffix(":\(RunState.failed.rawValue)") == true && checks == .passed
        announced = key
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

    /// "orodruin-3".
    var repoName: String {
        ref.repo.split(separator: "/").last.map(String.init) ?? ref.repo
    }
}

extension Notice {
    /// "✅ orodruin-3 · master passou", with "#5586 pronto para mergear" below: the run on a queued
    /// PR's base branch ended. Always posted, with sound: someone asked for it.
    init(freed pr: QueuedPR, run: WorkflowRun?) {
        let place = "\(pr.repoName) · \(pr.base ?? "")"
        switch run?.state {
        case .passed:
            kind = .passed
            title = "✅ \(place) passou"
        case .failed:
            kind = .failed
            title = "❌ \(place) quebrou"
        default:
            kind = .passed
            title = "\(place) liberou"
        }
        fromQueue = true
        let number = "#\(pr.ref.number)"
        switch pr.signal {
        case .ready: subtitle = "\(number) pronto para mergear"
        case .checksFailed: subtitle = pr.checks == .cancelled ? "\(number): CI do PR cancelado" : "\(number): CI do PR quebrou"
        default: subtitle = "\(number): CI do PR ainda rodando"
        }
        body = pr.title
        url = pr.url
        identifier = "pr-\(pr.ref.id)-freed-" + (run.map { "\($0.id)-\($0.attempt)" } ?? "")
    }

    /// "✅ orodruin-3 #5586 pronto para mergear": the PR's CI finished while its base branch is free.
    init(queued pr: QueuedPR, fixed: Bool) {
        let failed = pr.checks == .failed
        kind = failed ? .failed : fixed ? .fixed : .passed
        fromQueue = true
        title = failed ? "❌ \(pr.ref.shortName): CI do PR quebrou" : "✅ \(pr.ref.shortName) pronto para mergear"
        var took: String?
        if let start = pr.startedAt, let end = pr.finishedAt {
            took = (fixed ? "CI voltou a passar em " : "CI em ") + Format.duration(end.timeIntervalSince(start))
        }
        subtitle = [pr.base.map { "\($0) livre" }, took].compactMap { $0 }.joined(separator: " · ")
        body = pr.title
        url = pr.url
        identifier = "pr-\(pr.ref.id)-\(pr.announced ?? "")"
    }
}
