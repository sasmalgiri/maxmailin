import Foundation

/// A heuristic flag computed from the cross-message context of a single
/// message. Not stored — these are derived on demand from indexed columns.
public struct EmailAnomaly: Sendable, Codable, Hashable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        /// This sender has never written to this account before.
        case firstTimeContact
        /// This sender hasn't written in ≥90 days and just resurfaced.
        case dormantSenderRevival
        /// Message arrived in the small hours of the night (1am – 5am local).
        case offHoursArrival
    }

    public enum Severity: String, Codable, Sendable {
        case info, notable, high
    }

    public let kind: Kind
    public let messageRowID: Int64
    public let detail: String
    public let severity: Severity

    public init(kind: Kind, messageRowID: Int64, detail: String, severity: Severity) {
        self.kind = kind
        self.messageRowID = messageRowID
        self.detail = detail
        self.severity = severity
    }

    public var id: String { "\(kind.rawValue):\(messageRowID)" }
}
