import AppKit
import PipelightCore

struct BranchState {
    var status: BranchStatus?
    /// Why the last request failed. The last good status stays on screen meanwhile.
    var error: String?
}

/// PRs offered in "Adicionar PR à fila".
struct PRCandidates {
    var mine: [PRCandidate] = []
    var reviewRequested: [PRCandidate] = []
    var loadedAt: Date?
    var error: String?
}

/// Keeps the config, the latest status of every branch and the PR queue, asking gh again on a
/// timer, after waking from sleep and whenever the menu opens with stale data.
@MainActor
final class Monitor {
    nonisolated static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pipelight", isDirectory: true)

    let configURL: URL
    let queueURL: URL
    private(set) var config = Config()
    /// Set while config.json can't be read (a typo while editing it by hand); the last good list stays.
    private(set) var configError: String?
    private(set) var states: [String: BranchState] = [:]
    private(set) var queue: [QueuedPR] = []
    /// Why the last look at a queued PR failed, by `PRRef.id`.
    private(set) var queueErrors: [String: String] = [:]
    private(set) var candidates = PRCandidates()
    private(set) var lastUpdate: Date?
    private(set) var isRefreshing = false
    private(set) var isLoadingCandidates = false

    var onChange: (() -> Void)?
    var onNotice: ((Notice) -> Void)?
    /// Off for PIPELIGHT_PRINT_MENU: a look from the side must not mark results as announced or seen.
    var savesQueue = true

    private var configDate: Date?
    private var tracker = CompletionTracker()
    private var timer: Timer?
    private var refreshAgain = false

    init(directory: URL = Monitor.defaultDirectory) {
        configURL = directory.appendingPathComponent("config.json")
        queueURL = directory.appendingPathComponent("queue.json")
        loadQueue()
    }

    var overall: Overall {
        Overall(config.targets.map { states[$0.id]?.status })
    }

    /// A queued PR finished since the menu was last opened: the menu bar icon shows a dot.
    var hasUnseen: Bool {
        queue.contains(where: \.unseen)
    }

    func start() {
        refresh()
        refreshCandidates()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network takes a moment to come back after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        timer?.invalidate()
        loadConfigIfChanged()
        let targets = config.targets
        let refs = queue.map(\.ref)
        isRefreshing = true
        onChange?()
        Task {
            async let branches = Self.fetch(targets) { try await GitHubCLI.runs(for: $0) }
            async let prs = Self.fetch(refs) { try await GitHubCLI.pullRequest($0) }
            let branchResults = await branches
            apply(branchResults)
            apply(await prs)
            finishRefresh(succeeded: targets.isEmpty || branchResults.contains { $0.1.isSuccess })
        }
    }

    /// Changes the config from the menu: saves config.json and asks gh about the new list right away.
    func update(_ change: (inout Config) -> Void) {
        var new = config
        change(&new)
        save(new)
        refresh()
    }

    // MARK: Branches

    private func apply(_ results: [(Target, Result<[WorkflowRun], Error>)]) {
        let current = Set(config.targets.map(\.id))
        for (target, result) in results where current.contains(target.id) {
            switch result {
            case .success(let runs):
                states[target.id] = BranchState(status: BranchStatus(runs: runs), error: nil)
                let repo = Config.Repo(repo: target.repo, branches: []).name
                for completion in tracker.completions(in: runs, target: target.id) {
                    if let notice = Notice(repo: repo, branch: target.branch, completion: completion) {
                        onNotice?(notice)
                    }
                }
            case .failure(let error):
                states[target.id, default: BranchState()].error = error.localizedDescription
            }
        }
    }

    private func finishRefresh(succeeded: Bool) {
        if succeeded {
            lastUpdate = Date()
        }
        isRefreshing = false
        if refreshAgain {
            refreshAgain = false
            refresh()
            return
        }
        scheduleNext()
        onChange?()
    }

    private func scheduleNext() {
        let running = config.targets.contains { states[$0.id]?.status?.state?.isActive == true }
            || queue.contains { $0.checks?.isActive ?? true }
        let interval = Polling.interval(targets: config.targets.count + queue.count, running: running)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval / 10
        // .common keeps it firing while the menu is open (menus track events in their own run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    nonisolated private static func fetch<Key: Sendable, Value: Sendable>(
        _ keys: [Key], _ load: @escaping @Sendable (Key) async throws -> Value
    ) async -> [(Key, Result<Value, Error>)] {
        await withTaskGroup(of: (Key, Result<Value, Error>).self) { group in
            for key in keys {
                group.addTask {
                    do {
                        return (key, .success(try await load(key)))
                    } catch {
                        return (key, .failure(error))
                    }
                }
            }
            var all: [(Key, Result<Value, Error>)] = []
            for await result in group {
                all.append(result)
            }
            return all
        }
    }

