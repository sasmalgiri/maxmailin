import Foundation
import MaxMailCore

/// Single SwiftUI-friendly handle to every forensic engine: AuditLog,
/// ExportSigner, ChainOfCustodyManager, BatesNumberingManager, and the
/// GDPRAccessReportGenerator. Bound to one `MailStore` and one
/// per-installation HMAC secret.
///
/// Lifecycle: created in `MailViewModel.bootstrap` after the store
/// opens. If the Keychain write for the secret fails (sandbox, locked
/// keychain) we still create a coordinator using a process-ephemeral
/// secret so the UI doesn't crash — the user just sees a "secret not
/// persisted" warning in the Forensic settings pane.
///
/// All public methods are `@MainActor` so SwiftUI views can call them
/// directly; the underlying engines are actors and handle their own
/// concurrency.
@MainActor
final class ForensicCoordinator {

    let auditLog: AuditLog
    let exportSigner: ExportSigner
    let custody: ChainOfCustodyManager
    let bates: BatesNumberingManager
    let gdpr: GDPRAccessReportGenerator

    /// True when the secret used to instantiate the chain is the one
    /// stored in the Keychain (as opposed to a process-ephemeral fallback).
    let secretIsPersisted: Bool

    init(store: MailStore, secret: Data, secretIsPersisted: Bool) {
        self.auditLog = AuditLog(store: store, secret: secret)
        self.exportSigner = ExportSigner(secret: secret)
        self.custody = ChainOfCustodyManager(store: store, auditLog: auditLog)
        self.bates = BatesNumberingManager(store: store, auditLog: auditLog)
        self.gdpr = GDPRAccessReportGenerator(store: store, auditLog: auditLog)
        self.secretIsPersisted = secretIsPersisted
    }

    /// Build a coordinator paired with the given store, loading or
    /// generating the persistent HMAC secret. Returns nil only when
    /// nothing else has gone wrong but the caller passed a nil store
    /// (defensive — usually means bootstrap failed earlier).
    static func makeDefault(store: MailStore) -> ForensicCoordinator {
        if let persistent = ForensicSecret.loadOrGenerate() {
            return ForensicCoordinator(
                store: store, secret: persistent, secretIsPersisted: true
            )
        }
        // Keychain unavailable: fall back to a process-only secret so
        // the user can still seal / verify within this launch. Past
        // audit entries from a previous launch won't verify, but a
        // fresh install would have been the same situation anyway.
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 32, buf.baseAddress!)
        }
        return ForensicCoordinator(
            store: store, secret: Data(bytes), secretIsPersisted: false
        )
    }

    /// User-initiated secret rotation. Past audit chain verification
    /// will start failing — `AuditLog.verify()` will report the very
    /// first existing entry as tampered. UI must warn before calling.
    /// Returns a fresh coordinator the caller should swap in.
    static func rotate(store: MailStore) -> ForensicCoordinator {
        if let next = ForensicSecret.rotate() {
            return ForensicCoordinator(
                store: store, secret: next, secretIsPersisted: true
            )
        }
        return .makeDefault(store: store)
    }
}
