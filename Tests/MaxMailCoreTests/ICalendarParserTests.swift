import XCTest
@testable import MaxMailCore

final class ICalendarParserTests: XCTestCase {

    // MARK: - Happy path

    func testParseTypicalGoogleMeetingRequest() throws {
        let src = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:abc123@example.com
        DTSTAMP:20260619T120000Z
        DTSTART:20260620T170000Z
        DTEND:20260620T180000Z
        SUMMARY:Team Standup
        LOCATION:Zoom
        ORGANIZER;CN="Alice Morgan":mailto:alice@x
        ATTENDEE;CN="Bob";PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:bob@y
        ATTENDEE;CN="Carol";PARTSTAT=ACCEPTED:mailto:carol@z
        STATUS:CONFIRMED
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try ICalendarParser.parse(src)
        XCTAssertEqual(invite.uid, "abc123@example.com")
        XCTAssertEqual(invite.summary, "Team Standup")
        XCTAssertEqual(invite.location, "Zoom")
        XCTAssertEqual(invite.method, "REQUEST")
        XCTAssertEqual(invite.status, "CONFIRMED")
        XCTAssertFalse(invite.isAllDay)

        // 2026-06-20 17:00 UTC
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!,
                                       from: invite.start)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 20)
        XCTAssertEqual(comps.hour, 17)

        // Organizer + attendees
        XCTAssertEqual(invite.organizer?.address, "alice@x")
        XCTAssertEqual(invite.organizer?.displayName, "Alice Morgan")
        XCTAssertEqual(invite.attendees.map(\.address), ["bob@y", "carol@z"])
        XCTAssertEqual(invite.attendees.first?.partStat, "NEEDS-ACTION")
        XCTAssertTrue(invite.attendees.first?.rsvp ?? false)
        XCTAssertEqual(invite.attendees.last?.partStat, "ACCEPTED")
    }

    // MARK: - Line folding

    func testUnfoldsRFC5545LineWrap() {
        let src = """
        SUMMARY:This is a long subject that wraps in
          the iCalendar feed
        """
        let folded = ICalendarParser.unfold(src)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0],
                       "SUMMARY:This is a long subject that wraps in the iCalendar feed")
    }

    // MARK: - Date parsing

    func testParseAllDayEvent() throws {
        let src = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:allday@example.com
        DTSTART;VALUE=DATE:20260704
        DTEND;VALUE=DATE:20260705
        SUMMARY:Independence Day
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try ICalendarParser.parse(src)
        XCTAssertTrue(invite.isAllDay)
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!,
                                       from: invite.start)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 4)
    }

    func testParseFloatingTimeWithTZID() throws {
        let src = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:tz@example.com
        DTSTART;TZID=America/Los_Angeles:20260620T090000
        SUMMARY:Pacific morning
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try ICalendarParser.parse(src)
        // 09:00 LA on 2026-06-20 = 16:00 UTC (PDT, UTC-7).
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!,
                                       from: invite.start)
        XCTAssertEqual(comps.hour, 16)
    }

    // MARK: - Duration fallback

    func testParseDurationComputesEndFromStart() throws {
        let src = """
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:dur@example.com
        DTSTART:20260620T170000Z
        DURATION:PT1H30M
        SUMMARY:Briefing
        END:VEVENT
        END:VCALENDAR
        """
        let invite = try ICalendarParser.parse(src)
        XCTAssertEqual(invite.end?.timeIntervalSince(invite.start), 1.5 * 3600)
    }

    // MARK: - Text decoding

    func testDecodeTextHandlesEscapedNewlinesAndCommas() {
        XCTAssertEqual(
            ICalendarParser.decodeText("Line 1\\nLine 2\\, more"),
            "Line 1\nLine 2, more"
        )
    }

    // MARK: - Failure modes

    func testParseFailsOnMissingVEvent() {
        let src = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR"
        XCTAssertThrowsError(try ICalendarParser.parse(src)) { err in
            XCTAssertEqual(err as? ICalendarParser.ParseError, .noVEvent)
        }
    }

    func testParseFailsOnMissingUID() {
        let src = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        DTSTART:20260620T170000Z
        SUMMARY:No UID
        END:VEVENT
        END:VCALENDAR
        """
        XCTAssertThrowsError(try ICalendarParser.parse(src)) { err in
            XCTAssertEqual(err as? ICalendarParser.ParseError, .missingUID)
        }
    }

    func testParseFailsOnMalformedDate() {
        let src = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:bad@x
        DTSTART:not-a-date
        SUMMARY:Bad
        END:VEVENT
        END:VCALENDAR
        """
        XCTAssertThrowsError(try ICalendarParser.parse(src)) { err in
            guard case .malformedDate(let v) = err as? ICalendarParser.ParseError
            else { return XCTFail("wrong error: \(err)") }
            XCTAssertEqual(v, "not-a-date")
        }
    }
}
