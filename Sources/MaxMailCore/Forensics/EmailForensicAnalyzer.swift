import Foundation

/// Stateless forensic checks: phishing heuristics + PII regex sweep.
/// Ported from `mailin/EmailNLPEngine.swift` and trimmed to the rules we can
/// evaluate from what MaxMailCore stores today (subject, from, plain, html).
public enum EmailForensicAnalyzer {

    public static func analyze(
        subject: String,
        fromAddress: String,
        plainBody: String?,
        htmlBody: String?
    ) -> ForensicResult {
        let phishing = detectPhishing(
            subject: subject,
            fromAddress: fromAddress,
            plainBody: plainBody ?? "",
            htmlBody: htmlBody ?? ""
        )
        let pii = detectPII(plainBody: plainBody ?? "", htmlBody: htmlBody ?? "")
        return ForensicResult(phishing: phishing, pii: pii)
    }

    // MARK: - Phishing

    private static let urgencyPhrases: [String] = [
        "urgent", "act now", "immediately", "suspended", "verify your account",
        "confirm your identity", "unusual activity", "security alert",
        "unauthorized", "compromised", "account is locked", "will expire",
        "limited time", "within 24 hours", "within 48 hours",
    ]

    private static let credentialPhrases: [String] = [
        "click here to verify", "enter your password", "update your payment",
        "confirm your details", "click the link below", "won a prize",
        "lottery", "inherit", "million dollars", "wire transfer",
        "western union", "send money", "bitcoin wallet", "cryptocurrency",
        "social security number", "bank account details",
    ]

    private static let urlShorteners: [String] = [
        "bit.ly", "tinyurl.com", "goo.gl", "t.co", "ow.ly", "is.gd",
        "buff.ly", "rebrand.ly", "shorturl.at",
    ]

    /// Brand keywords that, when they show up in the subject but the sender
    /// is not on that brand's domain, are classic impersonation tells.
    private static let brandDomains: [String: [String]] = [
        "paypal":    ["paypal.com"],
        "apple":     ["apple.com", "icloud.com"],
        "amazon":    ["amazon.com", "amazon.co.uk"],
        "microsoft": ["microsoft.com", "outlook.com", "live.com"],
        "google":    ["google.com", "gmail.com"],
        "netflix":   ["netflix.com"],
        "facebook":  ["facebook.com", "fb.com"],
        "linkedin":  ["linkedin.com"],
        "dropbox":   ["dropbox.com"],
        "docusign":  ["docusign.com"],
    ]

