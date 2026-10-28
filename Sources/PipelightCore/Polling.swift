import Foundation

/// How often to ask GitHub. Faster while something runs, so the end shows up soon; slower when idle.
/// With many branches the interval stretches to stay under ~2000 requests an hour, well below the
/// 5000 a GitHub token gets (gh's other uses share that budget).
public enum Polling {
    public static func interval(targets: Int, running: Bool) -> TimeInterval {
        let floor: TimeInterval = running ? 15 : 30
        return max(floor, Double(targets) * 3600 / 2000)
    }

    /// A short, friendly reason from gh's stderr.
    public static func explain(_ stderr: String) -> String {
        let text = stderr.lowercased()
        if text.contains("gh auth login") || text.contains("authentication") || text.contains("http 401") {
            return "gh sem login: rode gh auth login no Terminal"
        }
        if text.contains("could not find any workflows named") {
            return "workflow não encontrado nesse repositório"
        }
        if text.contains("could not resolve to a pullrequest") {
            return "PR não encontrado nesse repositório"
        }
        if text.contains("http 404") || text.contains("could not resolve to a repository") {
            return "repositório não encontrado (ou sem acesso)"
        }
        if text.contains("rate limit") {
            return "limite de requisições do GitHub atingido"
        }
        if ["error connecting", "dial tcp", "no such host", "i/o timeout", "network is unreachable", "tls handshake"]
            .contains(where: text.contains) {
            return "sem conexão com o GitHub"
        }
        let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "erro desconhecido do gh" : line
    }
}
