import Foundation

/// RFC 5545 iCalendar parser, scoped to what an email-client invite
/// surface actually needs: line unfolding, property/parameter split,
/// DATE / DATE-TIME / TZID handling, VEVENT envelope. The returned
/// `CalendarInvite` carries the modelled properties plus a
/// raw-property dictionary so future features (RECURRENCE-ID,
/// RRULE) can read what's there without us pre-parsing them.
///
/// What's intentionally out of scope:
/// - VTODO, VJOURNAL, VFREEBUSY (mail invites are always VEVENT).
/// - RRULE expansion — invites carry the rule but the client
///   doesn't need to compute instances to show "weekly on Tue."
/// - Comma-separated DATE-TIME lists (only the first wins for the
///   summary card).
public enum ICalendarParser {

    public enum ParseError: Error, Equatable {
        case noVEvent
        case missingUID
        case missingStart
        case malformedDate(String)
    }

    public static func parse(_ source: String) throws -> CalendarInvite {
        let lines = unfold(source)
        var method: String?

        // Scan for the VCALENDAR-level METHOD before diving into events.
        // It tells the UI whether this is a REQUEST (show RSVP buttons)
        // or a CANCEL / REPLY (show that state instead).
        for line in lines {
            let (name, _, value) = splitProperty(line)
            if name == "METHOD" { method = value.uppercased(); break }
        }

        // Pull the first VEVENT block.
        guard let event = firstEvent(in: lines) else {
            throw ParseError.noVEvent
        }

        var uid: String?
        var summary = ""
        var description: String?
        var location: String?
        var startDate: Date?
        var endDate: Date?
        var isAllDay = false
        var organizer: CalendarInvite.Attendee?
        var attendees: [CalendarInvite.Attendee] = []
        var status: String?
        var raw: [String: String] = [:]

        for line in event {
            let (name, params, value) = splitProperty(line)
            raw[name] = value
            switch name {
            case "UID":          uid = value
            case "SUMMARY":      summary = decodeText(value)
            case "DESCRIPTION":  description = decodeText(value)
            case "LOCATION":     location = decodeText(value)
            case "STATUS":       status = value.uppercased()
            case "DTSTART":
                let parsed = try parseDate(value, params: params)
                startDate = parsed.date
                if parsed.isDateOnly { isAllDay = true }
            case "DTEND":
                let parsed = try parseDate(value, params: params)
                endDate = parsed.date
            case "DURATION":
                // ISO-8601 duration relative to start. Compute end
                // lazily — `endDate ?? startDate + duration`.
                if let d = parseDuration(value), let s = startDate {
                    endDate = s.addingTimeInterval(d)
                }
            case "ORGANIZER":
                organizer = parseAttendee(value: value, params: params)
            case "ATTENDEE":
                if let a = parseAttendee(value: value, params: params) {
                    attendees.append(a)
                }
            default:
                continue
            }
        }

        guard let uid else { throw ParseError.missingUID }
        guard let startDate else { throw ParseError.missingStart }

        return CalendarInvite(
            uid: uid, summary: summary, description: description,
            location: location, start: startDate, end: endDate,
            isAllDay: isAllDay, organizer: organizer, attendees: attendees,
            method: method, status: status, rawProperties: raw
        )
    }

    // MARK: - Lexing

