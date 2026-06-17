import Foundation
import UserNotifications

/// Tiny wrapper around UNUserNotificationCenter. The user opts in via a
/// toggle in JMAPSettingsView; we only post when both the toggle is on and
/// the system has granted authorization (or provisional authorization).
///
/// Notifications require a real .app bundle with a code-signed identifier —
/// running via `swift run maxmail-app` will get an authorization failure on
/// macOS, which we swallow silently so dev iterations still work.
enum MailNotifications {

    private static let enabledKey  = "maxmailin.notifications.enabled"
    private static let askedKey    = "maxmailin.notifications.asked"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Has the user been prompted at least once? Used to gate the toggle
    /// label in settings ("Allow…" vs "On").
    static var hasAsked: Bool {
        get { UserDefaults.standard.bool(forKey: askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedKey) }
    }

    static func currentStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    /// Returns true when the app can post notifications right now.
    /// Asks the system on first call; subsequent calls just inspect status.
    @discardableResult
    static func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            hasAsked = true
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                return false
            }
        case .ephemeral:
            return true
        @unknown default:
            return false
        }
    }

    /// Post a single notification summarizing N newly synced messages.
    /// `exampleSender` is the human-readable origin of the newest one and
    /// gives the body its punch line.
    static func postNewMail(count: Int, exampleSender: String?) async {
        guard enabled, count > 0 else { return }
        let authorized = await ensureAuthorized()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "maxmailin"
        if count == 1 {
            if let s = exampleSender, !s.isEmpty {
                content.body = "1 new message from \(s)"
            } else {
                content.body = "1 new message"
            }
        } else {
            if let s = exampleSender, !s.isEmpty {
                content.body = "\(count) new messages — most recent from \(s)"
            } else {
                content.body = "\(count) new messages"
            }
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // immediate delivery
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
