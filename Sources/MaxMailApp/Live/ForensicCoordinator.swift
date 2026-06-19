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

    // MARK: - Case bundle export

    /// Write `audit.csv` + `BatesIndex.csv` into `bundleRoot` and seal
    /// them under one signed manifest. Used by the Forensic settings
    /// pane's "Export full case bundle" button. A bundle produced this
    /// way is the artifact you'd hand over for end-of-matter archival.
    /// Records its own `case_bundle_exported` audit entry.
    func exportFullCaseBundle(
        store: MailStore,
        actor: String,
        bundleName: String,
        bundleRoot: URL
    ) async throws {
        try FileManager.default.createDirectory(
            at: bundleRoot, withIntermediateDirectories: true
        )

        // Audit CSV — every chain entry, not just custody kinds.
        let entries = try await auditLog.entries(limit: 1_000_000)
        let auditCSV = Self.renderAuditCSV(entries)
        let auditURL = bundleRoot.appendingPathComponent("audit.csv")
        try Data(auditCSV.utf8).write(to: auditURL, options: .atomic)

        // Bates index — every assignment ordered by sequence.
        let batesRows = try await store.batesIndexRows()
        let batesCSV = Self.renderBatesCSV(batesRows)
        let batesURL = bundleRoot.appendingPathComponent("BatesIndex.csv")
        try Data(batesCSV.utf8).write(to: batesURL, options: .atomic)

        let sealed = try await exportSigner.seal(
            actor: actor,
            bundleName: bundleName,
            files: [
                .init(relativePath: "audit.csv", url: auditURL),
                .init(relativePath: "BatesIndex.csv", url: batesURL)
            ]
        )
        try sealed.manifestJSON.write(
            to: bundleRoot.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data(sealed.signatureHex.utf8).write(
            to: bundleRoot.appendingPathComponent("manifest.sig"),
            options: .atomic
        )

        _ = try await auditLog.record(
            actor: actor,
            action: "case_bundle_exported",
            subjectKind: "bundle",
            subjectID: bundleName,
            details: [
                "audit_rows": String(entries.count),
                "bates_rows": String(batesRows.count)
            ]
        )
    }

    private static func renderAuditCSV(_ entries: [AuditEntry]) -> String {
        var out = "ID,Timestamp,Actor,Action,SubjectKind,SubjectID,PrevHash,EntryHash\n"
        let iso = ISO8601DateFormatter()
        for e in entries.reversed() {
            out += [
                String(e.id),
                iso.string(from: e.occurredAt),
                csvField(e.actor),
                csvField(e.action),
                csvField(e.subjectKind),
                csvField(e.subjectID),
                e.prevHash,
                e.entryHash
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    private static func renderBatesCSV(_ rows: [MailStore.BatesIndexRow]) -> String {
        var out = "BatesNumber,Sequence,From,To,Subject,Date,MessageID,AssignedAt\n"
        let iso = ISO8601DateFormatter()
        for r in rows {
            out += [
                csvField(r.batesNumber),
                String(r.sequence),
                csvField(r.fromAddress),
                csvField(r.toAddresses),
                csvField(r.subject),
                iso.string(from: r.date),
                csvField(r.messageID),
                iso.string(from: r.assignedAt)
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    private static func csvField(_ text: String) -> String {
        var v = text.replacingOccurrences(of: "\"", with: "\"\"")
        if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"\(v)\""
        }
        return v
    }
}