    /// RFC 5545 line folding: any line beginning with whitespace
    /// continues the previous line. Strip the continuation marker
    /// when joining so the property scanner sees one logical line.
    static func unfold(_ source: String) -> [String] {
        let raw = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        for line in raw {
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t" {
                if !out.isEmpty {
                    out[out.count - 1].append(contentsOf: line.dropFirst())
                }
            } else {
                out.append(line)
            }
        }
        return out
    }

    private static func firstEvent(in lines: [String]) -> [String]? {
        var inside = false
        var current: [String] = []
        for line in lines {
            if line == "BEGIN:VEVENT" { inside = true; current = []; continue }
            if line == "END:VEVENT" {
                if inside { return current }
                continue
            }
            if inside { current.append(line) }
        }
        return nil
    }

    /// `NAME[;PARAM=val[;PARAM=val…]]:VALUE`. Returns name (upper-
    /// cased), parameter map, and the raw value substring (any text
    /// after the first ':'). Tolerant of values that themselves
    /// contain ':' (URLs, mailto:).
    static func splitProperty(_ line: String) -> (
        name: String, params: [String: String], value: String
    ) {
        guard let colonIdx = line.firstIndex(of: ":") else {
            return (line.uppercased(), [:], "")
        }
        let head = String(line[..<colonIdx])
        let value = String(line[line.index(after: colonIdx)...])

        let parts = head.split(separator: ";", omittingEmptySubsequences: false)
        let name = String(parts.first ?? "").uppercased()
        var params: [String: String] = [:]
        for piece in parts.dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            params[String(kv[0]).uppercased()] = String(kv[1])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (name, params, value)
    }

    // MARK: - Dates

    struct ParsedDate {
        let date: Date
        let isDateOnly: Bool
    }

    static func parseDate(_ raw: String, params: [String: String])
        throws -> ParsedDate
    {
        // DATE-only form: 8 digits, no T.
        if raw.count == 8, raw.allSatisfy({ $0.isNumber }) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: raw) {
                return ParsedDate(date: d, isDateOnly: true)
            }
        }
        // DATE-TIME forms: yyyyMMddTHHmmss[Z], optionally TZID.
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        if raw.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            if let d = f.date(from: String(raw.dropLast())) {
                return ParsedDate(date: d, isDateOnly: false)
            }
        } else {
            let tz = params["TZID"].flatMap { TimeZone(identifier: $0) }
                ?? TimeZone(identifier: "UTC")!
            f.timeZone = tz
            if let d = f.date(from: raw) {
                return ParsedDate(date: d, isDateOnly: false)
            }
        }
        throw ParseError.malformedDate(raw)
    }

    /// ISO-8601 duration like "PT1H30M" → seconds. Subset coverage:
    /// W (weeks), D (days), H (hours), M (minutes), S (seconds).
    /// Returns nil for forms we don't recognise.
    static func parseDuration(_ raw: String) -> TimeInterval? {
        guard raw.first == "P" else { return nil }
        var total: Double = 0
        var num = ""
        var afterT = false
        for ch in raw.dropFirst() {
            if ch == "T" { afterT = true; continue }
            if ch.isNumber { num.append(ch); continue }
            guard let value = Double(num) else { continue }
            num.removeAll()
            switch ch {
            case "W": total += value * 604_800
            case "D": total += value * 86_400
            case "H": total += value * 3_600
            case "M":
                total += value * (afterT ? 60 : 30 * 86_400)
            case "S": total += value
            default: break
            }
        }
        return total > 0 ? total : nil
    }

    // MARK: - Attendees + text

    /// `mailto:alice@x` → `alice@x`. Honours `CN="Alice Morgan"`,
    /// `PARTSTAT=ACCEPTED`, and `RSVP=TRUE` parameters. Returns nil
    /// when there's no usable address (rare, but malformed feeds
    /// happen).
    static func parseAttendee(
        value: String, params: [String: String]
    ) -> CalendarInvite.Attendee? {
        let lower = value.lowercased()
        let address: String
        if lower.hasPrefix("mailto:") {
            address = String(value.dropFirst("mailto:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } else {
            address = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard address.contains("@") else { return nil }
        return CalendarInvite.Attendee(
            address: address,
            displayName: params["CN"],
            partStat: params["PARTSTAT"]?.uppercased(),
            rsvp: params["RSVP"]?.uppercased() == "TRUE"
        )
    }

    /// iCalendar `TEXT`-typed values escape backslashes, commas,
    /// semicolons, and newlines. Unescape for display.
    static func decodeText(_ raw: String) -> String {
        var out = ""
        var iter = raw.makeIterator()
        while let ch = iter.next() {
            if ch != "\\" { out.append(ch); continue }
            guard let next = iter.next() else { break }
            switch next {
            case "n", "N": out.append("\n")
            case "\\":     out.append("\\")
            case ",":      out.append(",")
            case ";":      out.append(";")
            default:       out.append(next)
            }
        }
        return out
    }
}
