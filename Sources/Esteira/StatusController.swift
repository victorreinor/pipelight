import AppKit
import EsteiraCore

/// The menu bar item: the icon sums up every branch (spinning while something runs) and the menu
/// lists each one. The menu is rebuilt right before it opens and on every update while it's open.
@MainActor
final class StatusController: NSObject, NSMenuDelegate {
    nonisolated static let notifyPassedKey = "notifyPassed"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let monitor: Monitor
    private var menuIsOpen = false
    private var spinTimer: Timer?
    private var spinFrame = 0

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityLabel("Esteira")
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
        item.button?.image = StatusIcons.menuBar(overall, frame: spinFrame)
        item.button?.toolTip = tooltip(overall)
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
                self.item.button?.image = StatusIcons.menuBar(self.monitor.overall, frame: self.spinFrame)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spinTimer = timer
    }

    private func tooltip(_ overall: Overall) -> String {
        switch overall {
        case .empty: return "Esteira: nenhum repositório"
        case .unknown: return "Esteira: carregando…"
        case .passed: return "Esteira: tudo verde"
        case .failed: return "Esteira: algo quebrou"
        case .running(let failing): return failing ? "Esteira: rodando, e algo está quebrado" : "Esteira: rodando"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        Notifier.shared.loadStatus { [weak self] in self?.update() }
        if (monitor.lastUpdate?.timeIntervalSinceNow ?? -.infinity) < -10 {
            monitor.refresh()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        let model = MenuModel(
            config: monitor.config, states: monitor.states, lastUpdate: monitor.lastUpdate,
            isRefreshing: monitor.isRefreshing, configError: monitor.configError,
            notifyPassed: UserDefaults.standard.bool(forKey: Self.notifyPassedKey), opensAtLogin: LoginItem.isEnabled,
            notificationsOff: Notifier.shared.isOff)
        menu.items = MenuBuilder.items(for: model, target: self)
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
