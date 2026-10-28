import Foundation

/// The text of the notification for a finished run.
public struct Notice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case passed, fixed, failed }

    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var body: String
    public var url: String
    /// Stable per run and attempt, so the same result never stacks twice.
    public var identifier: String

    /// nil for results that aren't worth a notification (cancelled, skipped).
    public init?(repo: String, branch: String, completion: Completion) {
        let run = completion.run
        switch run.state {
        case .passed:
            kind = completion.previous?.state == .failed ? .fixed : .passed
        case .failed:
            kind = .failed
        default:
            return nil
        }
        let place = "\(repo) · \(branch)"
        switch kind {
        case .passed: title = "✅ \(place) passou"
        case .fixed: title = "✅ \(place) voltou a passar"
        case .failed: title = "❌ \(place) quebrou"
        }
        subtitle = [run.workflowName, Format.duration(run.duration(now: run.updatedAt))]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        body = run.title
        url = run.url
        identifier = "\(run.id)-\(run.attempt)"
    }
}
