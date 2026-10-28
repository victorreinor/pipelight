import Foundation
import ServiceManagement

/// "Abrir ao iniciar o Mac": the same switch as System Settings › General › Login Items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Pipelight: failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }

    /// Turned on once, on the first run from an installed .app; after that it's the user's call.
    static func enableOnFirstRun() {
        let key = "loginItemConfigured"
        guard Bundle.main.bundleURL.pathExtension == "app", !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }
}
