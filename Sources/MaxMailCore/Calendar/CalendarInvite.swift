import Foundation

/// One parsed iCalendar `VEVENT` — the chunk the UI cares about.
/// Codable so SwiftUI previews + the future RSVP outbox payload can
/// round-trip it. Free-form properties we don't model explicitly
/// stay in `rawProperties` keyed by the iCalendar property name.
public struct CalendarInvite: Sendable, Codable, Equatable {

    public struct Attendee: Sendable, Codable, Equatable {
        public let address: String          // bare mailto: address, lower-cased
        public let displayName: String?
        public let partStat: String?        // ACCEPTED, DECLINED, NEEDS-ACTION, …
        public let rsvp: Bool

        public init(address: String, displayName: String?,
                    partStat: String?, rsvp: Bool) {
            self.address = address
            self.displayName = displayName
            self.partStat = partStat
            self.rsvp = rsvp
        }
    }

    public let uid: String
    public let summary: String
    public let description: String?
    public let location: String?
    public let start: Date
    public let end: Date?
    public let isAllDay: Bool
    public let organizer: Attendee?
    public let attendees: [Attendee]
    public let method: String?              // REQUEST / CANCEL / REPLY / …
    public let status: String?              // TENTATIVE / CONFIRMED / CANCELLED
    public let rawProperties: [String: String]

    public init(
        uid: String, summary: String, description: String?, location: String?,
        start: Date, end: Date?, isAllDay: Bool,
        organizer: Attendee?, attendees: [Attendee],
        method: String?, status: String?,
        rawProperties: [String: String]
    ) {
        self.uid = uid
        self.summary = summary
        self.description = description
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.organizer = organizer
        self.attendees = attendees
        self.method = method
        self.status = status
        self.rawProperties = rawProperties
    }
}
