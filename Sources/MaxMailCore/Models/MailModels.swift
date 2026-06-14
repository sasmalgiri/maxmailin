import Foundation

/// An attachment to be ingested. If `data` is non-nil it's content-addressed
/// into the BlobStore (duplicates dedupe automatically). If `data` is nil the
/// attachment is recorded by name only — useful for archive imports where the
/// bytes will be fetched on demand from the original mbox/eml later.
public struct AttachmentIn: Sendable {
    public let filename: String
    public let mimeType: String?
    public let data: Data?

    public init(filename: String, mimeType: String? = nil, data: Data? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// Read-back record of an attachment row.
public struct AttachmentRef: Sendable, Identifiable {
    public let id: Int64
    public let messageRowID: Int64
    public let filename: String
    public let mimeType: String?
    public let sizeBytes: Int64?
    public let sha256Hex: String?
}

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
    public var attachments: [AttachmentIn]

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
        attachments: [AttachmentIn] = []
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
        self.attachments = attachments
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

    public init(
        id: Int64, messageID: String, folder: String,
        subject: String, fromAddress: String, date: Date,
        sizeBytes: Int64, flags: MessageFlags, snippet: String?
    ) {
        self.id = id
        self.messageID = messageID
        self.folder = folder
        self.subject = subject
        self.fromAddress = fromAddress
        self.date = date
        self.sizeBytes = sizeBytes
        self.flags = flags
        self.snippet = snippet
    }
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

// MARK: - Analytics aggregates

public struct AnalysisProgress: Sendable {
    public let analyzed: Int64
    public let total: Int64
    public var percentComplete: Double {
        total == 0 ? 1 : Double(analyzed) / Double(total)
    }
    public init(analyzed: Int64, total: Int64) {
        self.analyzed = analyzed
        self.total = total
    }
}

public struct SentimentDistribution: Sendable {
    public let veryNegative: Int
    public let negative: Int
    public let neutral: Int
    public let positive: Int
    public let veryPositive: Int
    public var total: Int {
        veryNegative + negative + neutral + positive + veryPositive
    }
    public init(veryNegative: Int, negative: Int, neutral: Int, positive: Int, veryPositive: Int) {
        self.veryNegative = veryNegative
        self.negative = negative
        self.neutral = neutral
        self.positive = positive
        self.veryPositive = veryPositive
    }
}

public struct EntityCount: Sendable, Identifiable, Hashable {
    public let entity: EmailEntity
    public let count: Int
    public var id: String { "\(entity.kind.rawValue)|\(entity.text.lowercased())" }
}

public struct KeywordCount: Sendable, Identifiable, Hashable {
    public let keyword: String
    public let count: Int
    public var id: String { keyword }
}

public struct SentimentMonth: Sendable, Identifiable, Hashable {
    public let month: String        // "YYYY-MM"
    public let meanSentiment: Double
    public let messageCount: Int
    public var id: String { month }
}
