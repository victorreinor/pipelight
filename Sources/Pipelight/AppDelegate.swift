import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor!
    private var statusController: StatusController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 14.4, *), let directory = ProcessInfo.processInfo.environment["PIPELIGHT_SNAPSHOT_DIR"] {
            Snapshot.render(into: directory)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["PIPELIGHT_PRINT_MENU"] != nil {
            printMenuOnce()
            return
        }
        UserDefaults.standard.register(defaults: [StatusController.notifyPassedKey: true])
        LoginItem.enableOnFirstRun()
        installEditMenu()
        // UNUserNotificationCenter needs a bundle; `swift run` has none.
        if Bundle.main.bundleIdentifier != nil {
            Notifier.shared.setUp { [weak self] in self?.statusController?.update() }
        }

        monitor = Monitor()
        statusController = StatusController(monitor: monitor)
        monitor.onChange = { [weak self] in self?.statusController.update() }
        monitor.onNotice = { notice in
            if Bundle.main.bundleIdentifier != nil {
                Notifier.shared.post(notice)
            }
        }
        monitor.start()
    }

    /// ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z in the dialogs' fields are key equivalents of the Edit menu: without a
    /// main menu they go nowhere. A menu bar-only app never shows this menu, but the shortcuts work.
    private func installEditMenu() {
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        // The first item is always the app menu.
        main.addItem(withTitle: "Pipelight", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Pipelight")
        main.addItem(withTitle: "Editar", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }

    /// Development aid: `PIPELIGHT_PRINT_MENU=1 Pipelight` asks gh once, prints the menu as text (submenus
    /// included) and quits, so the real data can be checked without seeing the menu bar. No status item,
    /// no notifications, nothing saved. `PIPELIGHT_DATA_DIR=dir` reads config.json and queue.json from
    /// `dir` instead of Application Support.
    private func printMenuOnce() {
        let directory = ProcessInfo.processInfo.environment["PIPELIGHT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        monitor = Monitor(directory: directory ?? Monitor.defaultDirectory)
        monitor.savesQueue = false
        monitor.onChange = { [unowned self] in
            guard !monitor.isRefreshing, !monitor.isLoadingCandidates else { return }
            let model = MenuModel(
                config: monitor.config, states: monitor.states, lastUpdate: monitor.lastUpdate, isRefreshing: false,
                configError: monitor.configError, notifyPassed: true, opensAtLogin: LoginItem.isEnabled,
                notificationsOff: Notifier.shared.isOff, queue: monitor.queue, queueErrors: monitor.queueErrors,
                candidates: monitor.candidates)
            print("Overall: \(monitor.overall)")
            print("Queue dot: \(monitor.queueSignal.map { "\($0)" } ?? "none")")
            print("Notifications: \(Notifier.shared.statusDescription)")
            print(MenuBuilder.text(MenuBuilder.items(for: model, target: nil)))
            exit(0)
        }
        if Bundle.main.bundleIdentifier != nil {
            Notifier.shared.loadStatus()
        }
        // Never linger as a second copy of the app if gh hangs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(1) }
        monitor.refresh()
        monitor.refreshCandidates()
    }
}
