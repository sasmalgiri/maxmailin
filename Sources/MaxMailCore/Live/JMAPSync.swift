import Foundation

public struct JMAPMailbox: Sendable, Hashable {
    public let id: String
    public let name: String
    public let role: String?         // "inbox" / "sent" / "archive" / "trash" / "drafts" / etc.
    public let totalEmails: Int
    public let unreadEmails: Int
}

/// Drives a JMAP backend → MailStore handoff.
///
/// Single-shot snapshot model for this first cut:
/// - `listMailboxes()` enumerates folders
/// - `pullRecent(mailbox:limit:)` fetches the newest N emails from one
///   mailbox, parses them into `IngestMessage`s, and pushes them through
///   `MailStore.bulkIngest`. The unique `(account_id, message_id)` index
///   makes re-runs idempotent.
///
/// What's deferred (Phase 3A.2): Email/changes-based incremental sync via
/// state tokens; the eventSource push channel; flag updates / writes; the
/// Identity / Email/send path for outbound mail.
public actor JMAPSync {
    private let client: JMAPClient
    private let store: MailStore
    /// The local MailStore account row this JMAP backend feeds.
    private let localAccountID: Int64

    public init(client: JMAPClient, store: MailStore, localAccountID: Int64) {
        self.client = client
        self.store = store
        self.localAccountID = localAccountID
    }

    /// Enumerate mailboxes on the JMAP account.
    public func listMailboxes() async throws -> [JMAPMailbox] {
        let session = try await client.currentSession()
        guard let jmapAccountID = session.primaryMailAccountID else {
            throw JMAPError.invalidResponse("session has no primary mail account")
        }
        let result = try await client.invoke(methodCalls: [
            ["Mailbox/get", ["accountId": jmapAccountID], "0"]
        ])
        guard let args = result.first(method: "Mailbox/get"),
              let list = args["list"] as? [[String: Any]]
        else { throw JMAPError.invalidResponse("Mailbox/get missing list") }

        return list.compactMap { dict -> JMAPMailbox? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            return JMAPMailbox(
                id: id,
                name: name,
                role: dict["role"] as? String,
                totalEmails: dict["totalEmails"] as? Int ?? 0,
                unreadEmails: dict["unreadEmails"] as? Int ?? 0
            )
        }
    }

    /// Pull the newest `limit` emails from one mailbox into the local MailStore.
    /// Returns (ingested, skippedDuplicates).
    @discardableResult
    public func pullRecent(
        mailbox: JMAPMailbox,
        folderName: String? = nil,
        limit: Int = 100
    ) async throws -> (ingested: Int, skipped: Int) {
        let session = try await client.currentSession()
        guard let jmapAccountID = session.primaryMailAccountID else {
            throw JMAPError.invalidResponse("session has no primary mail account")
        }

        // Single round-trip: Email/query then Email/get with back-reference.
        let result = try await client.invoke(methodCalls: [
            ["Email/query", [
                "accountId": jmapAccountID,
                "filter": ["inMailbox": mailbox.id],
                "sort": [["property": "receivedAt", "isAscending": false]],
                "limit": limit
            ], "q"],
            ["Email/get", [
                "accountId": jmapAccountID,
                "#ids": ["resultOf": "q", "name": "Email/query", "path": "/ids"],
                "properties": [
                    "id", "messageId", "inReplyTo", "references", "subject",
                    "from", "to", "cc", "receivedAt", "size", "keywords",
                    "hasAttachment", "preview", "textBody", "htmlBody",
                    "bodyValues"
                ],
                "fetchTextBodyValues": true,
                "fetchHTMLBodyValues": true,
                "maxBodyValueBytes": 1_048_576
            ], "g"]
        ])

        guard let getArgs = result.first(method: "Email/get"),
              let emails = getArgs["list"] as? [[String: Any]]
        else { throw JMAPError.invalidResponse("Email/get missing list") }

        let resolvedFolder = folderName ?? mailbox.name
        var batch: [IngestMessage] = []
        batch.reserveCapacity(emails.count)
        for entry in emails {
            if let msg = ingestMessage(from: entry, folder: resolvedFolder) {
                batch.append(msg)
            }
        }
        let inserted = try await store.bulkIngest(batch)
        return (inserted, batch.count - inserted)
    }

    /// Convenience: pull recent mail from every mailbox at once.
    @discardableResult
    public func pullRecentFromAll(limit: Int = 100) async throws -> Int {
        let boxes = try await listMailboxes()
        var total = 0
        for box in boxes {
            let (n, _) = try await pullRecent(mailbox: box, limit: limit)
            total += n
        }
        return total
    }

    // MARK: - JSON → IngestMessage

    private func ingestMessage(from email: [String: Any], folder: String) -> IngestMessage? {
        // messageId is an *array* of strings per RFC 8621 (header may carry many).
        let messageID: String
        if let ids = email["messageId"] as? [String], let first = ids.first {
            messageID = first.hasPrefix("<") ? first : "<\(first)>"
        } else if let id = email["id"] as? String {
            // Fallback: synthesize from JMAP id so we still have a unique key.
            messageID = "<jmap-\(id)@local>"
        } else {
            return nil
        }

        let subject = (email["subject"] as? String) ?? ""
        let from = firstEmailAddress(email["from"]) ?? ""
        let to = emailAddresses(email["to"])
        let cc = emailAddresses(email["cc"])
        let inReplyTo: String? = {
            if let arr = email["inReplyTo"] as? [String], let v = arr.first {
                return v.hasPrefix("<") ? v : "<\(v)>"
            }
            return nil
        }()
        let references: [String] = {
            (email["references"] as? [String])?.map { $0.hasPrefix("<") ? $0 : "<\($0)>" } ?? []
        }()
        let date = parseJMAPDate(email["receivedAt"] as? String) ?? Date()
        let sizeBytes = Int64(email["size"] as? Int ?? 0)

        var flags: MessageFlags = []
        if let keywords = email["keywords"] as? [String: Bool] {
            if keywords["$seen"] == true { flags.insert(.seen) }
            if keywords["$flagged"] == true { flags.insert(.flagged) }
            if keywords["$answered"] == true { flags.insert(.answered) }
            if keywords["$draft"] == true { flags.insert(.draft) }
        }
        if email["hasAttachment"] as? Bool == true { flags.insert(.hasAttachment) }

        // Body extraction: bodyValues is { partId: { value: "...", ... } }.
        // textBody / htmlBody arrays say which partIds belong to each kind.
        let bodyValues = email["bodyValues"] as? [String: [String: Any]] ?? [:]
        let textPartIDs = (email["textBody"] as? [[String: Any]])?.compactMap { $0["partId"] as? String } ?? []
        let htmlPartIDs = (email["htmlBody"] as? [[String: Any]])?.compactMap { $0["partId"] as? String } ?? []
        let plainBody = textPartIDs.compactMap { bodyValues[$0]?["value"] as? String }.first
                        ?? (email["preview"] as? String)
        let htmlBody = htmlPartIDs.compactMap { bodyValues[$0]?["value"] as? String }.first

        return IngestMessage(
            accountID: localAccountID,
            folder: folder,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            fromAddress: from,
            toAddresses: to,
            ccAddresses: cc,
            date: date,
            sizeBytes: sizeBytes,
            flags: flags,
            plainBody: plainBody,
            htmlBody: htmlBody,
            attachments: []   // JMAP attachments via Email/get downloadUrl come in 3A.2
        )
    }

    private func firstEmailAddress(_ raw: Any?) -> String? {
        guard let arr = raw as? [[String: Any]],
              let first = arr.first,
              let email = first["email"] as? String
        else { return nil }
        return email.lowercased()
    }

    private func emailAddresses(_ raw: Any?) -> [String] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { ($0["email"] as? String)?.lowercased() }
    }

    /// JMAP UTC dates are ISO-8601 with optional fractional seconds and "Z".
    private func parseJMAPDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}
