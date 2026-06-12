import Foundation

/// Streaming reader for mbox files.
///
/// Backed by a memory-mapped Data so a 50 GB Gmail Takeout pages through the
/// virtual-memory system instead of loading into RAM. We never materialize
/// more than one message at a time. The caller receives raw `Data` slices —
/// header decoding lives in `RFC5322Parser`.
///
/// Format support: the dominant mbox-rd dialect. Messages begin at a line
/// that starts with "From " at column 0. Lines inside a message that start
/// with "From " or one-or-more ">" followed by "From " are escaped with a
/// leading ">"; we unescape on read.
public struct MboxStream {
    public let url: URL
    public let totalBytes: Int64
    private let data: Data

    public init(url: URL) throws {
        self.url = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.totalBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        self.data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
    }

    /// Yields each message in turn. `body` is called with the message's raw
    /// bytes (header lines through to the byte before the next "From " line)
    /// plus the byte offset at which it started, so callers can implement
    /// progress reporting.
    public func iterate(_ body: (_ message: Data, _ byteOffset: Int) throws -> Void) rethrows {
        let n = data.count
        if n == 0 { return }

        var idx = 0
        var atLineStart = true
        var msgStart: Int = -1

        while idx < n {
            if atLineStart && isFromLine(at: idx) {
                if msgStart >= 0 {
                    let raw = data.subdata(in: msgStart..<idx)
                    try body(unescapeFromQuoting(raw), msgStart)
                }
                msgStart = idx
            }
            atLineStart = (data[idx] == 0x0A)  // \n
            idx += 1
        }

        if msgStart >= 0 {
            let raw = data.subdata(in: msgStart..<n)
            try body(unescapeFromQuoting(raw), msgStart)
        }
    }

    // MARK: - Helpers

    @inline(__always)
    private func isFromLine(at offset: Int) -> Bool {
        guard offset + 5 <= data.count else { return false }
        return data[offset]     == 0x46    // F
            && data[offset + 1] == 0x72    // r
            && data[offset + 2] == 0x6F    // o
            && data[offset + 3] == 0x6D    // m
            && data[offset + 4] == 0x20    // space
    }

    /// Reverse the mbox-rd quoting that escapes interior "From " lines as
    /// ">From " and ">>From " as ">>>From ", etc. Allocates a new Data only
    /// when at least one occurrence is found; otherwise returns the input
    /// slice unchanged.
    private func unescapeFromQuoting(_ raw: Data) -> Data {
        var firstHit = -1
        var i = 0
        var atLineStart = true
        while i < raw.count {
            if atLineStart && raw[raw.startIndex + i] == 0x3E { // '>'
                if looksLikeQuotedFrom(in: raw, at: i) {
                    firstHit = i
                    break
                }
            }
            atLineStart = (raw[raw.startIndex + i] == 0x0A)
            i += 1
        }
        if firstHit == -1 { return raw }

        var out = Data()
        out.reserveCapacity(raw.count)
        out.append(raw.subdata(in: raw.startIndex..<(raw.startIndex + firstHit)))
        i = firstHit
        atLineStart = (firstHit == 0) || raw[raw.startIndex + firstHit - 1] == 0x0A
        while i < raw.count {
            if atLineStart && raw[raw.startIndex + i] == 0x3E && looksLikeQuotedFrom(in: raw, at: i) {
                i += 1   // drop one '>'
            }
            out.append(raw[raw.startIndex + i])
            atLineStart = (raw[raw.startIndex + i] == 0x0A)
            i += 1
        }
        return out
    }

    /// True when the byte at offset `i` (within `raw`) starts a run of '>'s
    /// followed by "From ".
    @inline(__always)
    private func looksLikeQuotedFrom(in raw: Data, at i: Int) -> Bool {
        var j = raw.startIndex + i
        let end = raw.startIndex + raw.count
        while j < end, raw[j] == 0x3E { j += 1 }
        guard end - j >= 5 else { return false }
        return raw[j]     == 0x46
            && raw[j + 1] == 0x72
            && raw[j + 2] == 0x6F
            && raw[j + 3] == 0x6D
            && raw[j + 4] == 0x20
    }
}
