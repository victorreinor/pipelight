import Foundation

/// The watched repos, in `~/Library/Application Support/Pipelight/config.json`. The menu edits it, and
/// people can too: the app rereads it whenever the file changes.
public struct Config: Codable, Equatable, Sendable {
    public struct Repo: Codable, Equatable, Sendable {
        /// "owner/name".
        public var repo: String
        public var branches: [String]
        /// Only this workflow (its name, file name or id); nil watches every workflow on the branch.
        public var workflow: String?

        public init(repo: String, branches: [String], workflow: String? = nil) {
            self.repo = repo
            self.branches = branches
            self.workflow = workflow
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repo = try c.decode(String.self, forKey: .repo)
            branches = try c.decodeIfPresent([String].self, forKey: .branches) ?? ["main"]
            let workflow = try c.decodeIfPresent(String.self, forKey: .workflow)?.trimmingCharacters(in: .whitespaces)
            self.workflow = workflow?.isEmpty == false ? workflow : nil
        }

        /// "api" for "acme/api".
        public var name: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    }

    public var repos: [Repo]

    public init(repos: [Repo] = []) {
        self.repos = repos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repos = try c.decodeIfPresent([Repo].self, forKey: .repos) ?? []
    }

    /// One entry per repo and branch, in the config's order.
    public var targets: [Target] {
        repos.flatMap { repo in
            repo.branches.map { Target(repo: repo.repo, branch: $0, workflow: repo.workflow) }
        }
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// One branch of one repo: what each `gh run list` call asks about.
public struct Target: Hashable, Sendable {
    public var repo: String
    public var branch: String
    public var workflow: String?

    public init(repo: String, branch: String, workflow: String? = nil) {
        self.repo = repo
        self.branch = branch
        self.workflow = workflow
    }

    public var id: String { "\(repo)@\(branch)#\(workflow ?? "")" }

    /// With one workflow, a few runs are enough to find the previous result; with all of them, more
    /// are needed to see the latest run of each.
    public var ghArguments: [String] {
        var args = ["run", "list", "--repo", repo, "--branch", branch, "--limit", workflow == nil ? "20" : "5",
                    "--json", WorkflowRun.ghFields]
        if let workflow { args += ["--workflow", workflow] }
        return args
    }

    public var actionsURL: String {
        let query = "branch:\(branch)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
        return "https://github.com/\(repo)/actions?query=\(query)"
    }
}

public enum RepoInput {
    /// "owner/name" from what people paste: "owner/name", a github.com URL (any page of the repo) or an
    /// SSH/HTTPS clone address. nil when it doesn't look like a GitHub repo.
    public static func parse(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://", "http://", "www.", "github.com/"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard [parts[0], name].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return nil
        }
        return "\(parts[0])/\(name)"
    }

    /// "master, homolog" or "master homolog" → ["master", "homolog"], without repeats.
    public static func branches(_ input: String) -> [String] {
        var result: [String] = []
        for branch in input.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        where !result.contains(branch) {
            result.append(branch)
        }
        return result
    }
}
