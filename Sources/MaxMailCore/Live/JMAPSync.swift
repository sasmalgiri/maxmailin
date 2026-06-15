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
                    "bodyValues", "attachments"
                ],
                "fetchTextBodyValues": true,
                "fetchHTMLBodyValues": true,
                "maxBodyValueBytes": 1_048_576
            ], "g"]
        ])

        guard let getArgs = result.first(method: "Email/get"),
              let emails = getArgs["list"] as? [[String: Any]]
        else { throw JMAPError.invalidResponse("Email/get missing list") }

        // Seed the sync cursor so a subsequent syncIncremental can run
        // Email/changes from this point forward.
        if let newState = getArgs["state"] as? String {
            try await store.setSyncState(
                accountID: localAccountID,
                scope: "email:\(jmapAccountID)",
                state: newState
            )
        }

        let resolvedFolder = folderName ?? mailbox.name
        var ingested = 0
        var skipped  = 0
        for entry in emails {
            guard let msg = ingestMessage(from: entry, folder: resolvedFolder),
                  let jmapEmailID = entry["id"] as? String else { continue }
            // Check if the RFC 5322 Message-ID already exists; ingest() is
            // idempotent on that key, so a pre-existing row means "skipped".
            let preExisting = try await store.lookupMessageRowID(
                accountID: localAccountID, messageID: msg.messageID
            )
            let rowID = try await store.ingest(msg)
            if preExisting == nil { ingested += 1 } else { skipped += 1 }
            try await store.linkJMAP(
                localRowID: rowID,
                jmapAccountID: jmapAccountID,
                jmapEmailID: jmapEmailID
            )
        }
        return (ingested, skipped)
    }

    /// Incremental sync via JMAP Email/changes. Reuses the per-account state
    /// token stored on the local MailStore. If no token is present yet, the
    /// caller should run pullRecent first to seed a baseline.
    ///
    /// Returns counts for each change category. Created entries are pulled
    /// fully (headers + body); updated entries are reduced to keyword diffs
    /// for now (which covers read/star/answer); destroyed entries are deleted
    /// locally.
    @discardableResult
    public func syncIncremental(
        mailboxHint: JMAPMailbox? = nil,
        folderName: String? = nil,
        maxChanges: Int = 200
    ) async throws -> (added: Int, updated: Int, removed: Int) {
        let session = try await client.currentSession()
        guard let jmapAccountID = session.primaryMailAccountID else {
            throw JMAPError.invalidResponse("session has no primary mail account")
        }
        let scopeKey = "email:\(jmapAccountID)"
        guard let sinceState = try await store.syncState(
            accountID: localAccountID, scope: scopeKey
        ) else {
            // No baseline yet — caller should have called pullRecent first.
            throw JMAPError.invalidResponse("no JMAP sync state; run pullRecent first")
        }

        let result = try await client.invoke(methodCalls: [
            ["Email/changes", [
                "accountId":  jmapAccountID,
                "sinceState": sinceState,
                "maxChanges": maxChanges
            ], "c"],
            ["Email/get", [
                "accountId": jmapAccountID,
                "#ids": ["resultOf": "c", "name": "Email/changes", "path": "/created"],
                "properties": [
                    "id", "messageId", "inReplyTo", "references", "subject",
                    "from", "to", "cc", "receivedAt", "size", "keywords",
                    "hasAttachment", "preview", "textBody", "htmlBody",
                    "bodyValues"
                ],
                "fetchTextBodyValues": true,
                "fetchHTMLBodyValues": true,
                "maxBodyValueBytes": 1_048_576
            ], "gnew"],
            ["Email/get", [
                "accountId": jmapAccountID,
                "#ids": ["resultOf": "c", "name": "Email/changes", "path": "/updated"],
                "properties": ["id", "keywords"]
            ], "gupd"]
        ])

        guard let changes = result.first(method: "Email/changes", callID: "c") else {
            throw JMAPError.invalidResponse("missing Email/changes result")
        }
        let newState   = (changes["newState"]  as? String) ?? sinceState
        let created    = (changes["created"]   as? [String]) ?? []
        let updated    = (changes["updated"]   as? [String]) ?? []
        let destroyed  = (changes["destroyed"] as? [String]) ?? []

        // Process creates
        var addedCount = 0
        if !created.isEmpty,
           let newArgs = result.first(method: "Email/get", callID: "gnew"),
           let newList = newArgs["list"] as? [[String: Any]] {
            let resolvedFolder = folderName ?? (mailboxHint?.name ?? "INBOX")
            for entry in newList {
                guard let msg = ingestMessage(from: entry, folder: resolvedFolder),
                      let jmapEmailID = entry["id"] as? String else { continue }
                let rowID = try await store.ingest(msg)
                try await store.linkJMAP(
                    localRowID: rowID,
                    jmapAccountID: jmapAccountID,
                    jmapEmailID: jmapEmailID
                )
                addedCount += 1
            }
        }

        // Process keyword updates
        var updatedCount = 0
        if !updated.isEmpty,
           let updArgs = result.first(method: "Email/get", callID: "gupd"),
           let updList = updArgs["list"] as? [[String: Any]] {
            for entry in updList {
                guard let jid = entry["id"] as? String,
                      let kws = entry["keywords"] as? [String: Bool] else { continue }
                guard let localID = try await store.localRowID(forJMAPEmailID: jid) else { continue }
                let new = Self.flags(from: kws)
                try await store.updateMessageFlags(messageRowID: localID, flags: new)
                updatedCount += 1
            }
        }

        // Process destroys
        var removedCount = 0
        for jid in destroyed {
            guard let localID = try await store.localRowID(forJMAPEmailID: jid) else { continue }
            try await store.deleteMessage(messageRowID: localID)
            removedCount += 1
        }

        try await store.setSyncState(accountID: localAccountID, scope: scopeKey, state: newState)
        return (addedCount, updatedCount, removedCount)
    }

    // MARK: - Attachment download

    /// Pull the blob bytes for one attachment via the session's downloadUrl
    /// template, store them in the MailStore BlobStore (content-addressed,
    /// so identical attachments across messages collapse to one file), and
    /// patch the attachments row with the new sha256 + actual size.
    /// Returns the AttachmentRef with sha256 populated.
    @discardableResult
    public func downloadAttachment(attachmentID: Int64) async throws -> AttachmentRef {
        guard let row = try await store.attachment(id: attachmentID) else {
            throw JMAPError.invalidResponse("no attachment row \(attachmentID)")
        }
        if row.hasLocalBlob { return row }   // already have it
        guard let externalID = row.externalID else {
            throw JMAPError.invalidResponse("attachment \(attachmentID) has no JMAP blobId")
        }
        // Need the JMAP accountId. We pull it from the per-message JMAP map
        // — the attachment belongs to the message identified by row.messageRowID.
        guard let mapping = try await store.jmapEmailID(forLocalRowID: row.messageRowID) else {
            throw JMAPError.invalidResponse("attachment \(attachmentID) is not on a JMAP-synced message")
        }
        let data = try await client.downloadBlob(
            accountID: mapping.jmapAccountID,
            blobID: externalID,
            mimeType: row.mimeType ?? "application/octet-stream",
            filename: row.filename
        )
        let hex = try await store.blobStore.put(data)
        try await store.setAttachmentBlob(
            attachmentID: attachmentID,
            sha256Hex: hex,
            sizeBytes: Int64(data.count)
        )
        return AttachmentRef(
            id: row.id,
            messageRowID: row.messageRowID,
            filename: row.filename,
            mimeType: row.mimeType,
            sizeBytes: Int64(data.count),
            sha256Hex: hex,
            externalID: row.externalID
        )
    }

    // MARK: - Flag writes

    /// Toggle a single JMAP keyword on a message. The server response is the
    /// source of truth — we only update local flags when the update is
    /// confirmed in Email/set.updated.
    public func setKeyword(localRowID: Int64, keyword: String, value: Bool) async throws {
        guard let mapping = try await store.jmapEmailID(forLocalRowID: localRowID) else {
            throw JMAPError.invalidResponse("local row \(localRowID) has no JMAP id")
        }
        // JMAP patch syntax: `keywords/$seen` is the keyword pointer; the
        // value is either true (set) or null (unset). Foundation can't encode
        // NSNull through JSONSerialization safely without a placeholder type,
        // so we send NSNull() which JSONSerialization renders as JSON null.
        let updateValue: Any = value ? true : NSNull()
        let result = try await client.invoke(methodCalls: [
            ["Email/set", [
                "accountId": mapping.jmapAccountID,
                "update": [
                    mapping.jmapEmailID: [
                        "keywords/\(keyword)": updateValue
                    ]
                ]
            ], "u"]
        ])
        guard let args = result.first(method: "Email/set", callID: "u") else {
            throw JMAPError.methodError("no Email/set response")
        }
        if let notUpdated = args["notUpdated"] as? [String: Any],
           let err = notUpdated[mapping.jmapEmailID] {
            throw JMAPError.methodError("Email/set rejected update: \(err)")
        }
        // Reflect locally.
        if var current = try await store.messageFlags(messageRowID: localRowID),
           let bit = Self.localFlag(forKeyword: keyword) {
            if value { current.insert(bit) } else { current.remove(bit) }
            try await store.updateMessageFlags(messageRowID: localRowID, flags: current)
        }
    }

    public func setSeen(localRowID: Int64, _ seen: Bool) async throws {
        try await setKeyword(localRowID: localRowID, keyword: "$seen", value: seen)
    }

    public func setFlagged(localRowID: Int64, _ flagged: Bool) async throws {
        try await setKeyword(localRowID: localRowID, keyword: "$flagged", value: flagged)
    }

    // MARK: - Compose / send

    /// Minimal Email/set + EmailSubmission/set round-trip. The server picks
    /// the first identity it advertises for the account. Returns the created
    /// JMAP email id so callers can link / track delivery later.
    public func sendPlainEmail(
        from sender: String,
        to recipients: [String],
        subject: String,
        body: String
    ) async throws -> String {
        let session = try await client.currentSession()
        guard let jmapAccountID = session.primaryMailAccountID else {
            throw JMAPError.invalidResponse("session has no primary mail account")
        }
        // Find Drafts mailbox + first identity.
        let boxes = try await listMailboxes()
        guard let drafts = boxes.first(where: { $0.role == "drafts" }) else {
            throw JMAPError.invalidResponse("no drafts mailbox on JMAP account")
        }
        let identityResult = try await client.invoke(
            using: [
                "urn:ietf:params:jmap:core",
                "urn:ietf:params:jmap:submission"
            ],
            methodCalls: [
                ["Identity/get", ["accountId": jmapAccountID], "i"]
            ]
        )
        guard let idArgs = identityResult.first(method: "Identity/get", callID: "i"),
              let idList = idArgs["list"] as? [[String: Any]],
              let identity = idList.first,
              let identityID = identity["id"] as? String else {
            throw JMAPError.invalidResponse("JMAP account has no Identity")
        }

        let draftKey = "draft"
        let bodyPartID = "body1"
        let toList: [[String: String]] = recipients.map { ["email": $0] }

        let createDraft: [String: Any] = [
            "accountId": jmapAccountID,
            "create": [
                draftKey: [
                    "mailboxIds": [drafts.id: true],
                    "keywords":   ["$draft": true],
                    "from":       [["email": sender]],
                    "to":         toList,
                    "subject":    subject,
                    "bodyValues": [bodyPartID: ["value": body]],
                    "textBody":   [["partId": bodyPartID, "type": "text/plain"]]
                ]
            ]
        ]
        let submission: [String: Any] = [
            "accountId": jmapAccountID,
            "create": [
                "sub": [
                    "identityId": identityID,
                    "emailId":    "#\(draftKey)",
                    "envelope": [
                        "mailFrom": ["email": sender],
                        "rcptTo":   toList
                    ]
                ]
            ],
            "onSuccessUpdateEmail": [
                "#sub": [
                    "keywords/$draft": NSNull(),
                    "keywords/$seen":  true
                ]
            ]
        ]

        let result = try await client.invoke(
            using: [
                "urn:ietf:params:jmap:core",
                "urn:ietf:params:jmap:mail",
                "urn:ietf:params:jmap:submission"
            ],
            methodCalls: [
                ["Email/set",            createDraft, "draft"],
                ["EmailSubmission/set",  submission,  "submit"]
            ]
        )

        guard let setArgs = result.first(method: "Email/set", callID: "draft"),
              let created = setArgs["created"] as? [String: Any],
              let draftObj = created[draftKey] as? [String: Any],
              let emailID = draftObj["id"] as? String else {
            throw JMAPError.methodError("Email/set did not create draft")
        }
        if let subArgs = result.first(method: "EmailSubmission/set", callID: "submit"),
           let notCreated = subArgs["notCreated"] as? [String: Any],
           !notCreated.isEmpty {
            throw JMAPError.methodError("EmailSubmission rejected: \(notCreated)")
        }
        return emailID
    }

    // MARK: - Flag helpers

    /// Convert a JMAP keywords dictionary into local MessageFlags.
    static func flags(from keywords: [String: Bool]) -> MessageFlags {
        var f: MessageFlags = []
        if keywords["$seen"]     == true { f.insert(.seen) }
        if keywords["$flagged"]  == true { f.insert(.flagged) }
        if keywords["$answered"] == true { f.insert(.answered) }
        if keywords["$draft"]    == true { f.insert(.draft) }
        return f
    }

    static func localFlag(forKeyword keyword: String) -> MessageFlags? {
        switch keyword {
        case "$seen":     return .seen
        case "$flagged":  return .flagged
        case "$answered": return .answered
        case "$draft":    return .draft
        default:          return nil
        }
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

        // JMAP attachments come through as a flat list of part metadata —
        // we keep filename/mime/size and store the blobId as externalID so
        // downloadAttachment can fetch the bytes later via downloadUrl.
        var attachments: [AttachmentIn] = []
        if let arr = email["attachments"] as? [[String: Any]] {
            for entry in arr {
                let name = (entry["name"] as? String) ?? "attachment.bin"
                let mime = entry["type"] as? String
                let blobID = entry["blobId"] as? String
                let size = entry["size"] as? Int
                attachments.append(AttachmentIn(
                    filename: name,
                    mimeType: mime,
                    data: nil,
                    externalID: blobID,
                    sizeHint: size.map(Int64.init)
                ))
            }
        }

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
            attachments: attachments
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
