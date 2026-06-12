import Foundation

/// MIME body decoder. Handles multipart/* (mixed, alternative, related, …),
/// nested multiparts, base64 / quoted-printable bodies, and extracts every
/// non-text part as an `AttachmentIn`. The first plain-text and first
/// HTML candidate win; later duplicates are ignored.
public enum MIMEParser {

    public struct ParsedMIME: Sendable {
        public var plainBody: String?
        public var htmlBody: String?
        public var attachments: [AttachmentIn]
    }

    /// Parse a single MIME entity. `headers` is the lowercased header map for
    /// this entity (top-level message *or* a recursive part); `body` is the
    /// raw bytes between the entity's header/body boundary and the next
    /// MIME boundary above it.
    public static func parse(headers: [String: String], body: Data) -> ParsedMIME {
        let contentType = headers["content-type"] ?? "text/plain"
        let ctLower = contentType.lowercased()

        if ctLower.hasPrefix("multipart/") {
            return parseMultipart(contentTypeHeader: contentType, body: body)
        }

        let encoding = (headers["content-transfer-encoding"] ?? "7bit").lowercased()
        let decoded = decode(body, encoding: encoding)
        let cd = headers["content-disposition"]

        // Attachment? Either explicitly tagged via Content-Disposition, or it's
        // a non-text MIME type living at body level.
        if isAttachment(contentType: ctLower, contentDisposition: cd?.lowercased()) {
            let name = filename(from: headers) ?? defaultFilename(for: ctLower)
            let mime = primaryMIMEType(contentType)
            return ParsedMIME(
                plainBody: nil, htmlBody: nil,
                attachments: [AttachmentIn(filename: name, mimeType: mime, data: decoded)]
            )
        }

        // Text part: decode using its charset, fall back to UTF-8 then Latin-1.
        let charset = extractParam(contentType, "charset") ?? "utf-8"
        let text = decodeText(decoded, charset: charset)
        if ctLower.hasPrefix("text/html") {
            return ParsedMIME(plainBody: nil, htmlBody: text, attachments: [])
        }
        // Default everything else textual to plain.
        return ParsedMIME(plainBody: text, htmlBody: nil, attachments: [])
    }

    // MARK: - Multipart

    private static func parseMultipart(contentTypeHeader: String, body: Data) -> ParsedMIME {
        guard let boundary = extractParam(contentTypeHeader, "boundary"), !boundary.isEmpty else {
            // No boundary — treat as a single text blob.
            return ParsedMIME(
                plainBody: String(data: body, encoding: .utf8)
                    ?? String(data: body, encoding: .isoLatin1),
                htmlBody: nil, attachments: []
            )
        }
        let parts = splitOnBoundary(body, boundary: boundary)
        var result = ParsedMIME(plainBody: nil, htmlBody: nil, attachments: [])

        for part in parts {
            let (headerData, partBody) = RFC5322Parser.splitHeaderBody(part)
            let partHeaders = RFC5322Parser.decodeHeaders(headerData)
            let sub = parse(headers: partHeaders, body: partBody)
            if result.plainBody == nil { result.plainBody = sub.plainBody }
            if result.htmlBody  == nil { result.htmlBody  = sub.htmlBody }
            result.attachments.append(contentsOf: sub.attachments)
        }
        return result
    }

