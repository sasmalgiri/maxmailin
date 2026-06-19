import Foundation

/// Structured GDPR data-subject access summary. Codable so the app layer
/// can render it to PDF, JSON, or HTML without the Core engine knowing
/// about any rendering framework.
///
/// Field semantics map onto Article 15 (right of access) disclosures:
/// what data is held, who it has been shared with, retention windows,
/// and PII categories. The accompanying CSV index emitted by the
/// generator covers the per-message detail.
public struct GDPRAccessReport: Sendable, Codable {

    public struct CorrespondentTally: Sendable, Codable {
        public let address: String
        public let messageCount: Int
        public init(address: String, messageCount: Int) {
            self.address = address
            self.messageCount = messageCount
        }
    }

    public let dataSubject: String
    public let generatedAt: Date
    public let actor: String

    public let totalMessages: Int
    public let messagesAsSender: Int
    public let messagesAsRecipient: Int
    public let messagesWithAttachments: Int

    public let earliestDate: Date?
    public let latestDate: Date?

    public let distinctCorrespondents: [CorrespondentTally]
    public let distinctFolders: [String]
    public let messagesByYear: [Int: Int]
    public let piiCounts: [String: Int]   // PIIFinding.Kind.rawValue -> total

    public init(
        dataSubject: String, generatedAt: Date, actor: String,
        totalMessages: Int, messagesAsSender: Int, messagesAsRecipient: Int,
        messagesWithAttachments: Int,
        earliestDate: Date?, latestDate: Date?,
        distinctCorrespondents: [CorrespondentTally],
        distinctFolders: [String], messagesByYear: [Int: Int],
        piiCounts: [String: Int]
    ) {
        self.dataSubject = dataSubject
        self.generatedAt = generatedAt
        self.actor = actor
        self.totalMessages = totalMessages
        self.messagesAsSender = messagesAsSender
        self.messagesAsRecipient = messagesAsRecipient
        self.messagesWithAttachments = messagesWithAttachments
        self.earliestDate = earliestDate
        self.latestDate = latestDate
        self.distinctCorrespondents = distinctCorrespondents
        self.distinctFolders = distinctFolders
        self.messagesByYear = messagesByYear
        self.piiCounts = piiCounts
    }
}

public struct GDPREraseReport: Sendable {
    public let dataSubject: String
    public let messagesDeleted: Int
    public let messagesFailed: Int
    public init(dataSubject: String, messagesDeleted: Int, messagesFailed: Int) {
        self.dataSubject = dataSubject
        self.messagesDeleted = messagesDeleted
        self.messagesFailed = messagesFailed
    }
}

