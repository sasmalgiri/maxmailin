import Foundation

/// One resolved correspondent. `canonical` is the address we use for
/// display + analytics; `aliases` are every other address (subaddress
/// variants, casing differences) that maps to the same human.
/// `messageCount` is the sum across the cluster.
public struct CorrespondentIdentity: Sendable, Codable, Hashable {
    public let canonical: String
    public let displayName: String?
    public let aliases: [String]
    public let messageCount: Int64

    public init(canonical: String, displayName: String?,
                aliases: [String], messageCount: Int64) {
        self.canonical = canonical
        self.displayName = displayName
        self.aliases = aliases
        self.messageCount = messageCount
    }
}

/// Cross-message identity resolution. Given raw `From:` header values
/// like `"Alice" <alex+work@acme.com>` and `Alex Morgan <alex@acme.com>`,
/// recognise that they refer to the same human and produce a
/// canonical correspondent record.
///
/// Scope decisions for this v1:
/// - **Address-driven only.** The normalisation rules below cover the
///   common dedup wins (subaddress, case-fold, dot-folding for the
///   gmail-style local part) without leaning on a full
///   KnowledgeGraph. Name-only merging without an address signal is
///   intentionally disabled — too many false positives in casual
///   mail corpora.
/// - **No NaturalLanguage dependency yet.** Embedding-based name
///   similarity is a future slice; this resolver is offline-pure
///   String-only Swift so it can run inside a MainActor without
///   importing NL on every analytics refresh.
public enum EntityResolver {

    /// Parse a single header value into its address + display name
    /// components. Returns nil when the input doesn't contain an
    /// address. Tolerant of:
    ///   - `alex@acme.com`
    ///   - `Alex Morgan <alex@acme.com>`
    ///   - `"Alex Morgan" <alex@acme.com>`
    ///   - `  alex@acme.com  ` (leading/trailing whitespace)
    public static func parse(_ raw: String) -> (address: String, displayName: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let open = trimmed.firstIndex(of: "<"),
           let close = trimmed[open...].firstIndex(of: ">") {
            let address = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            let namePart = String(trimmed[..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard address.contains("@") else { return nil }
            return (address, namePart.isEmpty ? nil : namePart)
        }
        if trimmed.contains("@") {
            return (trimmed, nil)
        }
        return nil
    }

    /// Normalise an address so dedup catches alias forms. Rules:
    ///   - Case-fold the whole address (RFC 5321 says the local part
    ///     is case-sensitive but virtually nobody uses that in
    ///     practice; folding wins more dedup than it loses).
    ///   - Strip a `+suffix` subaddress from the local part.
    ///   - Strip dots from the local part *only* when the domain is
    ///     gmail.com / googlemail.com (where Google itself does this).
    public static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        guard let at = lowered.firstIndex(of: "@") else { return lowered }
        var local = String(lowered[..<at])
        let domain = String(lowered[lowered.index(after: at)...])

        if let plus = local.firstIndex(of: "+") {
            local = String(local[..<plus])
        }
        if domain == "gmail.com" || domain == "googlemail.com" {
            local = local.replacingOccurrences(of: ".", with: "")
        }
        return "\(local)@\(domain)"
    }

    /// Resolve a list of raw header rows into deduplicated identities.
    /// The display name we keep is the longest non-empty name observed
    /// across the cluster — pragmatic proxy for "the version with the
    /// most signal" without picking arbitrarily.
    public static func resolve(
        _ rows: [MailStore.CorrespondentRow]
    ) -> [CorrespondentIdentity] {
        struct Bucket {
            var canonical: String
            var displayName: String?
            var aliases = Set<String>()
            var count: Int64 = 0
        }
        var buckets: [String: Bucket] = [:]

        for row in rows {
            guard let parsed = parse(row.rawHeaderValue) else { continue }
            let key = normalize(parsed.address)
            var b = buckets[key] ?? Bucket(canonical: key, displayName: nil)
            b.aliases.insert(parsed.address.lowercased())
            if let name = parsed.displayName,
               (b.displayName?.count ?? 0) < name.count {
                b.displayName = name
            }
            b.count += row.messageCount
            buckets[key] = b
        }

        // Order: descending by message count, then alphabetical.
        return buckets.values
            .map { CorrespondentIdentity(
                canonical: $0.canonical,
                displayName: $0.displayName,
                aliases: $0.aliases.sorted(),
                messageCount: $0.count
            )}
            .sorted { lhs, rhs in
                lhs.messageCount != rhs.messageCount
                    ? lhs.messageCount > rhs.messageCount
                    : lhs.canonical < rhs.canonical
            }
    }
}
