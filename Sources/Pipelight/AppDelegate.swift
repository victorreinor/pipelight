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

    /// Development aid: `PIPELIGHT_PRINT_MENU=1 Pipelight` asks gh once, prints the menu as text and quits,
    /// so the real data can be checked without seeing the menu bar. No status item, no notifications.
    private func printMenuOnce() {
        monitor = Monitor()
        monitor.onChange = { [unowned self] in
            guard !monitor.isRefreshing else { return }
            let model = MenuModel(
                config: monitor.config, states: monitor.states, lastUpdate: monitor.lastUpdate, isRefreshing: false,
                configError: monitor.configError, notifyPassed: true, opensAtLogin: LoginItem.isEnabled,
                notificationsOff: Notifier.shared.isOff)
            print("Overall: \(monitor.overall)")
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
    }
}
