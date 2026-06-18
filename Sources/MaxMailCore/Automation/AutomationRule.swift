import Foundation

/// One automation rule. Conditions and actions are intentionally minimal —
/// covers the 80 % of mail-rule use cases (sender match / subject keyword /
/// flag changes / move to folder) without trying to be a query DSL.
public struct AutomationRule: Sendable, Identifiable, Equatable {
    public let id: Int64
    public var accountID: Int64
    public var name: String
    public var enabled: Bool
    public var priority: Int        // higher first
    public var conditions: RuleConditions
    public var actions: RuleActions
    public let createdAt: Date

    public init(
        id: Int64 = 0,
        accountID: Int64,
        name: String,
        enabled: Bool = true,
        priority: Int = 0,
        conditions: RuleConditions,
        actions: RuleActions,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.conditions = conditions
        self.actions = actions
        self.createdAt = createdAt
    }
}

public struct RuleConditions: Sendable, Codable, Equatable {
    public var fromContains:    [String]    // case-insensitive substring on from_addr
    public var subjectContains: [String]    // case-insensitive substring on subject
    public var bodyContains:    [String]    // matches plain body
    public var hasAttachment:   Bool?       // nil = don't care
    public var combinator:      Combinator  // .and / .or across all populated condition lists

    public enum Combinator: String, Sendable, Codable { case and, or }

    public init(
        fromContains: [String] = [],
        subjectContains: [String] = [],
        bodyContains: [String] = [],
        hasAttachment: Bool? = nil,
        combinator: Combinator = .and
    ) {
        self.fromContains = fromContains
        self.subjectContains = subjectContains
        self.bodyContains = bodyContains
        self.hasAttachment = hasAttachment
        self.combinator = combinator
    }
}

public struct RuleActions: Sendable, Codable, Equatable {
    public var markSeen:      Bool
    public var markFlagged:   Bool
    public var moveToFolder:  String?

    public init(markSeen: Bool = false, markFlagged: Bool = false,
                moveToFolder: String? = nil) {
        self.markSeen = markSeen
        self.markFlagged = markFlagged
        self.moveToFolder = moveToFolder
    }

    /// True when the action list would do nothing — handy for filtering
    /// out malformed rules before saving.
    public var isEmpty: Bool {
        !markSeen && !markFlagged && (moveToFolder?.isEmpty ?? true)
    }
}

/// Evaluator — pure function over (rule, message snapshot). Used both at
/// the storage layer (during sweepRules) and as a UI preview helper.
public enum RuleMatcher {

    /// Snapshot of the fields a rule can inspect. Built from a
    /// MessageHeader + body in MailStore.
    public struct MessageSnapshot: Sendable {
        public let subject: String
        public let fromAddress: String
        public let plainBody: String
        public let hasAttachment: Bool
        public init(subject: String, fromAddress: String,
                    plainBody: String, hasAttachment: Bool) {
            self.subject = subject
            self.fromAddress = fromAddress
            self.plainBody = plainBody
            self.hasAttachment = hasAttachment
        }
    }

    public static func matches(_ rule: AutomationRule, _ msg: MessageSnapshot) -> Bool {
        guard rule.enabled else { return false }
        let c = rule.conditions
        var verdicts: [Bool] = []

        if !c.fromContains.isEmpty {
            verdicts.append(c.fromContains.contains { msg.fromAddress.localizedCaseInsensitiveContains($0) })
        }
        if !c.subjectContains.isEmpty {
            verdicts.append(c.subjectContains.contains { msg.subject.localizedCaseInsensitiveContains($0) })
        }
        if !c.bodyContains.isEmpty {
            verdicts.append(c.bodyContains.contains { msg.plainBody.localizedCaseInsensitiveContains($0) })
        }
        if let attach = c.hasAttachment {
            verdicts.append(msg.hasAttachment == attach)
        }
        guard !verdicts.isEmpty else { return false }   // a rule with no conditions matches nothing
        return c.combinator == .and ? verdicts.allSatisfy { $0 } : verdicts.contains(true)
    }
}
