import Foundation

/// What a branch looks like right now, summed up from its recent runs (newest first, as gh lists them).
public struct BranchStatus: Equatable, Sendable {
    /// The run that best describes the branch: one still going, else one that failed, else the latest.
    /// Each workflow counts only with its latest run, so an old failure fixed since doesn't show.
    public var headline: WorkflowRun?
    /// While the headline is still going: the last finished run of the same workflow, so the menu can
    /// say whether the branch was green or broken before this push.
    public var previous: WorkflowRun?

    public init(runs: [WorkflowRun]) {
        // Skipped runs (an `if:` that didn't match) say nothing about the branch.
        let relevant = runs.filter { !($0.status == "completed" && $0.conclusion == "skipped") }
        var latest: [WorkflowRun] = []
        for run in relevant where !latest.contains(where: { $0.workflowName == run.workflowName }) {
            latest.append(run)
        }
        headline = latest.first(where: \.isActive) ?? latest.first(where: { $0.state == .failed }) ?? latest.first
        if let headline, headline.isActive {
            previous = relevant.first { $0.workflowName == headline.workflowName && $0.id != headline.id && !$0.isActive }
        }
    }

    public var state: RunState? { headline?.state }

    /// A run is going: queued, running or waiting for approval.
    public var isActive: Bool { headline?.isActive == true }
}

/// The single state the menu bar icon shows for every watched branch together.
public enum Overall: Equatable, Sendable {
    /// Nothing configured.
    case empty
    /// No branch answered yet (first load, or every request failed).
    case unknown
    case passed
    case failed
    /// Something is running; `failing` when another branch is broken meanwhile.
    case running(failing: Bool)

    public init(_ statuses: [BranchStatus?]) {
        guard !statuses.isEmpty else { self = .empty; return }
        let states = statuses.compactMap { $0?.state }
        let failing = states.contains(.failed)
        if states.contains(where: \.isActive) {
            self = .running(failing: failing)
        } else if failing {
            self = .failed
        } else if states.isEmpty {
            self = .unknown
        } else {
            self = .passed
        }
    }
}
