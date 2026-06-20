import Foundation

/// Cross-cutting case report. One Codable summary that rolls up the
/// audit log + Bates production + per-account analytics (top senders /
/// sentiment / phishing distribution / PII totals / monthly volume) +
/// custody markers (every message tagged-as-evidence or
/// marked-privileged on the chain).
///
/// This is the artifact you'd hand to a supervising attorney at the end
/// of a matter or to a forensic examiner reviewing your work. The PDF
/// rendering is a separate app-layer concern — Core's job is to
/// produce the structured truth, signed.
public struct InvestigationCaseReport: Sendable, Codable {

    public struct CaseHeader: Sendable, Codable {
        public let title: String
        public let caseNumber: String
        public let examiner: String
        public let generatedAt: Date
        public let accountAddress: String?
        public init(title: String, caseNumber: String, examiner: String,
                    generatedAt: Date, accountAddress: String?) {
            self.title = title
            self.caseNumber = caseNumber
            self.examiner = examiner
            self.generatedAt = generatedAt
            self.accountAddress = accountAddress
        }
    }

    public struct VolumePoint: Sendable, Codable {
        public let month: String          // "YYYY-MM"
        public let count: Int64
        public init(month: String, count: Int64) {
            self.month = month
            self.count = count
        }
    }

    public struct SenderRow: Sendable, Codable {
        public let address: String
        public let messageCount: Int64
        public init(address: String, messageCount: Int64) {
            self.address = address
            self.messageCount = messageCount
        }
    }

    public struct EvidenceMarker: Sendable, Codable {
        public let auditID: Int64
        public let occurredAt: Date
        public let actor: String
        public let kind: String           // "tagged_as_evidence" / "marked_privileged"
        public let subjectID: String      // message row id, as string
        public let description: String
        public init(auditID: Int64, occurredAt: Date, actor: String,
                    kind: String, subjectID: String, description: String) {
            self.auditID = auditID
            self.occurredAt = occurredAt
            self.actor = actor
            self.kind = kind
            self.subjectID = subjectID
            self.description = description
        }
    }

    public struct BatesRange: Sendable, Codable {
        public let first: String
        public let last: String
        public let count: Int64
        public init(first: String, last: String, count: Int64) {
            self.first = first
            self.last = last
            self.count = count
        }
    }

    public struct AuditChainSummary: Sendable, Codable {
        public let totalEntries: Int
        public let isIntact: Bool
        public let firstTamperedID: Int64?
        public init(totalEntries: Int, isIntact: Bool, firstTamperedID: Int64?) {
            self.totalEntries = totalEntries
            self.isIntact = isIntact
            self.firstTamperedID = firstTamperedID
        }
    }

    public let header: CaseHeader

    // Volume + sentiment
    public let totalMessages: Int64
    public let monthlyVolume: [VolumePoint]
    public let topSenders: [SenderRow]

    // Forensic signal
    public let phishingDistribution: [String: Int64]   // "none"/"low"/"medium"/"high" → count
    public let piiTotals: [String: Int]                // PIIFinding.Kind.rawValue → total

    // Custody / production
    public let evidenceMarkers: [EvidenceMarker]
    public let bates: BatesRange?
    public let auditSummary: AuditChainSummary

    public init(
        header: CaseHeader,
        totalMessages: Int64,
        monthlyVolume: [VolumePoint],
        topSenders: [SenderRow],
        phishingDistribution: [String: Int64],
        piiTotals: [String: Int],
        evidenceMarkers: [EvidenceMarker],
        bates: BatesRange?,
        auditSummary: AuditChainSummary
    ) {
        self.header = header
        self.totalMessages = totalMessages
        self.monthlyVolume = monthlyVolume
        self.topSenders = topSenders
        self.phishingDistribution = phishingDistribution
        self.piiTotals = piiTotals
        self.evidenceMarkers = evidenceMarkers
        self.bates = bates
        self.auditSummary = auditSummary
    }
}

