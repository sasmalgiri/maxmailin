import Foundation

/// User-facing custody actions. These map onto AuditLog entries — there is
/// no separate persistence store. Strings are stable wire values; never
/// rename them or older audit entries become unrecognisable as custody.
public enum CustodyEventKind: String, Sendable, CaseIterable, Codable {
    case imported
    case accessed
    case sealed
    case verified
    case annotated
    case taggedAsEvidence = "tagged_as_evidence"
    case markedPrivileged = "marked_privileged"
    case exported
    case transferred
}

public struct CustodyEvent: Sendable, Identifiable {
    public let id: Int64               // audit_log row id
    public let occurredAt: Date
    public let actor: String
    public let kind: CustodyEventKind
    public let subjectID: String       // either a message-id or bundle name
    public let description: String
    public let messageHash: String?    // present for seal/verify events
}

/// Outcome of `sealMessages` — newly-sealed count plus any rows that we
/// found already sealed (skipped) and any that don't exist (missing).
public struct SealReport: Sendable {
    public let newlySealed: Int
    public let alreadySealed: Int
    public let missing: [Int64]
}

public struct CustodyVerification: Sendable {
    public struct Drift: Sendable {
        public let messageRowID: Int64
        public let sealedHash: String
        public let currentHash: String
    }
    public let totalChecked: Int
    public let passed: Int
    public let unsealed: [Int64]   // rows with no baseline at all
    public let drifted: [Drift]    // rows whose canonical hash has changed
    public var isIntact: Bool { drifted.isEmpty && unsealed.isEmpty }
}

