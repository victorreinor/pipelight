import Foundation

/// One GitHub Actions run, as printed by `gh run list --json <WorkflowRun.ghFields>`.
public struct WorkflowRun: Codable, Equatable, Sendable {
    public var id: Int
    public var attempt: Int
    public var workflowName: String
    public var title: String
    /// queued, in_progress, waiting, requested, pending or completed.
    public var status: String
    /// Empty until the run completes; then success, failure, cancelled, skipped, timed_out…
    public var conclusion: String
    public var createdAt: Date
    public var startedAt: Date
    public var updatedAt: Date
    public var url: String

    public static let ghFields = "databaseId,attempt,workflowName,displayTitle,status,conclusion,createdAt,startedAt,updatedAt,url"

    enum CodingKeys: String, CodingKey {
        case id = "databaseId", attempt, workflowName, title = "displayTitle", status, conclusion
        case createdAt, startedAt, updatedAt, url
    }

    public init(
        id: Int, attempt: Int = 1, workflowName: String, title: String, status: String, conclusion: String = "",
        createdAt: Date, startedAt: Date? = nil, updatedAt: Date? = nil, url: String = ""
    ) {
        self.id = id
        self.attempt = attempt
        self.workflowName = workflowName
        self.title = title
        self.status = status
        self.conclusion = conclusion
        self.createdAt = createdAt
        self.startedAt = startedAt ?? createdAt
        self.updatedAt = updatedAt ?? self.startedAt
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 1
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decode(String.self, forKey: .status)
        conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? createdAt
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? startedAt
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    public static func decodeList(_ data: Data) throws -> [WorkflowRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([WorkflowRun].self, from: data)
    }

    public var state: RunState {
        switch status {
        case "completed":
            switch conclusion {
            case "success": return .passed
            case "failure", "timed_out", "startup_failure": return .failed
            case "cancelled": return .cancelled
            case "action_required": return .waiting
            default: return .neutral
            }
        case "queued", "requested", "pending": return .queued
        case "waiting", "action_required": return .waiting
        default: return .running
        }
    }

    public var isActive: Bool { status != "completed" }

    /// A re-run keeps the run id and bumps the attempt, so both identify one execution.
    public var key: RunKey { RunKey(id: id, attempt: attempt) }

    /// How long it ran, or has been running.
    public func duration(now: Date) -> TimeInterval {
        max(0, (isActive ? now : updatedAt).timeIntervalSince(startedAt))
    }
}

public struct RunKey: Hashable, Sendable {
    public var id: Int
    public var attempt: Int
}

public enum RunState: Equatable, Sendable {
    case queued, running, waiting, passed, failed, cancelled, neutral

    public var isActive: Bool { self == .queued || self == .running || self == .waiting }
}
