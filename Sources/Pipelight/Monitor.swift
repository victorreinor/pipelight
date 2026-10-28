import AppKit
import PipelightCore

struct BranchState {
    var status: BranchStatus?
    /// Why the last request failed. The last good status stays on screen meanwhile.
    var error: String?
}

/// Keeps the config and the latest status of every branch, asking gh again on a timer, after waking
/// from sleep and whenever the menu opens with stale data.
@MainActor
final class Monitor {
    nonisolated static let defaultConfigURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pipelight", isDirectory: true)
        .appendingPathComponent("config.json")

    let configURL: URL
    private(set) var config = Config()
    /// Set while config.json can't be read (a typo while editing it by hand); the last good list stays.
    private(set) var configError: String?
    private(set) var states: [String: BranchState] = [:]
    private(set) var lastUpdate: Date?
    private(set) var isRefreshing = false

    var onChange: (() -> Void)?
    var onNotice: ((Notice) -> Void)?

    private var configDate: Date?
    private var tracker = CompletionTracker()
    private var timer: Timer?
    private var refreshAgain = false

    init(configURL: URL = Monitor.defaultConfigURL) {
        self.configURL = configURL
    }

    var overall: Overall {
        Overall(config.targets.map { states[$0.id]?.status })
    }

    func start() {
        refresh()
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
        isRefreshing = true
        onChange?()
        Task {
            let results = await withTaskGroup(of: (Target, Result<[WorkflowRun], Error>).self) { group in
                for target in targets {
                    group.addTask {
                        do {
                            return (target, .success(try await GitHubCLI.runs(for: target)))
                        } catch {
                            return (target, .failure(error))
                        }
                    }
                }
                var all: [(Target, Result<[WorkflowRun], Error>)] = []
                for await result in group {
                    all.append(result)
                }
                return all
            }
            apply(results)
        }
    }

    /// Changes the config from the menu: saves config.json and asks gh about the new list right away.
    func update(_ change: (inout Config) -> Void) {
        var new = config
        change(&new)
        save(new)
        refresh()
    }

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
        if results.isEmpty || results.contains(where: { if case .success = $0.1 { true } else { false } }) {
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
        let interval = Polling.interval(targets: config.targets.count, running: running)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval / 10
        // .common keeps it firing while the menu is open (menus track events in their own run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
