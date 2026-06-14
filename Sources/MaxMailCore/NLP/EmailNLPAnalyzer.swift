import Foundation
import NaturalLanguage

/// Pure on-device analysis. No state, no network — safe to call from any
/// actor and parallelize across messages. Backed entirely by Apple's
/// NaturalLanguage framework so it works fully offline.
public enum EmailNLPAnalyzer {

    public static func analyze(text: String, keywordLimit: Int = 12) -> EmailNLP {
        // NLTagger barfs on very long inputs; truncate generously.
        let capped = String(text.prefix(50_000))
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        return EmailNLP(
            sentiment: sentimentScore(capped),
            language: detectLanguage(capped),
            entities: extractEntities(capped),
            keywords: extractKeywords(capped, limit: keywordLimit)
        )
    }

    // MARK: - Sentiment

    /// Returns the mean of per-paragraph sentiment scores in `text`. Apple's
    /// sentiment model produces a single score for each paragraph; averaging
    /// is a reasonable proxy for the message-level tone of a longer email.
    public static func sentimentScore(_ text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        var total: Double = 0
        var count: Int = 0
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .paragraph,
            scheme: .sentimentScore,
            options: []
        ) { tag, _ in
            if let v = tag?.rawValue, let d = Double(v) {
                total += d
                count += 1
            }
            return true
        }
        return count == 0 ? 0 : total / Double(count)
    }

    // MARK: - Language

    public static func detectLanguage(_ text: String) -> String? {
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        return rec.dominantLanguage?.rawValue
    }

    // MARK: - Entities

    public static func extractEntities(_ text: String) -> [EmailEntity] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var seen = Set<String>()
        var out: [EmailEntity] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            guard let tag else { return true }
            let kind: EmailEntity.Kind
            switch tag {
            case .personalName:     kind = .person
            case .organizationName: kind = .organization
            case .placeName:        kind = .place
            default:                return true
            }
            let token = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(kind.rawValue)|\(token.lowercased())"
            guard token.count >= 2, !seen.contains(key) else { return true }
            seen.insert(key)
            out.append(EmailEntity(kind: kind, text: token))
            return true
        }
        return out
    }

    // MARK: - Keywords

    private static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "from", "this", "that",
        "have", "has", "are", "was", "were", "but", "not", "can", "will",
        "would", "should", "could", "into", "than", "they", "their", "them",
        "our", "ours", "out", "any", "all", "some", "more", "most", "such",
        "also", "just", "very", "even", "much", "many", "few", "now", "then",
        "here", "there", "when", "where", "while", "what", "which", "who",
        "whom", "why", "how", "let", "yet", "etc", "amp", "via",
    ]

    public static func extractKeywords(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        var freq: [String: Int] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation, .omitOther]
        ) { tag, range in
            guard tag == .noun else { return true }
            // Prefer the lemma so plural/singular collapse together.
            let lemmaTag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
            let base = (lemmaTag?.rawValue ?? String(text[range])).lowercased()
            guard base.count >= 4, !stopWords.contains(base),
                  base.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "-" })
            else { return true }
            freq[base, default: 0] += 1
            return true
        }
        return freq.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        .prefix(limit)
        .map { $0.key }
    }
}
