import Foundation

/// Short pt-BR texts for the menu and the notifications.
public enum Format {
    /// "agora", "há 5 min", "há 2 h", "há 3 dias".
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "agora"
        case ..<3600: return "há \(Int(seconds / 60)) min"
        case ..<86_400: return "há \(Int(seconds / 3600)) h"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "há 1 dia" : "há \(days) dias"
        }
    }

    /// "40 s", "6 min", "1 h 05 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        switch total {
        case ..<60: return "\(total) s"
        case ..<3600: return "\(total / 60) min"
        default:
            let minutes = (total % 3600) / 60
            return minutes == 0 ? "\(total / 3600) h" : "\(total / 3600) h \(String(format: "%02d", minutes)) min"
        }
    }

    /// Cuts at a word boundary near `limit` characters and adds "…".
    public static func truncate(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.count > limit else { return line }
        var cut = String(line.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// What a queued PR's checks are doing: "rodando há 4 min", "passou · há 2 min".
    public static func summary(of pr: QueuedPR, now: Date) -> String {
        switch pr.checks {
        case nil: return "esperando os checks"
        case .queued: return "na fila"
        case .running: return "rodando há \(duration(now.timeIntervalSince(pr.startedAt ?? now)))"
        case .waiting: return "aguardando aprovação"
        case .passed: return pr.finishedAt.map { "passou · \(ago($0, now: now))" } ?? "passou"
        case .failed: return pr.finishedAt.map { "quebrou · \(ago($0, now: now))" } ?? "quebrou"
        case .cancelled: return "cancelado"
        case .neutral: return "sem checks"
        }
    }

    /// What a branch is doing, for the first line of its menu item: "passou em 6 min · há 12 min".
    public static func summary(of run: WorkflowRun, now: Date) -> String {
        let took = duration(run.duration(now: now))
        switch run.state {
        case .queued: return "na fila há \(duration(now.timeIntervalSince(run.createdAt)))"
        case .running: return "rodando há \(took)"
        case .waiting: return "aguardando aprovação"
        case .passed: return "passou em \(took) · \(ago(run.updatedAt, now: now))"
        case .failed: return "quebrou em \(took) · \(ago(run.updatedAt, now: now))"
        case .cancelled: return "cancelado · \(ago(run.updatedAt, now: now))"
        case .neutral: return "\(run.conclusion) · \(ago(run.updatedAt, now: now))"
        }
    }
}
