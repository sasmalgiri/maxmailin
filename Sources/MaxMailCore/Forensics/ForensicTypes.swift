import Foundation

public struct PhishingReason: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case urgency
        case credentialHarvest
        case brandImpersonation
        case urlRawIP
        case urlAtSymbol
        case urlShortener
        case linkTextMismatch
    }
    public let kind: Kind
    public let detail: String
    public let weight: Int

    public init(kind: Kind, detail: String, weight: Int) {
        self.kind = kind
        self.detail = detail
        self.weight = weight
    }
}

public struct PhishingFinding: Sendable, Codable, Equatable {
    public enum RiskLevel: String, Sendable, Codable {
        case none, low, medium, high
    }
    public let level: RiskLevel
    public let score: Int
    public let reasons: [PhishingReason]

    public init(level: RiskLevel, score: Int, reasons: [PhishingReason]) {
        self.level = level
        self.score = score
        self.reasons = reasons
    }

    public static let none = PhishingFinding(level: .none, score: 0, reasons: [])
}

public struct PIIFinding: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case email
        case phone
        case ssn
        case creditCard
        case ipAddress
        case iban

        public var label: String {
            switch self {
            case .email:      return "Email"
            case .phone:      return "Phone"
            case .ssn:        return "SSN"
            case .creditCard: return "Credit card"
            case .ipAddress:  return "IP address"
            case .iban:       return "IBAN"
            }
        }

        /// Heuristic severity used by the detail-pane chip color.
        public var severity: Int {
            switch self {
            case .ssn, .creditCard: return 3
            case .iban, .phone:     return 2
            case .email, .ipAddress: return 1
            }
        }
    }

    public let kind: Kind
    public let count: Int

    public var id: String { kind.rawValue }

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

public struct ForensicResult: Sendable, Codable, Equatable {
    public let phishing: PhishingFinding
    public let pii: [PIIFinding]

    public init(phishing: PhishingFinding, pii: [PIIFinding]) {
        self.phishing = phishing
        self.pii = pii
    }

    public static let empty = ForensicResult(phishing: .none, pii: [])

    /// Total count of PII items across all kinds.
    public var piiTotal: Int { pii.reduce(0) { $0 + $1.count } }
}
