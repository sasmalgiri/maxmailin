import Foundation

/// A parsed message ready to be ingested into the store.
/// Bodies are kept out of memory wherever possible; the caller streams them in.
public struct IngestMessage: Sendable {
    public var accountID: Int64
    public var folder: String
    public var messageID: String          // RFC 822 Message-ID, canonical key
    public var inReplyTo: String?
    public var references: [String]
    public var subject: String
    public var fromAddress: String
    public var toAddresses: [String]
    public var ccAddresses: [String]
    public var date: Date
    public var sizeBytes: Int64
    public var flags: MessageFlags
    public var plainBody: String?         // pass nil if you'll attach a blob ref instead
    public var htmlBody: String?
    public var attachmentNames: [String]

    public init(
        accountID: Int64,
        folder: String,
        messageID: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String,
        fromAddress: String,
        toAddresses: [String] = [],
        ccAddresses: [String] = [],
        date: Date,
        sizeBytes: Int64,
        flags: MessageFlags = [],
        plainBody: String? = nil,
        htmlBody: String? = nil,
        attachmentNames: [String] = []
    ) {
        self.accountID = accountID
        self.folder = folder
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.fromAddress = fromAddress
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.date = date
        self.sizeBytes = sizeBytes
        self.flags = flags
        self.plainBody = plainBody
        self.htmlBody = htmlBody
        self.attachmentNames = attachmentNames
    }
}

public struct MessageFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let seen      = MessageFlags(rawValue: 1 << 0)
    public static let flagged   = MessageFlags(rawValue: 1 << 1)
    public static let answered  = MessageFlags(rawValue: 1 << 2)
    public static let draft     = MessageFlags(rawValue: 1 << 3)
    public static let deleted   = MessageFlags(rawValue: 1 << 4)
    public static let hasAttachment = MessageFlags(rawValue: 1 << 5)
}

/// Lightweight header used to render a list row. Bodies are not loaded.
public struct MessageHeader: Sendable, Identifiable {
    public let id: Int64
    public let messageID: String
    public let folder: String
    public let subject: String
    public let fromAddress: String
    public let date: Date
    public let sizeBytes: Int64
    public let flags: MessageFlags
    public let snippet: String?
}

public struct SearchHit: Sendable, Identifiable {
    public let id: Int64
    public let messageID: String
    public let subject: String
    public let fromAddress: String
    public let date: Date
    public let snippet: String     // FTS5 snippet() output
    public let score: Double       // BM25 rank (lower = better)
}

public struct StoreStats: Sendable {
    public let messageCount: Int64
    public let folderCount: Int64
    public let accountCount: Int64
    public let dbFileBytes: Int64
}
