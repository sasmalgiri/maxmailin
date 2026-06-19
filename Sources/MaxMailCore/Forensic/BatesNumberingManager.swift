import Foundation

/// Bates numbering configuration. `prefix` is the project / matter code
/// (often the producing party's name), `startNumber` is the first sequence
/// to issue, `zeroPadding` controls how many digits the integer portion is
/// padded to. A typical configuration is `MAILIN` / `1` / `6`, producing
/// `MAILIN000001`, `MAILIN000002`, … which is what most U.S. discovery
/// production protocols expect.
public struct BatesConfig: Sendable, Equatable {
    public var prefix: String
    public var startNumber: Int64
    public var zeroPadding: Int

    public init(prefix: String = "MAILIN", startNumber: Int64 = 1, zeroPadding: Int = 6) {
        self.prefix = prefix
        self.startNumber = startNumber
        self.zeroPadding = zeroPadding
    }
}

public struct BatesAssignmentReport: Sendable {
    public let newlyAssignedCount: Int
    public let alreadyAssignedCount: Int64
    public let firstBatesNumber: String?
    public let lastBatesNumber: String?
}

/// Sequential Bates numbering for legal production. Sits on the audit
/// chain so every assignment / removal is recorded — Bates numbers are
/// citation-stable identifiers used in court filings, so an unrecorded
/// renumbering is a serious evidence-handling issue.
///
/// The actor is deliberately small: format / assign / lookup / export /
/// remove. Heavier UI workflows (PDF stamping, redaction overlays) sit
/// in the app layer and call into this for the underlying number.
///
/// Numbering policy:
/// - Sort all unnumbered messages by `date_unix ASC, id ASC` so the
///   sequence matches the chronological order an examiner would
///   produce by hand.
/// - The next sequence is `max(existing) + 1` clamped to `>= start`. If
///   the config's start is bumped after assignments exist, we keep
///   appending past the existing high-water mark rather than skipping
///   forward — preserving the contract that every number is unique and
///   nothing already assigned changes.
public actor BatesNumberingManager {

    private static let cfgPrefix     = "prefix"
    private static let cfgStartKey   = "start"
    private static let cfgPaddingKey = "padding"
    private static let auditAssign   = "bates_assigned"
    private static let auditRemove   = "bates_removed"

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

    // MARK: - Config

    public func config() async throws -> BatesConfig {
        let prefix = (try await store.batesConfigValue(forKey: Self.cfgPrefix)) ?? "MAILIN"
        let start  = Int64((try await store.batesConfigValue(forKey: Self.cfgStartKey)) ?? "1") ?? 1
        let pad    = Int((try await store.batesConfigValue(forKey: Self.cfgPaddingKey)) ?? "6") ?? 6
        return BatesConfig(prefix: prefix, startNumber: start, zeroPadding: pad)
    }

    public func setConfig(_ cfg: BatesConfig) async throws {
        try await store.setBatesConfigValue(cfg.prefix, forKey: Self.cfgPrefix)
        try await store.setBatesConfigValue(String(cfg.startNumber), forKey: Self.cfgStartKey)
        try await store.setBatesConfigValue(String(cfg.zeroPadding), forKey: Self.cfgPaddingKey)
    }

    /// Pure number formatter. Exposed so previews can show a config's
    /// first/last numbers without writing to the store.
    public static func format(_ n: Int64, config: BatesConfig) -> String {
        let pad = max(1, config.zeroPadding)
        // Format with width pad; %0*lld matches what the legacy mailin
        // ObjC bridge produced so existing examiners see the same shape.
        return "\(config.prefix)\(String(format: "%0\(pad)lld", n))"
    }

    public func format(_ n: Int64) async throws -> String {
        Self.format(n, config: try await config())
    }

    // MARK: - Assign

    /// Stamp every unnumbered message in `accountID` (or across all
    /// accounts when nil) in chronological order. Already-numbered
    /// messages are left exactly as they are — Bates numbers are
    /// citation-stable so the rule is *never re-stamp*.
    @discardableResult
    public func assignNumbers(
        accountID: Int64? = nil,
        actor: String,
        limit: Int = 100_000
    ) async throws -> BatesAssignmentReport {
        let cfg = try await config()
        let alreadyCount = try await store.batesAssignmentCount()
        let candidates = try await store.unnumberedMessageRowIDsInChronologicalOrder(
            accountID: accountID, limit: limit
        )
        guard !candidates.isEmpty else {
            return BatesAssignmentReport(
                newlyAssignedCount: 0,
                alreadyAssignedCount: alreadyCount,
                firstBatesNumber: nil,
                lastBatesNumber: nil
            )
        }

        let highWater = try await store.maxAssignedBatesSequence()
        // Don't roll backwards if the user lowered `start` after some rows
        // were already produced — every Bates number must remain unique.
        let nextStart = max(highWater + 1, cfg.startNumber)
        let assignedAt = dateProvider()
        var rows: [MailStore.BatesAssignmentRow] = []
        rows.reserveCapacity(candidates.count)
        for (i, rowID) in candidates.enumerated() {
            let seq = nextStart + Int64(i)
            rows.append(.init(
                messageRowID: rowID,
                sequence: seq,
                batesNumber: Self.format(seq, config: cfg),
                assignedAt: assignedAt
            ))
        }
        try await store.bulkInsertBatesAssignments(rows)

        let first = rows.first?.batesNumber
        let last  = rows.last?.batesNumber
        _ = try await auditLog.record(
            actor: actor,
            action: Self.auditAssign,
            subjectKind: "batch",
            subjectID: "\(rows.count)-messages",
            details: [
                "count": String(rows.count),
                "first": first ?? "",
                "last":  last ?? "",
                "prefix": cfg.prefix
            ],
            at: assignedAt
        )

        return BatesAssignmentReport(
            newlyAssignedCount: rows.count,
            alreadyAssignedCount: alreadyCount,
            firstBatesNumber: first,
            lastBatesNumber: last
        )
    }

    // MARK: - Lookup

    public func batesNumber(messageRowID: Int64) async throws -> String? {
        try await store.batesAssignment(messageRowID: messageRowID)?.batesNumber
    }

    public func count() async throws -> Int64 {
        try await store.batesAssignmentCount()
    }

    // MARK: - Remove

    /// Wipe every Bates assignment. Audit entry is written *before* the
    /// rows are dropped so the chain retains a record of who removed
    /// what and how many — Bates removal is unusual and a forensic red
    /// flag if it ever happens without a clear rationale.
    @discardableResult
    public func removeAllAssignments(actor: String, reason: String) async throws -> Int64 {
        let count = try await store.batesAssignmentCount()
        _ = try await auditLog.record(
            actor: actor,
            action: Self.auditRemove,
            subjectKind: "batch",
            subjectID: "\(count)-messages",
            details: ["count": String(count), "reason": reason],
            at: dateProvider()
        )
        return try await store.removeAllBatesAssignments()
    }

    // MARK: - Export

    /// Write `BatesIndex.csv` + signed manifest into `bundleRoot`. CSV
    /// columns mirror what U.S. discovery production cover sheets ask
    /// for: BatesNumber, Sequence, From, To, Subject, Date, MessageID,
    /// AssignedAt. The manifest signature lets the receiving party
    /// verify the file hasn't drifted in transit.
    @discardableResult
    public func exportBatesIndex(
        actor: String,
        bundleName: String,
        bundleRoot: URL,
        signer: ExportSigner,
        limit: Int = 100_000
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: bundleRoot, withIntermediateDirectories: true
        )
        let csvURL = bundleRoot.appendingPathComponent("BatesIndex.csv")
        let rows = try await store.batesIndexRows(limit: limit)
        let csv = Self.renderCSV(rows)
        try Data(csv.utf8).write(to: csvURL, options: .atomic)

        let sealed = try await signer.seal(
            actor: actor,
            bundleName: bundleName,
            files: [.init(relativePath: "BatesIndex.csv", url: csvURL)]
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
            action: "bates_index_exported",
            subjectKind: "bundle",
            subjectID: bundleName,
            details: ["rows": String(rows.count)],
            at: dateProvider()
        )
        return bundleRoot
    }

    private static func renderCSV(_ rows: [MailStore.BatesIndexRow]) -> String {
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

    /// Same CSV-escape rules as ChainOfCustodyManager: double quotes, leading
    /// `=+@-\t\r` gets a `'` prefix so opening the CSV in Excel can't trigger
    /// a formula-injection attack on whoever's reviewing production.
    private static func csvField(_ text: String) -> String {
        var v = text.replacingOccurrences(of: "\"", with: "\"\"")
        if let first = v.first, "=+@-\t\r".contains(first) { v = "'" + v }
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"\(v)\""
        }
        return v
    }
}