/// Builds a GDPR Article 15 (right of access) summary for a given data
/// subject, plus the Article 17 (right to erasure) deletion flow.
///
/// All operations are recorded on the audit chain — GDPR responses are
/// regulated disclosures, and the audit trail proves who ran the report
/// and when. Export bundles are HMAC-signed via ExportSigner so an
/// auditor can later verify they have the same disclosure the data
/// subject was given.
///
/// Body / Bcc / forensic enrichment policy:
/// - Header involvement (from/to/cc) is exact at SQL time; that's the
///   ground truth for Article 15.
/// - PII roll-up uses the existing per-message forensics column. Rows
///   without forensics are silently skipped — the report's
///   `piiCounts` reflects what's already been analyzed rather than
///   triggering a slow on-the-fly scan that would block the report.
public actor GDPRAccessReportGenerator {

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

    // MARK: - Generate

    public func generate(
        dataSubject: String,
        actor: String,
        accountID: Int64? = nil,
        topCorrespondents: Int = 50,
        limit: Int = 100_000
    ) async throws -> (report: GDPRAccessReport, messages: [MailStore.GDPRMessageRef]) {
        let trimmed = dataSubject.trimmingCharacters(in: .whitespaces).lowercased()
        let messages = try await store.findMessagesInvolving(
            emailAddress: trimmed, accountID: accountID, limit: limit
        )

        var asSender = 0
        var asRecipient = 0
        var withAttachments = 0
        var earliest: Date?
        var latest: Date?
        var byYear: [Int: Int] = [:]
        var folders = Set<String>()
        var correspondents: [String: Int] = [:]

        let cal = Calendar(identifier: .iso8601)
        for m in messages {
            let from = m.fromAddress.lowercased()
            if from.contains(trimmed) {
                asSender += 1
            }
            let to = m.toAddresses.lowercased()
            let cc = m.ccAddresses.lowercased()
            if to.contains(trimmed) || cc.contains(trimmed) {
                asRecipient += 1
            }
            if m.hasAttachments { withAttachments += 1 }

            if earliest == nil || m.date < earliest! { earliest = m.date }
            if latest == nil || m.date > latest! { latest = m.date }

            let year = cal.component(.year, from: m.date)
            byYear[year, default: 0] += 1
            folders.insert(m.folder)

            for addr in Self.extractAddresses(m.fromAddress) {
                if addr != trimmed { correspondents[addr, default: 0] += 1 }
            }
            for addr in Self.extractAddresses(m.toAddresses) {
                if addr != trimmed { correspondents[addr, default: 0] += 1 }
            }
            for addr in Self.extractAddresses(m.ccAddresses) {
                if addr != trimmed { correspondents[addr, default: 0] += 1 }
            }
        }

        let topCorr = correspondents
            .sorted { lhs, rhs in
                lhs.value != rhs.value
                    ? lhs.value > rhs.value
                    : lhs.key < rhs.key
            }
            .prefix(topCorrespondents)
            .map { GDPRAccessReport.CorrespondentTally(address: $0.key, messageCount: $0.value) }

        let piiTotals = try await store.aggregatePIICounts(
            forMessageRowIDs: messages.map(\.messageRowID)
        )
        let piiCounts = piiTotals.reduce(into: [String: Int]()) { acc, kv in
            acc[kv.key.rawValue] = kv.value
        }

        let now = dateProvider()
        let report = GDPRAccessReport(
            dataSubject: trimmed,
            generatedAt: now,
            actor: actor,
            totalMessages: messages.count,
            messagesAsSender: asSender,
            messagesAsRecipient: asRecipient,
            messagesWithAttachments: withAttachments,
            earliestDate: earliest,
            latestDate: latest,
            distinctCorrespondents: Array(topCorr),
            distinctFolders: folders.sorted(),
            messagesByYear: byYear,
            piiCounts: piiCounts
        )

        _ = try await auditLog.record(
            actor: actor,
            action: "gdpr_access_report_generated",
            subjectKind: "data_subject",
            subjectID: trimmed,
            details: [
                "messages": String(messages.count),
                "as_sender": String(asSender),
                "as_recipient": String(asRecipient)
            ],
            at: now
        )
        return (report, messages)
    }

    // MARK: - Export

    /// Write `report.json`, `Messages.csv`, and a signed manifest into
    /// `bundleRoot`. The CSV mirrors what Article 15 disclosures
    /// typically include for inspection: subject, from, to, date,
    /// folder, attachment flag, message-id.
    @discardableResult
    public func exportBundle(
        actor: String,
        bundleName: String,
        bundleRoot: URL,
        report: GDPRAccessReport,
        messages: [MailStore.GDPRMessageRef],
        signer: ExportSigner
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: bundleRoot, withIntermediateDirectories: true
        )

        let jsonURL = bundleRoot.appendingPathComponent("report.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(report).write(to: jsonURL, options: .atomic)

        let csvURL = bundleRoot.appendingPathComponent("Messages.csv")
        try Data(Self.renderMessagesCSV(messages).utf8).write(to: csvURL, options: .atomic)

        let sealed = try await signer.seal(
            actor: actor,
            bundleName: bundleName,
            files: [
                .init(relativePath: "report.json", url: jsonURL),
                .init(relativePath: "Messages.csv", url: csvURL)
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
            action: "gdpr_access_report_exported",
            subjectKind: "bundle",
            subjectID: bundleName,
            details: [
                "data_subject": report.dataSubject,
                "messages": String(messages.count)
            ],
            at: dateProvider()
        )
        return bundleRoot
    }

    // MARK: - Erase (Article 17)

    /// Delete every message returned by `findMessagesInvolving` for the
    /// given subject. Recorded on the audit chain *before* deletion so
    /// the record persists even though the underlying rows don't. Bates
    /// numbers and message seals cascade out via `ON DELETE CASCADE` —
    /// regulators consider that the correct outcome for the right to
    /// erasure, but if you need to preserve the metadata you should
    /// erase manually instead of calling this.
    @discardableResult
    public func eraseAllForSubject(
        emailAddress: String,
        actor: String,
        reason: String,
        accountID: Int64? = nil
    ) async throws -> GDPREraseReport {
        let trimmed = emailAddress.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = try await store.findMessagesInvolving(
            emailAddress: trimmed, accountID: accountID
        )
        _ = try await auditLog.record(
            actor: actor,
            action: "gdpr_erasure_requested",
            subjectKind: "data_subject",
            subjectID: trimmed,
            details: [
                "messages": String(matches.count),
                "reason": reason
            ],
            at: dateProvider()
        )
        var deleted = 0
        var failed = 0
        for m in matches {
            do {
                try await store.deleteMessage(messageRowID: m.messageRowID)
                deleted += 1
            } catch {
                failed += 1
            }
        }
        _ = try await auditLog.record(
            actor: actor,
            action: "gdpr_erasure_completed",
            subjectKind: "data_subject",
            subjectID: trimmed,
            details: [
                "deleted": String(deleted),
                "failed": String(failed)
            ],
            at: dateProvider()
        )
        return GDPREraseReport(
            dataSubject: trimmed,
            messagesDeleted: deleted,
            messagesFailed: failed
        )
    }

    // MARK: - Helpers

    private static func renderMessagesCSV(_ messages: [MailStore.GDPRMessageRef]) -> String {
        var out = "Date,From,To,Cc,Subject,Folder,HasAttachments,MessageID\n"
        let iso = ISO8601DateFormatter()
        for m in messages {
            out += [
                iso.string(from: m.date),
                csvField(m.fromAddress),
                csvField(m.toAddresses),
                csvField(m.ccAddresses),
                csvField(m.subject),
                csvField(m.folder),
                m.hasAttachments ? "1" : "0",
                csvField(m.messageID)
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

    /// Extract bare email addresses from a header value that may contain
    /// `"Alice" <alice@x>` style entries separated by commas. We don't try
    /// to be RFC 5322 perfect — just good enough for correspondent
    /// counts. Anything with an `@` in it counts; everything else is
    /// ignored.
    static func extractAddresses(_ raw: String) -> [String] {
        let lowered = raw.lowercased()
        var out: [String] = []
        var current = ""
        var inAngle = false
        for ch in lowered {
            if ch == "<" { inAngle = true; current = ""; continue }
            if ch == ">" {
                inAngle = false
                if current.contains("@") { out.append(current) }
                current = ""
                continue
            }
            if inAngle { current.append(ch); continue }
            if ch == "," {
                let token = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if token.contains("@") { out.append(token) }
                current = ""
                continue
            }
            current.append(ch)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inAngle, tail.contains("@") { out.append(tail) }
        return out
    }
}
