import Foundation
import CryptoKit

public struct AuditEntry: Sendable, Identifiable {
    public let id: Int64
    public let occurredAt: Date
    public let actor: String
    public let action: String
    public let subjectKind: String
    public let subjectID: String
    public let details: [String: String]
    public let prevHash: String
    public let entryHash: String

    public init(
        id: Int64, occurredAt: Date, actor: String, action: String,
        subjectKind: String, subjectID: String,
        details: [String: String], prevHash: String, entryHash: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.actor = actor
        self.action = action
        self.subjectKind = subjectKind
        self.subjectID = subjectID
        self.details = details
        self.prevHash = prevHash
        self.entryHash = entryHash
    }
}

public struct AuditVerification: Sendable {
    public let totalEntries: Int
    public let firstTamperedID: Int64?
    public var isIntact: Bool { firstTamperedID == nil }
}

/// Tamper-evident append-only audit log.
///
/// Each row's `entry_hash` is HMAC-SHA256 over a canonicalised payload
/// concatenated with the previous row's `entry_hash`, keyed by a
/// per-installation secret the caller supplies. Verifying the chain means
/// recomputing each entry's hash and checking it matches what was written.
/// Any inserted, edited, deleted, or reordered row breaks the chain at the
/// affected entry.
public actor AuditLog {

    public static let genesisHash: String = String(repeating: "0", count: 64)

    private let store: MailStore
    private let secret: SymmetricKey

    public init(store: MailStore, secret: Data) {
        self.store = store
        self.secret = SymmetricKey(data: secret)
    }

    /// Append a new entry. `details` is a flat string map (we keep
    /// canonicalisation easy by sorting keys).
    @discardableResult
    public func record(
        actor: String,
        action: String,
        subjectKind: String,
        subjectID: String,
        details: [String: String] = [:],
        at date: Date = Date()
    ) async throws -> AuditEntry {
        let prevHash = (try await store.lastAuditEntryHash()) ?? Self.genesisHash
        let occurred = Int64(date.timeIntervalSince1970)
        let detailsJSON = Self.canonicalJSON(details)
        let payload = Self.canonicalPayload(
            occurredAt: occurred, actor: actor, action: action,
            subjectKind: subjectKind, subjectID: subjectID,
            detailsJSON: detailsJSON
        )
        let entryHash = Self.hmacHex(secret: secret,
                                     payload: payload + prevHash)
        let id = try await store.appendAuditEntry(
            occurredAt: occurred, actor: actor, action: action,
            subjectKind: subjectKind, subjectID: subjectID,
            detailsJSON: detailsJSON,
            prevHash: prevHash, entryHash: entryHash
        )
        return AuditEntry(
            id: id, occurredAt: date, actor: actor, action: action,
            subjectKind: subjectKind, subjectID: subjectID,
            details: details, prevHash: prevHash, entryHash: entryHash
        )
    }

    public func entries(limit: Int = 200) async throws -> [AuditEntry] {
        try await store.auditEntries(limit: limit)
    }

    /// Walk every entry in order, recomputing each hash. Returns the id
    /// of the first entry whose computed hash doesn't match the stored
    /// hash, or nil when the whole chain verifies.
    public func verify() async throws -> AuditVerification {
        let all = try await store.auditEntriesInOrder()
        var prev = Self.genesisHash
        for entry in all {
            let occurred = Int64(entry.occurredAt.timeIntervalSince1970)
            let payload = Self.canonicalPayload(
                occurredAt: occurred, actor: entry.actor, action: entry.action,
                subjectKind: entry.subjectKind, subjectID: entry.subjectID,
                detailsJSON: Self.canonicalJSON(entry.details)
            )
            let expected = Self.hmacHex(secret: secret, payload: payload + prev)
            if expected != entry.entryHash || entry.prevHash != prev {
                return AuditVerification(totalEntries: all.count,
                                         firstTamperedID: entry.id)
            }
            prev = entry.entryHash
        }
        return AuditVerification(totalEntries: all.count, firstTamperedID: nil)
    }

    // MARK: - Canonicalisation

    /// Stable string representation: sorted key=value pairs separated by `;`.
    /// We intentionally avoid JSON because Foundation's JSONEncoder doesn't
    /// guarantee key ordering across runs — a re-serialise would break the
    /// HMAC even though semantically nothing changed.
    static func canonicalJSON(_ details: [String: String]) -> String {
        details.keys.sorted().map { "\($0)=\(details[$0] ?? "")" }.joined(separator: ";")
    }

    static func canonicalPayload(
        occurredAt: Int64, actor: String, action: String,
        subjectKind: String, subjectID: String, detailsJSON: String
    ) -> String {
        [
            String(occurredAt), actor, action,
            subjectKind, subjectID, detailsJSON
        ].joined(separator: "|")
    }

    static func hmacHex(secret: SymmetricKey, payload: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: secret)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