    public static func detectPhishing(
        subject: String,
        fromAddress: String,
        plainBody: String,
        htmlBody: String
    ) -> PhishingFinding {
        var score = 0
        var reasons: [PhishingReason] = []
        let subj = subject.lowercased()
        let body = plainBody.lowercased()
        let html = htmlBody.lowercased()
        let bodySample = String(body.prefix(2000))
        let fromDomain = fromAddress
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            .last.map(String.init)?.lowercased() ?? ""

        // Urgency in subject or first 2 KB of body.
        for phrase in urgencyPhrases where subj.contains(phrase) || bodySample.contains(phrase) {
            reasons.append(PhishingReason(kind: .urgency, detail: phrase, weight: 2))
            score += 2
        }

        // Credential harvesting phrases in the body.
        for phrase in credentialPhrases where bodySample.contains(phrase) {
            reasons.append(PhishingReason(kind: .credentialHarvest, detail: phrase, weight: 3))
            score += 3
        }

        // Brand impersonation: subject mentions brand but the sender is on
        // some unrelated domain (the well-known brand domains aren't in the
        // sender, so it's not really the brand).
        for (brand, legitimateDomains) in brandDomains {
            if subj.contains(brand)
                && !fromDomain.isEmpty
                && !legitimateDomains.contains(where: { fromDomain.hasSuffix($0) }) {
                reasons.append(PhishingReason(
                    kind: .brandImpersonation,
                    detail: "subject mentions \(brand), sender is \(fromDomain)",
                    weight: 4
                ))
                score += 4
                break  // one is enough; otherwise we'd double-count
            }
        }

        // Suspicious URLs in either body. We scan the html source too because
        // attacker bodies often hide the giveaway URL inside an <a href>.
        let textForURLScan = body + " " + html
        if textForURLScan.range(of: #"https?://\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#,
                                options: .regularExpression) != nil {
            reasons.append(PhishingReason(kind: .urlRawIP, detail: "URL with raw IP address", weight: 3))
            score += 3
        }
        if textForURLScan.range(of: #"https?://[^\s]*@[^\s]+"#,
                                options: .regularExpression) != nil {
            reasons.append(PhishingReason(kind: .urlAtSymbol, detail: "URL with @ (redirect)", weight: 3))
            score += 3
        }
        for shortener in urlShorteners where textForURLScan.contains(shortener) {
            reasons.append(PhishingReason(kind: .urlShortener, detail: shortener, weight: 1))
            score += 1
            break  // single occurrence is enough to flag
        }

        // HTML link-text mismatch: <a href="evil.com">paypal.com</a>
        let mismatchRegex = #"<a[^>]*href=["']https?://([^/"']+)[^>]*>\s*https?://([^<\s/]+)"#
        if let range = html.range(of: mismatchRegex, options: .regularExpression) {
            let snippet = String(html[range])
            // Pull the two domains back out so we only flag actual mismatches.
            let hrefDomain = firstCapture(in: snippet,
                                          pattern: #"href=["']https?://([^/"']+)"#)?.lowercased()
            let textDomain = firstCapture(in: snippet,
                                          pattern: #">\s*https?://([^<\s/]+)"#)?.lowercased()
            if let h = hrefDomain, let t = textDomain, h != t {
                reasons.append(PhishingReason(
                    kind: .linkTextMismatch,
                    detail: "anchor text shows \(t), actual href is \(h)",
                    weight: 4
                ))
                score += 4
            }
        }

        let level: PhishingFinding.RiskLevel
        switch score {
        case 0...3:   level = .none
        case 4...6:   level = .low
        case 7...9:   level = .medium
        default:      level = .high
        }
        return PhishingFinding(level: level, score: score, reasons: reasons)
    }

    // MARK: - PII

    private struct PIIPattern { let kind: PIIFinding.Kind; let regex: NSRegularExpression }

    private static let piiPatterns: [PIIPattern] = {
        let raw: [(PIIFinding.Kind, String)] = [
            (.email,      #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
            (.phone,      #"(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}"#),
            (.ssn,        #"\b(?!000|666|9\d{2})\d{3}[-\s](?!00)\d{2}[-\s](?!0000)\d{4}\b"#),
            (.creditCard, #"\b(?:\d{4}[-\s]?){3}\d{4}\b"#),
            (.ipAddress,  #"\b(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\b"#),
            (.iban,       #"\b[A-Z]{2}\d{2}\s?[\dA-Z]{4}\s?[\dA-Z]{4}\s?[\dA-Z]{4}(?:\s?[\dA-Z]{4}){0,4}\s?[\dA-Z]{0,4}\b"#),
        ]
        return raw.compactMap { kind, pat in
            guard let r = try? NSRegularExpression(pattern: pat) else { return nil }
            return PIIPattern(kind: kind, regex: r)
        }
    }()

    public static func detectPII(plainBody: String, htmlBody: String) -> [PIIFinding] {
        // We strip the HTML before merging so phone-number-looking digits
        // inside CSS or hex colors don't get falsely flagged. Cheap tag strip
        // is fine; nothing precise needed here.
        let strippedHTML = stripTags(htmlBody)
        let text = plainBody + "\n" + strippedHTML

        var counts: [PIIFinding.Kind: Int] = [:]
        var seenPerKind: [PIIFinding.Kind: Set<String>] = [:]
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        for pattern in piiPatterns {
            let matches = pattern.regex.matches(in: text, range: fullRange)
            for match in matches {
                let raw = nsText.substring(with: match.range)
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }

                // Credit cards: require a valid Luhn checksum so we don't
                // falsely flag four arbitrary 4-digit groupings.
                if pattern.kind == .creditCard {
                    let digits = normalized.filter(\.isNumber)
                    guard (13...19).contains(digits.count), luhnCheck(digits) else { continue }
                }

                // IP addresses: drop private and loopback ranges.
                if pattern.kind == .ipAddress, isPrivateOrReservedIP(normalized) {
                    continue
                }

                if seenPerKind[pattern.kind, default: []].insert(normalized).inserted {
                    counts[pattern.kind, default: 0] += 1
                }
            }
        }
        return counts.map { PIIFinding(kind: $0.key, count: $0.value) }
            .sorted { $0.kind.severity > $1.kind.severity }
    }

    // MARK: - Helpers

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func luhnCheck(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard let d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    private static func isPrivateOrReservedIP(_ s: String) -> Bool {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        if parts == [0, 0, 0, 0] { return true }
        if parts[0] == 127 { return true }              // loopback
        if parts[0] == 10 { return true }               // private 10/8
        if parts[0] == 192 && parts[1] == 168 { return true }  // 192.168/16
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true } // 172.16/12
        if parts[0] == 169 && parts[1] == 254 { return true }  // link-local
        return false
    }

    private static func stripTags(_ html: String) -> String {
        var out = ""
        var inTag = false
        for ch in html {
            if inTag { if ch == ">" { inTag = false } }
            else     { if ch == "<" { inTag = true } else { out.append(ch) } }
        }
        return out
    }
}
