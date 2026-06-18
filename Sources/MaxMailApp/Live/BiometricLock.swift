import Foundation
import LocalAuthentication

/// Touch ID / Face ID / device-password gate.
///
/// Wraps Apple's LocalAuthentication. The store remembers whether the user
/// has opted in; the lock decision itself is made fresh at each app launch
/// or after the app has been backgrounded for `relockAfterSeconds`.
enum BiometricLock {

    enum Availability: Sendable {
        case touchID
        case faceID
        case watch        // macOS unlock via Apple Watch
        case devicePassword
        case unavailable(String)
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Re-lock window. After this many seconds in the background, the
    /// next foreground requires another biometric prompt.
    static var relockAfterSeconds: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: relockKey)
            return v > 0 ? v : 300   // default: 5 minutes
        }
        set { UserDefaults.standard.set(newValue, forKey: relockKey) }
    }

    /// What kind of authentication will the device offer? Used to pick
    /// the icon / label in the Settings sheet.
    static func availability() -> Availability {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "Device cannot authenticate")
        }
        switch ctx.biometryType {
        case .touchID:    return .touchID
        case .faceID:     return .faceID
        case .opticID:    return .faceID    // Vision Pro — render as Face ID-ish
        case .none:       return .devicePassword
        @unknown default: return .devicePassword
        }
    }

    /// Run the system unlock prompt. Returns true on success, false on
    /// user cancel / failure. The reason string is shown in the prompt.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use device password"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                localizedReason: reason)
        } catch {
            return false
        }
    }

    // MARK: - Persistence keys
    private static let enabledKey = "maxmailin.biometric.enabled"
    private static let relockKey  = "maxmailin.biometric.relockSeconds"
}
