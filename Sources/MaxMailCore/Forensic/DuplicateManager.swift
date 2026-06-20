import Foundation

/// Resolution policy for cleaning up duplicate clusters. "keep oldest"
/// is the default because legal-discovery norms preserve the earliest
/// copy as canonical evidence. The pure-Swift "deleteAllButFirst" /
/// "deleteAllButLast" variants are exposed so a future UI flow can let
/// the user pick.
public enum DuplicateResolution: String, Sendable {
    case keepOldest
    case keepNewest

    func rowsToDelete(_ cluster: MailStore.DuplicateCluster) -> [Int64] {
        // MailStore returns rowIDs date-ascending. Drop the first
        // (oldest) or the last (newest) depending on policy.
        switch self {
        case .keepOldest:
            return Array(cluster.messageRowIDs.dropFirst())
        case .keepNewest:
            return Array(cluster.messageRowIDs.dropLast())
        }
    }
}

public struct DuplicateResolutionReport: Sendable {
    public let clustersResolved: Int
    public let messagesDeleted: Int
    public let messagesFailed: Int
    public init(clustersResolved: Int, messagesDeleted: Int, messagesFailed: Int) {
        self.clustersResolved = clustersResolved
        self.messagesDeleted = messagesDeleted
        self.messagesFailed = messagesFailed
    }
}

/// Surfaces and resolves duplicate clusters on top of MailStore.
///
/// Detection policy: `(subject, from_addr)` pairs with more than one
/// row in the same account. That's the cheapest correct heuristic
/// at scale — SQL-driven, no body comparison required. Two messages
/// from the same sender with the same subject are nearly always the
/// same thread artifact (CC'd twice, mailing-list dupes, sync drift),
/// and the rare false positive of two genuinely-distinct messages
/// sharing both fields is exactly the case where you want manual
/// review anyway.
///
/// Resolution writes one audit entry per resolved cluster recording
/// which rows were kept and which were dropped, so the chain has the
/// receipts even though the deleted rows are gone. The deletion path
/// goes through `MailStore.deleteMessage`, which cascades to bodies /
/// attachments / NLP / forensics / FTS — the standard contract.
public actor DuplicateManager {

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

    /// Read-only: list duplicate clusters newest-largest-first.
    public func clusters(
        accountID: Int64,
        limit: Int = 200,
        rowsPerCluster: Int = 50
    ) async throws -> [MailStore.DuplicateCluster] {
        try await store.duplicateClusters(
            accountID: accountID, limit: limit, rowsPerCluster: rowsPerCluster
        )
    }

    /// Apply `resolution` to every cluster supplied. Use `clusters(...)`
    /// to fetch the list first; the caller can filter / present /
    /// confirm before invoking this.
    @discardableResult
    public func resolve(
        clusters: [MailStore.DuplicateCluster],
        using resolution: DuplicateResolution,
        actor: String
    ) async throws -> DuplicateResolutionReport {
        var resolved = 0
        var deleted = 0
        var failed = 0
        for cluster in clusters {
            let toDelete = resolution.rowsToDelete(cluster)
            if toDelete.isEmpty { continue }
            let keepers = cluster.messageRowIDs.filter { !toDelete.contains($0) }
            _ = try await auditLog.record(
                actor: actor,
                action: "duplicates_resolved",
                subjectKind: "cluster",
                subjectID: cluster.subject,
                details: [
                    "from": cluster.fromAddress,
                    "kept": keepers.map(String.init).joined(separator: ","),
                    "deleted": toDelete.map(String.init).joined(separator: ","),
                    "policy": resolution.rawValue
                ],
                at: dateProvider()
            )
            for id in toDelete {
                do {
                    try await store.deleteMessage(messageRowID: id)
                    deleted += 1
                } catch {
                    failed += 1
                }
            }
            resolved += 1
        }
        return DuplicateResolutionReport(
            clustersResolved: resolved,
            messagesDeleted: deleted,
            messagesFailed: failed
        )
    }
}