    /// Find every part demarcated by "--<boundary>" lines and return their raw
    /// bytes (without the boundary lines themselves). The preamble before the
    /// first boundary and the epilogue after "--<boundary>--" are discarded.
    private static func splitOnBoundary(_ body: Data, boundary: String) -> [Data] {
        let delim = Array("--\(boundary)".utf8)
        let n = body.count
        let bs = body.startIndex
        var lineStarts: [Int] = []
        var lineStart = 0
        var i = 0
        while i <= n {
            // At a line start, check if it begins with the boundary delim.
            if i == lineStart, matchPrefix(body, atOffset: lineStart, expected: delim) {
                lineStarts.append(lineStart)
            }
            if i == n { break }
            if body[bs + i] == 0x0A { lineStart = i + 1 }
            i += 1
        }
        if lineStarts.count < 2 { return [] }

        var parts: [Data] = []
        for k in 0..<(lineStarts.count - 1) {
            let boundaryLineStart = lineStarts[k]
            // Walk to the end of this boundary line.
            var partStart = boundaryLineStart
            while partStart < n && body[bs + partStart] != 0x0A { partStart += 1 }
            if partStart < n { partStart += 1 }
            let partEnd = lineStarts[k + 1]
            // Strip CRLF directly preceding the next boundary.
            var trimmed = partEnd
            if trimmed > partStart && body[bs + trimmed - 1] == 0x0A { trimmed -= 1 }
            if trimmed > partStart && body[bs + trimmed - 1] == 0x0D { trimmed -= 1 }
            if partStart < trimmed {
                parts.append(body.subdata(in: bs + partStart..<bs + trimmed))
            }
        }
        // Detect close-delim ("--boundary--") on the last boundary line. If
        // present, anything after is the epilogue and was excluded above. If
        // it isn't a close-delim, the message is technically malformed but we
        // already returned everything between boundaries; no further action.
        return parts
    }

    @inline(__always)
    private static func matchPrefix(_ body: Data, atOffset offset: Int, expected: [UInt8]) -> Bool {
        let bs = body.startIndex
        let n = body.count
        if offset + expected.count > n { return false }
        for i in 0..<expected.count where body[bs + offset + i] != expected[i] {
            return false
        }
        return true
    }

    // MARK: - Single-part decode

    private static func decode(_ body: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            // Reconstruct ignoring whitespace/newlines mailers love to fold in.
            if let s = String(data: body, encoding: .ascii),
               let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) {
                return d
            }
            return body
        case "quoted-printable":
            return RFC5322Parser.decodeQuotedPrintableData(body)
        default:
            // 7bit, 8bit, binary, or anything we don't recognise: pass through.
            return body
        }
    }

    private static func decodeText(_ data: Data, charset: String) -> String? {
        let enc = RFC5322Parser.charsetEncoding(charset)
        if let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Attachment classification

    private static func isAttachment(contentType: String, contentDisposition: String?) -> Bool {
        if let cd = contentDisposition, cd.contains("attachment") { return true }
        // Inline parts that are images / pdfs / binaries are still attachments
        // for indexing purposes — we don't want them in the search body.
        if contentType.hasPrefix("text/") { return false }
        if contentType.hasPrefix("multipart/") { return false }
        return true
    }

    private static func filename(from headers: [String: String]) -> String? {
        if let cd = headers["content-disposition"],
           let name = extractParam(cd, "filename") {
            return RFC5322Parser.decodeEncodedWords(name)
        }
        if let ct = headers["content-type"],
           let name = extractParam(ct, "name") {
            return RFC5322Parser.decodeEncodedWords(name)
        }
        return nil
    }

    private static func defaultFilename(for ctLower: String) -> String {
        let ext: String
        switch primaryMIMEType(ctLower) {
        case "application/pdf":  ext = "pdf"
        case "image/png":        ext = "png"
        case "image/jpeg":       ext = "jpg"
        case "image/gif":        ext = "gif"
        case "application/zip":  ext = "zip"
        default:                 ext = "bin"
        }
        return "attachment.\(ext)"
    }

    private static func primaryMIMEType(_ contentType: String) -> String {
        let semi = contentType.firstIndex(of: ";") ?? contentType.endIndex
        return contentType[contentType.startIndex..<semi]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    // MARK: - Header parameter extraction

    /// Pull a `key=value` (or `key="value"`) parameter out of a header value,
    /// case-insensitive on the key. Returns the unquoted value.
    static func extractParam(_ headerValue: String, _ key: String) -> String? {
        let pieces = headerValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let lowerKey = key.lowercased() + "="
        for piece in pieces {
            let lower = piece.lowercased()
            if lower.hasPrefix(lowerKey) {
                var value = String(piece.dropFirst(lowerKey.count))
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return nil
    }
}