/// Generator actor that composes a CaseReport from MailStore + AuditLog
/// + Bates. Records its own audit entry on the chain so the report's
/// existence is itself part of the case file. Export bundle (JSON +
/// CSV indices + signed manifest) is the same shape as the Bates and
/// GDPR exports for consistency.
public actor InvestigationReportGenerator {

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

    public func generate(
        accountID: Int64,
        accountAddress: String?,
        title: String,
        caseNumber: String,
        examiner: String,
        topSenderLimit: Int = 25
    ) async throws -> InvestigationCaseReport {

        let now = dateProvider()

        // Volume + sender mix come straight from the indexed message
        // table; both are O(rows-in-account), bounded by what the
        // examiner is actually working with.
        let monthly = try await store.monthlyMessageVolume(accountID: accountID)
        let total = monthly.reduce(Int64(0)) { $0 + $1.count }
        let senders = try await store.topSenders(
            accountID: accountID, limit: topSenderLimit
        )

        // Forensic distributions sourced from already-persisted analyzer
        // rows; we don't trigger fresh analysis here because that would
        // make report generation unbounded in time. UI flow is expected
        // to drive BackgroundAnalyzer ahead of asking for a case report.
        let phishing = try await store.phishingDistribution(accountID: accountID)

        // PII roll-up needs every message row id in scope. Cap at a
        // sensible ceiling so a giant corpus doesn't spike memory just
        // to enumerate row ids — the chunked aggregator in MailStore
        // batches the IN-lists internally.
        let rowIDs = try await Self.collectAccountRowIDs(
            store: store, accountID: accountID, limit: 500_000
        )
        let piiKinds = try await store.aggregatePIICounts(forMessageRowIDs: rowIDs)
        let piiTotals = piiKinds.reduce(into: [String: Int]()) { acc, kv in
            acc[kv.key.rawValue] = kv.value
        }

        // Custody markers: only the actions that mean "this is an
        // exhibit." The chain may carry seal/verify entries too but
        // those aren't case-report material.
        let evidence = try await Self.collectEvidenceMarkers(auditLog: auditLog)

        let bates = try await store.batesAssignmentRange().map {
            InvestigationCaseReport.BatesRange(
                first: $0.first, last: $0.last, count: $0.count
            )
        }

        let chain = try await auditLog.verify()
        let auditSummary = InvestigationCaseReport.AuditChainSummary(
            totalEntries: chain.totalEntries,
            isIntact: chain.isIntact,
            firstTamperedID: chain.firstTamperedID
        )

        let report = InvestigationCaseReport(
            header: .init(
                title: title, caseNumber: caseNumber, examiner: examiner,
                generatedAt: now, accountAddress: accountAddress
            ),
            totalMessages: total,
            monthlyVolume: monthly.map { .init(month: $0.month, count: $0.count) },
            topSenders: senders.map { .init(address: $0.address, messageCount: Int64($0.messageCount)) },
            phishingDistribution: phishing,
            piiTotals: piiTotals,
            evidenceMarkers: evidence,
            bates: bates,
            auditSummary: auditSummary
        )

        _ = try await auditLog.record(
            actor: examiner,
            action: "investigation_report_generated",
            subjectKind: "case",
            subjectID: caseNumber.isEmpty ? "untitled" : caseNumber,
            details: [
                "title": title,
                "messages": String(total),
                "evidence": String(evidence.count),
                "chain_intact": auditSummary.isIntact ? "true" : "false"
            ],
            at: now
        )
        return report
    }

    // MARK: - Export

    /// Write `case.json`, `monthly.csv`, `top_senders.csv`,
    /// `evidence.csv`, plus a signed manifest into `bundleRoot`. The
    /// CSV slices double as something a non-technical reviewer can
    /// open in Numbers / Excel without parsing JSON. Records an
    /// `investigation_report_exported` audit entry.
    @discardableResult
    public func exportBundle(
        actor: String,
        bundleName: String,
        bundleRoot: URL,
        report: InvestigationCaseReport,
        signer: ExportSigner
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: bundleRoot, withIntermediateDirectories: true
        )

        let jsonURL = bundleRoot.appendingPathComponent("case.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(report).write(to: jsonURL, options: .atomic)

        let monthlyURL = bundleRoot.appendingPathComponent("monthly.csv")
        try Data(Self.renderMonthlyCSV(report.monthlyVolume).utf8)
            .write(to: monthlyURL, options: .atomic)

        let sendersURL = bundleRoot.appendingPathComponent("top_senders.csv")
        try Data(Self.renderSendersCSV(report.topSenders).utf8)
            .write(to: sendersURL, options: .atomic)

        let evidenceURL = bundleRoot.appendingPathComponent("evidence.csv")
        try Data(Self.renderEvidenceCSV(report.evidenceMarkers).utf8)
            .write(to: evidenceURL, options: .atomic)

        let sealed = try await signer.seal(
            actor: actor,
            bundleName: bundleName,
            files: [
                .init(relativePath: "case.json",      url: jsonURL),
                .init(relativePath: "monthly.csv",    url: monthlyURL),
                .init(relativePath: "top_senders.csv", url: sendersURL),
                .init(relativePath: "evidence.csv",   url: evidenceURL)
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
            action: "investigation_report_exported",
            subjectKind: "bundle",
            subjectID: bundleName,
            details: [
                "case_number": report.header.caseNumber,
                "evidence": String(report.evidenceMarkers.count)
            ],
            at: dateProvider()
        )
        return bundleRoot
    }

    // MARK: - Helpers

    /// Enumerate row ids for an account in chronological order. Used
    /// only for PII aggregation; the store-level chunker handles the
    /// SQL IN-list slicing so this list stays a flat [Int64].
    private static func collectAccountRowIDs(
        store: MailStore, accountID: Int64, limit: Int
    ) async throws -> [Int64] {
        try await store.messageRowIDs(accountID: accountID, limit: limit)
    }

    private static func collectEvidenceMarkers(
        auditLog: AuditLog
    ) async throws -> [InvestigationCaseReport.EvidenceMarker] {
        let entries = try await auditLog.entries(limit: 10_000)
        return entries.compactMap { entry in
            switch entry.action {
            case "tagged_as_evidence", "marked_privileged":
                return InvestigationCaseReport.EvidenceMarker(
                    auditID: entry.id,
                    occurredAt: entry.occurredAt,
                    actor: entry.actor,
                    kind: entry.action,
                    subjectID: entry.subjectID,
                    description: entry.details["description"] ?? ""
                )
            default:
                return nil
            }
        }
    }

    private static func renderMonthlyCSV(_ rows: [InvestigationCaseReport.VolumePoint]) -> String {
        var out = "Month,Count\n"
        for r in rows {
            out += "\(r.month),\(r.count)\n"
        }
        return out
    }

    private static func renderSendersCSV(_ rows: [InvestigationCaseReport.SenderRow]) -> String {
        var out = "Address,MessageCount\n"
        for r in rows {
            out += "\(csvField(r.address)),\(r.messageCount)\n"
        }
        return out
    }

    private static func renderEvidenceCSV(_ rows: [InvestigationCaseReport.EvidenceMarker]) -> String {
        var out = "AuditID,Timestamp,Actor,Kind,SubjectID,Description\n"
        let iso = ISO8601DateFormatter()
        for r in rows {
            out += [
                String(r.auditID),
                iso.string(from: r.occurredAt),
                csvField(r.actor),
                csvField(r.kind),
                csvField(r.subjectID),
                csvField(r.description)
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