    // MARK: PR queue

    private func apply(_ results: [(PRRef, Result<PullRequest, Error>)]) {
        for (ref, result) in results {
            // Removed from the queue while gh was answering.
            guard let index = queue.firstIndex(where: { $0.ref.id == ref.id }) else { continue }
            switch result {
            case .success(let pr) where !pr.isOpen:
                queue.remove(at: index)
                queueErrors[ref.id] = nil
            case .success(let pr):
                queueErrors[ref.id] = nil
                if let notice = queue[index].update(with: pr, workflow: workflow(for: ref.repo)) {
                    onNotice?(notice)
                }
            case .failure(let error):
                queueErrors[ref.id] = error.localizedDescription
            }
        }
        if !results.isEmpty {
            saveQueue()
        }
    }

    /// Looks the PR up and starts watching it. Throws a short reason when it can't.
    func addToQueue(_ ref: PRRef) async throws {
        let pr = try await GitHubCLI.pullRequest(ref)
        guard pr.isOpen else {
            throw GitHubCLI.Failure.failed(pr.state == "MERGED" ? "esse PR já foi mergeado" : "esse PR está fechado")
        }
        // The link may spell the repo in another case; GitHub's URL has it right.
        let repo = PRRef.find(in: pr.url)?.repo ?? ref.repo
        guard !queue.contains(where: { $0.ref.id == ref.id }) else { return }
        queue.append(QueuedPR(pr: pr, repo: repo, workflow: workflow(for: repo), now: Date()))
        saveQueue()
        onChange?()
        refresh()
    }

    func removeFromQueue(_ filter: (QueuedPR) -> Bool) {
        queue.removeAll(where: filter)
        saveQueue()
        onChange?()
    }

    /// Opening the menu shows every result, so the dot goes away.
    func markQueueSeen() {
        guard hasUnseen else { return }
        for index in queue.indices {
            queue[index].unseen = false
        }
        saveQueue()
    }

    /// The repo's workflow from config.json, so a PR's "CI" is the same one watched on its branches.
    private func workflow(for repo: String) -> String? {
        config.repos.first { $0.repo.lowercased() == repo.lowercased() }?.workflow
    }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueURL) else { return }
        do {
            queue = try JSONDecoder().decode([QueuedPR].self, from: data)
        } catch {
            NSLog("Pipelight: failed to read \(queueURL.path): \(error)")
        }
    }

    private func saveQueue() {
        guard savesQueue else { return }
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(queue).write(to: queueURL, options: .atomic)
        } catch {
            NSLog("Pipelight: failed to write \(queueURL.path): \(error)")
        }
    }

    // MARK: PR candidates

    /// Your open PRs and the ones asking for your (or your team's) review, for the add-to-queue submenu.
    func refreshCandidates() {
        guard !isLoadingCandidates else { return }
        isLoadingCandidates = true
        Task {
            async let mine = GitHubCLI.searchPRs("--author=@me", limit: 8)
            async let review = GitHubCLI.searchPRs("--review-requested=@me", limit: 12)
            do {
                let (mine, review) = try await (mine, review)
                let own = Set(mine.map(\.ref.id))
                candidates = PRCandidates(mine: mine, reviewRequested: review.filter { !own.contains($0.ref.id) }, loadedAt: Date())
            } catch {
                candidates.error = error.localizedDescription
            }
            isLoadingCandidates = false
            onChange?()
        }
    }

    // MARK: Config file

    private func loadConfigIfChanged() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            save(Config())
            return
        }
        let date = modificationDate()
        guard date != configDate else { return }
        configDate = date
        do {
            setConfig(try Config.decode(Data(contentsOf: configURL)))
            configError = nil
        } catch {
            configError = "config.json inválido; o formato está no README"
            NSLog("Pipelight: failed to read \(configURL.path): \(error)")
        }
    }

    private func save(_ new: Config) {
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.encoded().write(to: configURL, options: .atomic)
        } catch {
            NSLog("Pipelight: failed to write \(configURL.path): \(error)")
        }
        configDate = modificationDate()
        configError = nil
        setConfig(new)
    }

    private func setConfig(_ new: Config) {
        let kept = Set(new.targets.map(\.id))
        for id in Array(states.keys) where !kept.contains(id) {
            states[id] = nil
            tracker.forget(target: id)
        }
        config = new
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
