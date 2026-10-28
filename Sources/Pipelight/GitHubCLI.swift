import Foundation
import PipelightCore

/// Talks to GitHub through the gh CLI, so the app reuses the login people already have (keychain
/// included) and never stores a token. Opened from Finder or at login, the app gets a bare PATH, so gh
/// is looked up in the usual install places, and gh's own children (`security`, for the keychain) get
/// a full PATH.
enum GitHubCLI {
    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "gh não encontrado: instale com brew install gh e rode gh auth login"
            case .failed(let reason): return reason
            }
        }
    }

    static let executable: URL? = {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.nix-profile/bin/gh",
                          "/run/current-system/sw/bin/gh", "\(home)/.local/bin/gh"]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        // Installed somewhere else: a login shell knows the user's PATH.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lc", "command -v gh"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        shell.waitUntilExit()
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }()

    static func runs(for target: Target) async throws -> [WorkflowRun] {
        try WorkflowRun.decodeList(try await run(target.ghArguments))
    }

    /// The repo as GitHub spells it ("owner/name") and its default branch. Fails when it doesn't exist
    /// or this login can't see it.
    static func repository(_ repo: String) async throws -> (name: String, defaultBranch: String) {
        struct Info: Decodable {
            struct Ref: Decodable { let name: String }
            let nameWithOwner: String
            let defaultBranchRef: Ref?
        }
        let data = try await run(["repo", "view", repo, "--json", "nameWithOwner,defaultBranchRef"])
        let info = try JSONDecoder().decode(Info.self, from: data)
        return (info.nameWithOwner, info.defaultBranchRef?.name ?? "main")
    }

    /// gh's stdout, or `Failure` with a short reason taken from its stderr.
    static func run(_ arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
        guard let executable else { throw Failure.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                                       "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
                environment["GH_PROMPT_DISABLED"] = "1"
                environment["GH_NO_UPDATE_NOTIFIER"] = "1"
                process.environment = environment
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                    return
                }
                let watchdog = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                watchdog.cancel()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: Failure.failed("o GitHub demorou demais para responder"))
                } else {
                    continuation.resume(throwing: Failure.failed(Polling.explain(errorText)))
                }
            }
        }
    }
}
