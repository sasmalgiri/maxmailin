import Foundation

/// Local persisted draft. JMAP-backed draft auto-sync (Email/set into the
/// Drafts mailbox) is a future Phase — for now we serialize one in-progress
/// draft to UserDefaults so the user doesn't lose work if the sheet closes.
public struct ComposeDraft: Codable, Sendable, Equatable {
    public var to: String
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: [String]
    public var savedAt: Date

    public init(
        to: String = "",
        subject: String = "",
        body: String = "",
        inReplyTo: String? = nil,
        references: [String] = [],
        savedAt: Date = Date()
    ) {
        self.to = to
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.savedAt = savedAt
    }

    public var hasContent: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ComposePrefill {

    public enum Mode {
        case reply, replyAll, forward
    }

    /// Pure (testable) prefill builder. Doesn't touch any storage; given the
    /// original message's headers + body + threading chain, produces a
    /// ComposeDraft ready to drop into the compose form.
    public static func build(
        mode: Mode,
        originalSubject: String,
        originalFrom: String,
        originalTo: [String],
        originalCc: [String],
        originalDate: Date,
        originalBody: String,
        originalMessageID: String,
        originalReferences: [String],
        currentUserAddress: String
    ) -> ComposeDraft {
        let recipients: [String]
        switch mode {
        case .reply:
            recipients = [originalFrom]
        case .replyAll:
            let pool = ([originalFrom] + originalTo + originalCc)
                .map { $0.lowercased() }
                .filter { !$0.isEmpty && $0 != currentUserAddress.lowercased() }
            var seen = Set<String>()
            recipients = pool.filter { seen.insert($0).inserted }
        case .forward:
            recipients = []
        }
        let subject: String = {
            let s = originalSubject.trimmingCharacters(in: .whitespaces)
            switch mode {
            case .reply, .replyAll:
                return s.lowercased().hasPrefix("re:") ? s : "Re: \(s)"
            case .forward:
                return s.lowercased().hasPrefix("fwd:")
                    || s.lowercased().hasPrefix("fw:")
                    ? s : "Fwd: \(s)"
            }
        }()
        let body = quotedBody(
            mode: mode,
            originalFrom: originalFrom,
            originalDate: originalDate,
            originalTo: originalTo,
            originalSubject: originalSubject,
            originalBody: originalBody
        )
        let inReplyTo: String? = {
            switch mode {
            case .reply, .replyAll: return originalMessageID.isEmpty ? nil : originalMessageID
            case .forward:          return nil
            }
        }()
        let references: [String] = {
            switch mode {
            case .reply, .replyAll:
                return originalReferences + (originalMessageID.isEmpty ? [] : [originalMessageID])
            case .forward:
                return []
            }
        }()
        return ComposeDraft(
            to: recipients.joined(separator: ", "),
            subject: subject,
            body: body,
            inReplyTo: inReplyTo,
            references: references
        )
    }

    private static func quotedBody(
        mode: Mode,
        originalFrom: String,
        originalDate: Date,
        originalTo: [String],
        originalSubject: String,
        originalBody: String
    ) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let when = df.string(from: originalDate)
        switch mode {
        case .reply, .replyAll:
            let quoted = originalBody
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }
                .joined(separator: "\n")
            return "\n\nOn \(when), \(originalFrom) wrote:\n\(quoted)\n"
        case .forward:
            var header = "\n\n--- Forwarded message ---\n"
            header += "From: \(originalFrom)\n"
            header += "Date: \(when)\n"
            if !originalTo.isEmpty {
                header += "To: \(originalTo.joined(separator: ", "))\n"
            }
            header += "Subject: \(originalSubject)\n\n"
            return header + originalBody
        }
    }
}

/// Persistent slot for one in-progress draft. Cheap UserDefaults blob —
/// fine for crash recovery / sheet-close survival.
public enum ComposeDraftStore {
    private static let key = "maxmailin.compose.draft.v1"

    public static func save(_ draft: ComposeDraft) {
        guard draft.hasContent else { clear(); return }
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public static func load() -> ComposeDraft? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let d = try? JSONDecoder().decode(ComposeDraft.self, from: data),
              d.hasContent
        else { return nil }
        return d
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
