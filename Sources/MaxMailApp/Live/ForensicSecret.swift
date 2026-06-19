import Foundation
import CryptoKit

/// Per-installation 32-byte HMAC secret used to key the AuditLog HMAC
/// chain and ExportSigner manifest signatures. Persisted hex-encoded in
/// the Keychain so it survives reinstalls of the app inside the same
/// user account but is not portable to a different machine.
///
/// Why a separate type from the IMAP / JMAP password Keychain entries:
/// rotating this secret has different semantics — past audit entries
/// stop verifying once the secret changes. A separate namespace makes
/// the "rotate" action explicit and prevents accidental clobbering of
/// account passwords with `setSecret` calls.
enum ForensicSecret {

    private static let service = "maxmailin.forensic.hmac"
    private static let account = "default"

    /// Load the existing secret, or generate + persist a new one the
    /// first time we're asked. Returns the raw 32-byte key as `Data`.
    /// nil means the Keychain write failed (sandboxed environment,
    /// disk full, etc.) and the caller should fall back to a
    /// process-ephemeral secret rather than refusing to open the store.
    @discardableResult
    static func loadOrGenerate() -> Data? {
        if let existing = load() { return existing }
        let fresh = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let hex = fresh.map { String(format: "%02x", $0) }.joined()
        guard Keychain.setSecret(hex, service: service, account: account) else {
            return nil
        }
        return fresh
    }

    static func load() -> Data? {
        guard let hex = Keychain.getSecret(service: service, account: account) else {
            return nil
        }
        return Data(hexEncoded: hex)
    }

    /// Wipe the existing secret. The next `loadOrGenerate` will mint a
    /// new one. Existing audit entries cannot be verified after this —
    /// callers should warn the user before invoking.
    @discardableResult
    static func rotate() -> Data? {
        _ = Keychain.deleteSecret(service: service, account: account)
        return loadOrGenerate()
    }

    static var isConfigured: Bool { load() != nil }
}

private extension Data {
    init?(hexEncoded hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }
}
