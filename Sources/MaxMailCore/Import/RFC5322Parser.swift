import Foundation

/// Parsed view of a single RFC 5322 message — enough to feed `IngestMessage`.
/// MIME multipart, encoded-word subjects, and attachment extraction are
/// intentionally minimal in this first cut; they'll grow in Phase 2E.
public struct ParsedMessage: Sendable {
    public var messageID: String      // synthesized if the message had no Message-ID
    public var inReplyTo: String?
    public var references: [String]
    public var subject: String
    public var fromAddress: String
    public var toAddresses: [String]
    public var ccAddresses: [String]
    public var date: Date             // falls back to fileMTime if header was missing/garbled
    public var plainBody: String?
    public var htmlBody: String?
    public var sizeBytes: Int64
}

public enum RFC5322Parser {

    /// Parse a single message buffer (one mbox entry, post-unescape).
    /// `fallbackDate` is used when the message has no parseable Date header —
    /// usually the file's mtime, so even malformed mail still timelines correctly.
    public static func parse(_ raw: Data, fallbackDate: Date) -> ParsedMessage {
        let (headerBytes, bodyBytes) = splitHeaderBody(raw)
        let headers = decodeHeaders(headerBytes)

        let messageID = headers["message-id"].flatMap(normalizeMessageID)
            ?? "<synth-\(hash(raw))@maxmailin.local>"

        let inReplyTo = headers["in-reply-to"].flatMap(normalizeMessageID)

        let references = (headers["references"] ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { normalizeMessageID(String($0)) }

        let subject = decodeEncodedWords(headers["subject"] ?? "")
        let fromAddr = (headers["from"]).flatMap { addressList($0).first } ?? ""
        let to = addressList(headers["to"] ?? "")
        let cc = addressList(headers["cc"] ?? "")

        let date = parseDate(headers["date"]) ?? fallbackDate

        // Body decoding: this first cut treats the entire body as plain text.
        // MIME multipart parsing comes in Phase 2E.
        let plain = decodeBodyAsText(bodyBytes)

        return ParsedMessage(
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            fromAddress: fromAddr,
            toAddresses: to,
            ccAddresses: cc,
            date: date,
            plainBody: plain,
            htmlBody: nil,
            sizeBytes: Int64(raw.count)
        )
    }

    // MARK: - Header / body split

    /// Split on the first blank line (\n\n or \r\n\r\n).
    static func splitHeaderBody(_ raw: Data) -> (headers: Data, body: Data) {
        let n = raw.count
        var i = 0
        while i + 1 < n {
            // Look for "\n\n" or "\r\n\r\n"
            if raw[raw.startIndex + i] == 0x0A && raw[raw.startIndex + i + 1] == 0x0A {
                return (raw.subdata(in: raw.startIndex..<(raw.startIndex + i)),
                        raw.subdata(in: (raw.startIndex + i + 2)..<raw.endIndex))
            }
            if i + 3 < n &&
                raw[raw.startIndex + i] == 0x0D &&
                raw[raw.startIndex + i + 1] == 0x0A &&
                raw[raw.startIndex + i + 2] == 0x0D &&
                raw[raw.startIndex + i + 3] == 0x0A {
                return (raw.subdata(in: raw.startIndex..<(raw.startIndex + i)),
                        raw.subdata(in: (raw.startIndex + i + 4)..<raw.endIndex))
            }
            i += 1
        }
        return (raw, Data())
    }

    // MARK: - Header decoding (lowercased keys, folded continuations joined)

    static func decodeHeaders(_ headerBytes: Data) -> [String: String] {
        guard let text = String(data: headerBytes, encoding: .utf8)
                ?? String(data: headerBytes, encoding: .isoLatin1) else {
            return [:]
        }

        var out: [String: String] = [:]
        var currentKey: String?
        var currentValue: String = ""

        func flush() {
            if let k = currentKey {
                // First field wins. mbox occasionally has both "From " line and "From:" header.
                if out[k] == nil {
                    out[k] = currentValue.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        // mbox keeps the leading "From " envelope line in headerBytes.
        // We skip it because it's not a real RFC 5322 field.
        let allLines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }

        for sub in allLines {
            let line = String(sub)
            if line.isEmpty { continue }
            if line.hasPrefix("From ") && currentKey == nil { continue }

            // Folded continuation: starts with WS.
            if let first = line.first, first == " " || first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            // New field.
            flush()
            if let colon = line.firstIndex(of: ":") {
                currentKey = line[line.startIndex..<colon].lowercased()
                currentValue = String(line[line.index(after: colon)..<line.endIndex])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                currentKey = nil
                currentValue = ""
            }
        }
        flush()
        return out
    }

    /// Message-ID-style identifiers (Message-ID, In-Reply-To, References).
    /// Returns them in `<unique@domain>` form, preserving brackets if present,
    /// adding them if missing, lower-casing the contents.
    static func normalizeMessageID(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if let lt = t.firstIndex(of: "<"), let gt = t.firstIndex(of: ">"), gt > lt {
            let inner = t[t.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces).lowercased()
            if inner.isEmpty { return nil }
            return "<\(inner)>"
        }
        if t.contains("@") && !t.contains(" ") {
            return "<\(t.lowercased())>"
        }
        return nil
    }

    // MARK: - Address parsing

    /// Pull the angle-addr from things like "Display Name <user@host>",
    /// "user@host", "<user@host>", "Display Name (comment) <user@host>".
    /// Lower-cases the result.
    static func extractAngleAddr(_ s: String) -> String? {
        if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), gt > lt {
            let inner = s[s.index(after: lt)..<gt]
            let t = inner.trimmingCharacters(in: .whitespaces).lowercased()
            return t.isEmpty ? nil : t
        }
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.contains("@") && !t.contains(" ") { return t }
        return nil
    }

    /// Split a header value into individual addresses. Naive comma split —
    /// good enough for the common case; doesn't yet honor commas inside
    /// quoted display names.
    static func addressList(_ s: String) -> [String] {
        s.split(separator: ",")
            .compactMap { extractAngleAddr(String($0)) }
    }

    // MARK: - RFC 2047 encoded-word ("=?charset?Q?...?=" or "=?charset?B?...?=")

    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        // Single-pass scan: find =?...?=  and decode.
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if i < s.endIndex, s[i] == "=",
               s.index(after: i) < s.endIndex, s[s.index(after: i)] == "?",
               let close = s.range(of: "?=", range: s.index(after: i)..<s.endIndex) {
                let inside = s[s.index(i, offsetBy: 2)..<close.lowerBound]
                let parts = inside.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    let charset = String(parts[0]).lowercased()
                    let enc = String(parts[1]).uppercased()
                    let payload = String(parts[2])
                    if let decoded = decodeEncodedWordPayload(payload: payload, encoding: enc, charset: charset) {
                        out.append(decoded)
                        i = close.upperBound
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEncodedWordPayload(payload: String, encoding: String, charset: String) -> String? {
        let data: Data?
        if encoding == "B" {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else if encoding == "Q" {
            data = decodeQuotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
        } else {
            return nil
        }
        guard let d = data else { return nil }
        let cf = stringEncoding(forCharset: charset)
        return String(data: d, encoding: cf) ?? String(data: d, encoding: .isoLatin1)
    }

    private static func decodeQuotedPrintable(_ s: String) -> Data? {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D && i + 2 < bytes.count {  // '='
                let h1 = bytes[i + 1], h2 = bytes[i + 2]
                if h1 == 0x0D && h2 == 0x0A {
                    i += 3; continue   // soft line break
                }
                if let hi = hexNibble(h1), let lo = hexNibble(h2) {
                    out.append(UInt8(hi << 4 | lo))
                    i += 3; continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    @inline(__always)
    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    private static func stringEncoding(forCharset charset: String) -> String.Encoding {
        switch charset {
        case "utf-8", "utf8":             return .utf8
        case "iso-8859-1", "latin1":      return .isoLatin1
        case "us-ascii", "ascii":         return .ascii
        case "windows-1252":              return .windowsCP1252
        case "iso-8859-2":                return .isoLatin2
        default:                          return .utf8
        }
    }

    // MARK: - Date parsing (RFC 5322, with a few common deviations)

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        // Strip parenthesized comments like "Mon, 1 Jan 2024 12:00:00 +0000 (UTC)"
        var cleaned = s
        while let open = cleaned.firstIndex(of: "("),
              let close = cleaned[open...].firstIndex(of: ")") {
            cleaned.removeSubrange(open...close)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        for fmt in dateFormats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            if let d = df.date(from: cleaned) { return d }
        }
        return nil
    }

    private static let dateFormats: [String] = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
    ]

    // MARK: - Body decoding

    private static func decodeBodyAsText(_ body: Data) -> String? {
        if body.isEmpty { return nil }
        if let s = String(data: body, encoding: .utf8) { return s }
        if let s = String(data: body, encoding: .isoLatin1) { return s }
        return nil
    }

    private static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in data.prefix(2048) {
            h ^= UInt64(byte)
            h &*= prime
        }
        return String(h, radix: 16)
    }
}
