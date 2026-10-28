import Foundation

/// Finds the runs that finished since the last look, so each one is announced once.
///
/// The first look at a branch only takes note of what's there: opening the app (or adding a repo)
/// doesn't announce old results. After that, any finished run not seen finished before is new,
/// including one that started and ended between two looks, and a re-run (same id, next attempt).
public struct CompletionTracker: Sendable {
    private var seen: Set<RunKey> = []
    private var primed: Set<String> = []

    public init() {}

    /// `runs` is the branch's recent list, newest first.
    public mutating func completions(in runs: [WorkflowRun], target: String) -> [Completion] {
        var found: [Completion] = []
        for (index, run) in runs.enumerated() where !run.isActive && !seen.contains(run.key) {
            seen.insert(run.key)
            guard primed.contains(target) else { continue }
            let previous = runs[(index + 1)...].first {
                $0.workflowName == run.workflowName && !$0.isActive && ($0.state == .passed || $0.state == .failed)
            }
            found.append(Completion(run: run, previous: previous))
        }
        primed.insert(target)
        return found
    }

    /// Forgets a branch that left the config, so adding it back doesn't announce its history.
    public mutating func forget(target: String) {
        primed.remove(target)
    }
}

public struct Completion: Equatable, Sendable {
    public var run: WorkflowRun
    /// The finished run of the same workflow before this one, if it passed or failed.
    public var previous: WorkflowRun?
}