/// Coordinates the custody surface that sits on top of `AuditLog` and the
/// per-message integrity seals stored in `message_seals`.
///
/// Three responsibilities:
///
/// 1. **Seal** — compute and persist a baseline hash of a message's
///    canonical projection. Emits a `sealed` audit entry per message.
/// 2. **Verify** — recompute the canonical hash and compare to the
///    persisted seal. Emits a `verified` audit entry per batch with the
///    drift count in the details map.
/// 3. **Record** — append free-form custody events (accessed, annotated,
///    tagged as evidence, exported, transferred) directly into the audit
///    chain. Subject is either a message-id or an export bundle name.
///
/// All event persistence flows through `AuditLog`, so every action is
/// part of the same HMAC-chained tamper-evident log already covered by
/// `AuditLogTests`. We don't keep a parallel UserDefaults store.
public actor ChainOfCustodyManager {

    private let store: MailStore
    private let auditLog: AuditLog
    private let dateProvider: @Sendable () -> Date

    public init(
        store: MailStore,
        auditLog: AuditLog,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.auditLog = auditLog
        self.dateProvider = dateProvider
    }

    // MARK: - Seal

    /// Compute and persist baseline hashes for each given message row. Rows
    /// that already have a seal are left untouched (and reported back). One
    /// `sealed` audit entry is appended per *newly* sealed message.
    @discardableResult
    public func sealMessages(
        rowIDs: [Int64],
        actor: String
    ) async throws -> SealReport {
        let unique = Array(Set(rowIDs))
        let toSeal = try await store.unsealedMessageRowIDs(unique)
        let alreadySealedCount = unique.count - toSeal.count

        var newlySealed = 0
        var missing: [Int64] = []
        for id in toSeal {
            guard let hash = try await store.canonicalMessageHash(messageRowID: id) else {
                missing.append(id)
                continue
            }
            let when = dateProvider()
            try await store.recordMessageSeal(
                messageRowID: id, sealedAt: when, contentSHA256Hex: hash
            )
            _ = try await auditLog.record(
                actor: actor,
                action: CustodyEventKind.sealed.rawValue,
                subjectKind: "message",
                subjectID: String(id),
                details: ["sha256": hash],
                at: when
            )
            newlySealed += 1
        }
        return SealReport(
            newlySealed: newlySealed,
            alreadySealed: alreadySealedCount,
            missing: missing
        )
    }

    // MARK: - Verify

    /// Recompute the canonical hash for each given message and compare to
    /// the stored seal. Returns the rows whose hash changed (drifted) and
    /// rows that have never been sealed. A single `verified` audit entry
    /// captures the batch summary so the chain has a record of who ran the
    /// verification and what they found.
    @discardableResult
    public func verifyMessages(
        rowIDs: [Int64],
        actor: String
    ) async throws -> CustodyVerification {
        let unique = Array(Set(rowIDs))
        var unsealed: [Int64] = []
        var drifted: [CustodyVerification.Drift] = []
        var passed = 0
        for id in unique {
            guard let current = try await store.canonicalMessageHash(messageRowID: id) else {
                // Treat a missing message as unsealed — there's nothing to
                // verify against and surfacing it as drift would be wrong.
                unsealed.append(id)
                continue
            }
            guard let seal = try await store.messageSeal(messageRowID: id) else {
                unsealed.append(id)
                continue
            }
            if seal.sha256Hex == current {
                passed += 1
            } else {
                drifted.append(.init(
                    messageRowID: id,
                    sealedHash: seal.sha256Hex,
                    currentHash: current
                ))
            }
        }
        _ = try await auditLog.record(
            actor: actor,
            action: CustodyEventKind.verified.rawValue,
            subjectKind: "batch",
            subjectID: "\(unique.count)-messages",
            details: [
                "checked": String(unique.count),
                "passed": String(passed),
                "drifted": String(drifted.count),
                "unsealed": String(unsealed.count)
            ],
            at: dateProvider()
        )
        return CustodyVerification(
            totalChecked: unique.count,
            passed: passed,
            unsealed: unsealed,
            drifted: drifted
        )
    }

    // MARK: - Record

    /// Append a custody event to the audit chain. The `subjectKind` is
    /// implicit: `"message"` for per-row events, `"bundle"` for exports,
    /// `"custodian"` for transfers. Returns the audit row id.
    @discardableResult
    public func recordEvent(
        kind: CustodyEventKind,
        actor: String,
        subjectKind: String,
        subjectID: String,
        description: String,
        extraDetails: [String: String] = [:]
    ) async throws -> Int64 {
        var details = extraDetails
        details["description"] = description
        let entry = try await auditLog.record(
            actor: actor,
            action: kind.rawValue,
            subjectKind: subjectKind,
            subjectID: subjectID,
            details: details,
            at: dateProvider()
        )
        return entry.id
    }

    // MARK: - Read back

    /// Read recent custody events out of the audit log. Filters to known
    /// `CustodyEventKind` actions so non-custody audit rows (eg. flag
    /// changes) don't show up in the custody UI.
    public func events(limit: Int = 200) async throws -> [CustodyEvent] {
        let entries = try await auditLog.entries(limit: limit)
        return entries.compactMap { Self.custodyEvent(from: $0) }
    }

    private static func custodyEvent(from entry: AuditEntry) -> CustodyEvent? {
        guard let kind = CustodyEventKind(rawValue: entry.action) else { return nil }
        return CustodyEvent(
            id: entry.id,
            occurredAt: entry.occurredAt,
            actor: entry.actor,
            kind: kind,
            subjectID: entry.subjectID,
            description: entry.details["description"] ?? "",
            messageHash: entry.details["sha256"]
        )
    }

    // MARK: - Export

    /// Write a CSV custody trail into `bundleRoot` and seal the bundle with
    /// `ExportSigner`. After this returns, the directory contains:
    ///
    ///     <bundleRoot>/custody.csv
    ///     <bundleRoot>/manifest.json
    ///     <bundleRoot>/manifest.sig
    ///
    /// The signer is the caller's choice — same per-installation secret as
    /// the audit log, typically — so verifying the bundle later proves the
    /// CSV was the one this app produced at this moment.
    @discardableResult
    public func exportCustodyTrail(
        actor: String,
        bundleName: String,
        bundleRoot: URL,
        signer: ExportSigner,
        limit: Int = 5_000
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: bundleRoot, withIntermediateDirectories: true
        )
        let csvURL = bundleRoot.appendingPathComponent("custody.csv")
        let events = try await events(limit: limit)
        let csv = Self.renderCSV(events)
        try Data(csv.utf8).write(to: csvURL, options: .atomic)

        let sealed = try await signer.seal(
            actor: actor,
            bundleName: bundleName,
            files: [.init(relativePath: "custody.csv", url: csvURL)]
        )
        try sealed.manifestJSON.write(
            to: bundleRoot.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data(sealed.signatureHex.utf8).write(
            to: bundleRoot.appendingPathComponent("manifest.sig"),
            options: .atomic
        )

        // Record the export itself so future verifiers can see *which*
        // bundle name the trail was sealed under and who did it.
        _ = try await auditLog.record(
            actor: actor,
            action: CustodyEventKind.exported.rawValue,
            subjectKind: "bundle",
            subjectID: bundleName,
            details: ["events": String(events.count)],
            at: dateProvider()
        )
        return bundleRoot
    }

    private static func renderCSV(_ events: [CustodyEvent]) -> String {
        var out = "id,occurred_at,actor,kind,subject_id,description,message_hash\n"
        let iso = ISO8601DateFormatter()
        for e in events {
            out += [
                String(e.id),
                iso.string(from: e.occurredAt),
                csvField(e.actor),
                csvField(e.kind.rawValue),
                csvField(e.subjectID),
                csvField(e.description),
                csvField(e.messageHash ?? "")
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    /// CSV-escape a field. Quotes embed by doubling; leading `=+@-\t\r`
    /// gets a `'` prefix so Excel doesn't try to evaluate it as a formula
    /// when an examiner opens the trail.
    private static func csvField(_ text: String) -> String {
        var v = text.replacingOccurrences(of: "\"", with: "\"\"")
        if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"\(v)\""
        }
        return v
    }
}
