import AppKit
import PipelightCore
import UserNotifications

/// Posts "passou / quebrou / voltou a passar" to Notification Center; clicking one opens the run.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var center: UNUserNotificationCenter { .current() }

    /// System Settings › Notifications › Pipelight.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.victorreinor.pipelight")!

    /// The last answer from macOS; nil until asked (or without a bundle).
    private(set) var status: UNAuthorizationStatus?

    var isOff: Bool { status == .denied }

    var statusDescription: String {
        switch status {
        case nil: return "unknown (no bundle)"
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .authorized: return "authorized"
        default: return "\(status!.rawValue)"
        }
    }

    func setUp(onStatus: @escaping () -> Void) {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Pipelight: notification authorization failed: \(error)")
            } else if !granted {
                NSLog("Pipelight: notifications are turned off in System Settings")
            }
            self.loadStatus(then: onStatus)
        }
    }

    /// Asks macOS again (people flip the switch in System Settings) and calls back on the main queue.
    func loadStatus(then done: @escaping () -> Void = {}) {
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.status = settings.authorizationStatus
                done()
            }
        }
    }

    func post(_ notice: Notice) {
        if notice.kind == .passed && !notice.fromQueue && !UserDefaults.standard.bool(forKey: StatusController.notifyPassedKey) {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.userInfo = ["url": notice.url]
        // A broken branch makes a sound; a green one just shows up. A queued PR always sounds: someone
        // asked to be told.
        if notice.kind == .failed || notice.fromQueue {
            content.sound = .default
        }
        center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)) { error in
            if let error {
                NSLog("Pipelight: failed to post notification: \(error)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    /// Show banners even if the app happens to be active (e.g. the add-repo alert is open).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
