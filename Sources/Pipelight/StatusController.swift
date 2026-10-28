import AppKit
import PipelightCore

/// The menu bar item: the icon sums up every branch (spinning while something runs, with a dot when
/// a queued PR's base branch is free) and the menu lists the queue and each branch. The menu is rebuilt right
/// before it opens and on every update while it's open; the add-PR submenu, each time it opens.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    nonisolated static let notifyPassedKey = "notifyPassed"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let monitor: Monitor
    private var menuIsOpen = false
    private weak var addPRMenu: NSMenu?
    private var spinTimer: Timer?
    private var spinFrame = 0

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityLabel("Pipelight")
        update()
    }

    func update() {
        updateIcon()
        if menuIsOpen {
            rebuildMenu()
        }
    }

    // MARK: Icon

    private func updateIcon() {
        let overall = monitor.overall
        item.button?.image = StatusIcons.menuBar(overall, frame: spinFrame, badge: monitor.queueSignal)
        item.button?.toolTip = tooltip(overall) + (monitor.queueSignal.map(queueTooltip) ?? "")
        if case .running = overall {
            startSpinning()
        } else {
            spinTimer?.invalidate()
            spinTimer = nil
            spinFrame = 0
        }
    }

    private func startSpinning() {
        guard spinTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / Double(StatusIcons.spinFrames), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.spinFrame = (self.spinFrame + 1) % StatusIcons.spinFrames
                self.item.button?.image = StatusIcons.menuBar(self.monitor.overall, frame: self.spinFrame,
                                                              badge: self.monitor.queueSignal)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spinTimer = timer
    }

    private func tooltip(_ overall: Overall) -> String {
        switch overall {
        case .empty: return "Pipelight: nenhum repositório"
        case .unknown: return "Pipelight: carregando…"
        case .passed: return "Pipelight: tudo verde"
        case .failed: return "Pipelight: algo quebrou"
        case .running(let failing): return failing ? "Pipelight: rodando, e algo está quebrado" : "Pipelight: rodando"
        }
    }

    private func queueTooltip(_ signal: QueuedPR.Signal) -> String {
        switch signal {
        case .ready: return " · PR da fila pronto para mergear"
        case .checksRunning: return " · branch livre, CI do PR da fila ainda rodando"
        case .checksFailed: return " · branch livre, CI do PR da fila quebrou"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === addPRMenu {
            menu.items = MenuBuilder.addPRItems(for: model(), target: self)
        } else if menu === self.menu {
            rebuildMenu()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = true
        Notifier.shared.loadStatus { [weak self] in self?.update() }
        if (monitor.lastUpdate?.timeIntervalSinceNow ?? -.infinity) < -10 {
            monitor.refresh()
        }
        if (monitor.candidates.loadedAt?.timeIntervalSinceNow ?? -.infinity) < -60 {
            monitor.refreshCandidates()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu {
            menuIsOpen = false
        }
    }

    private func model() -> MenuModel {
        MenuModel(
            config: monitor.config, states: monitor.states, lastUpdate: monitor.lastUpdate,
            isRefreshing: monitor.isRefreshing, configError: monitor.configError,
            notifyPassed: UserDefaults.standard.bool(forKey: Self.notifyPassedKey), opensAtLogin: LoginItem.isEnabled,
            notificationsOff: Notifier.shared.isOff, queue: monitor.queue, queueErrors: monitor.queueErrors,
            candidates: monitor.candidates)
    }

    private func rebuildMenu() {
        menu.items = MenuBuilder.items(for: model(), target: self)
        addPRMenu = menu.items.first { $0.tag == MenuBuilder.addPRTag }?.submenu
        addPRMenu?.delegate = self
    }

    // MARK: Actions

    @objc func openLink(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? String, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func refreshNow() {
        monitor.refresh()
    }

    @objc func addRepo() {
        Task { await askForRepo(AddRepoDialog.Input(), problem: nil) }
    }

    private func askForRepo(_ previous: AddRepoDialog.Input, problem: String?) async {
        guard let input = AddRepoDialog.ask(previous, problem: problem) else { return }
        guard let typed = RepoInput.parse(input.repo) else {
            await askForRepo(input, problem: "Não entendi o repositório. Use dono/nome ou o endereço do GitHub.")
            return
        }
        do {
            let repo = try await GitHubCLI.repository(typed)
            let workflow = input.workflow.trimmingCharacters(in: .whitespaces)
            if !workflow.isEmpty {
                _ = try await GitHubCLI.run(["run", "list", "--repo", repo.name, "--workflow", workflow, "--limit", "1", "--json", "status"])
            }
            var branches = RepoInput.branches(input.branches)
            if branches.isEmpty {
                branches = [repo.defaultBranch]
            }
            let entry = Config.Repo(repo: repo.name, branches: branches, workflow: workflow.isEmpty ? nil : workflow)
            monitor.update { config in
                if let index = config.repos.firstIndex(where: { $0.repo.lowercased() == repo.name.lowercased() }) {
                    config.repos[index] = entry
                } else {
                    config.repos.append(entry)
                }
            }
        } catch {
            await askForRepo(input, problem: "\(typed): \(error.localizedDescription).")
        }
    }

    // MARK: PR queue

    @objc func pastePRLink() {
        Task { await askForPR("", problem: nil) }
    }

    private func askForPR(_ previous: String, problem: String?) async {
        guard let text = AddPRDialog.ask(previous, problem: problem) else { return }
        guard let ref = PRRef.find(in: text) else {
            await askForPR(text, problem: "Não achei um link de PR aí. Ele é assim: https://github.com/dono/repo/pull/123")
            return
        }
        do {
            try await monitor.addToQueue(ref)
        } catch {
            await askForPR(text, problem: "\(ref.shortName): \(error.localizedDescription).")
        }
    }

    /// A PR picked in the add-PR submenu: in if it's out, out if it's in.
    @objc func toggleQueuedPR(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let ref = PRRef.find(in: text) else { return }
        if monitor.queue.contains(where: { $0.ref.id == ref.id }) {
            monitor.removeFromQueue { $0.ref.id == ref.id }
            return
        }
        Task {
            do {
                try await monitor.addToQueue(ref)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Não deu para adicionar \(ref.shortName)"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func removeQueuedPR(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        monitor.removeFromQueue { $0.ref.id == id }
    }

    @objc func removePassedPRs() {
        monitor.removeFromQueue { $0.checks == .passed }
    }

    @objc func clearQueue() {
        monitor.removeFromQueue { _ in true }
    }

    // MARK: Repos and settings

    @objc func removeRepo(_ sender: NSMenuItem) {
        guard let repo = sender.representedObject as? String else { return }
        monitor.update { $0.repos.removeAll { $0.repo == repo } }
    }

    @objc func editConfig() {
        let url = monitor.configURL
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc func openNotificationSettings() {
        NSWorkspace.shared.open(Notifier.settingsURL)
    }

    @objc func toggleNotifyPassed() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Self.notifyPassedKey), forKey: Self.notifyPassedKey)
    }

    @objc func toggleOpenAtLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }
}
