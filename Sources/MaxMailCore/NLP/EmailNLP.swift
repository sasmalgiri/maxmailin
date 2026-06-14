import Foundation

/// On-device NLP results for a single email. Everything is derived from the
/// message body via Apple's NaturalLanguage framework — no network, no model
/// download — so this is safe to run for every imported message.
public struct EmailNLP: Sendable, Codable, Equatable {
    /// Apple's per-paragraph sentiment score, range [-1.0, 1.0]; negative
    /// values are negative sentiment, positive are positive, ~0 is neutral.
    public let sentiment: Double
    /// BCP-47 dominant language code, e.g., "en", "fr", "ja". Nil when the
    /// text is too short for confident detection.
    public let language: String?
    public let entities: [EmailEntity]
    /// Top noun lemmas by frequency (lower-cased, length-filtered).
    public let keywords: [String]

    public static let empty = EmailNLP(
        sentiment: 0, language: nil, entities: [], keywords: []
    )

    public init(sentiment: Double, language: String?,
                entities: [EmailEntity], keywords: [String]) {
        self.sentiment = sentiment
        self.language = language
        self.entities = entities
        self.keywords = keywords
    }

    public enum Mood: String, Sendable {
        case veryNegative, negative, neutral, positive, veryPositive
    }

    public var mood: Mood {
        switch sentiment {
        case ..<(-0.6): return .veryNegative
        case ..<(-0.2): return .negative
        case ..<0.2:    return .neutral
        case ..<0.6:    return .positive
        default:        return .veryPositive
        }
    }
}

public struct EmailEntity: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case person, organization, place, other
    }
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}
