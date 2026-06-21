import Foundation

/// Quick-pick send times offered to the compose-view "Send later"
/// menu. Same calendar-aware computation as SnoozeOption — keeping
/// the two helpers in sync means the labels the user reads in both
/// places (snooze + send-later) match what the action produces.
public enum SendLaterOption: Sendable, CaseIterable, Equatable {
    case inOneHour
    case tomorrowMorning
    case tomorrowEvening
    case nextMonday

    public var label: String {
        switch self {
        case .inOneHour:       return "In one hour"
        case .tomorrowMorning: return "Tomorrow morning"
        case .tomorrowEvening: return "Tomorrow evening"
        case .nextMonday:      return "Monday morning"
        }
    }

    public var systemImage: String {
        switch self {
        case .inOneHour:       return "clock"
        case .tomorrowMorning: return "sun.max"
        case .tomorrowEvening: return "moon.stars"
        case .nextMonday:      return "calendar"
        }
    }

    public func sendTime(
        from now: Date, calendar: Calendar = .current
    ) -> Date {
        switch self {
        case .inOneHour:
            return now.addingTimeInterval(3600)
        case .tomorrowMorning:
            return weekday(after: now, days: 1, hour: 9, calendar: calendar)
        case .tomorrowEvening:
            return weekday(after: now, days: 1, hour: 18, calendar: calendar)
        case .nextMonday:
            return SnoozeOption.next(weekday: 2, hour: 9,
                                     after: now, calendar: calendar)
        }
    }

    private func weekday(after now: Date, days: Int, hour: Int,
                         calendar: Calendar) -> Date {
        let base = calendar.date(byAdding: .day, value: days, to: now) ?? now
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps) ?? base
    }
}
