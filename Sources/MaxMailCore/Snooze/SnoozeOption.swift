import Foundation

/// Pre-baked snooze targets the UI offers as quick picks. Computed
/// against a supplied `now` so tests can pin the clock.
///
/// Times follow common-sense defaults that match what most snooze
/// products produce — tomorrow-morning is 9 AM, evening is 6 PM,
/// weekend is Saturday morning, next-week is Monday morning.
public enum SnoozeOption: Sendable, CaseIterable, Equatable {
    case laterToday        // +3h, clamped to before 9 PM
    case tomorrowMorning
    case tomorrowEvening
    case thisWeekend       // next Saturday 9 AM
    case nextWeek          // next Monday 9 AM

    public var label: String {
        switch self {
        case .laterToday:      return "Later today"
        case .tomorrowMorning: return "Tomorrow morning"
        case .tomorrowEvening: return "Tomorrow evening"
        case .thisWeekend:     return "This weekend"
        case .nextWeek:        return "Next week"
        }
    }

    public var systemImage: String {
        switch self {
        case .laterToday:      return "clock"
        case .tomorrowMorning: return "sun.max"
        case .tomorrowEvening: return "moon.stars"
        case .thisWeekend:     return "calendar"
        case .nextWeek:        return "calendar.badge.clock"
        }
    }

    /// Compute the absolute wake time from `now`. Calendar used
    /// honours the current locale so "Saturday" / "Monday" follow
    /// the user's first-day-of-week setting.
    public func wakeTime(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .laterToday:
            return Self.clampToBeforeEvening(
                now.addingTimeInterval(3 * 3600), calendar: calendar
            )
        case .tomorrowMorning:
            return Self.nextWeekday(after: now,
                                    addingDays: 1, hour: 9, calendar: calendar)
        case .tomorrowEvening:
            return Self.nextWeekday(after: now,
                                    addingDays: 1, hour: 18, calendar: calendar)
        case .thisWeekend:
            return Self.next(weekday: 7, hour: 9, after: now, calendar: calendar)
        case .nextWeek:
            return Self.next(weekday: 2, hour: 9, after: now, calendar: calendar)
        }
    }

    // MARK: - Internal computers

    /// Clamp a candidate later-today time to at most 9 PM so
    /// "Later today" at 8 PM doesn't quietly snooze to 11 PM (when
    /// the user is asleep). The fallback when the candidate is
    /// already past 9 PM is tomorrow morning, which is what every
    /// mail client does in this corner.
    private static func clampToBeforeEvening(
        _ candidate: Date, calendar: Calendar
    ) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: candidate)
        if (comps.hour ?? 0) >= 21 {
            return nextWeekday(after: candidate,
                               addingDays: 1, hour: 9, calendar: calendar)
        }
        return candidate
    }

    /// `addingDays` days from `after`, normalised to the given hour
    /// (minutes / seconds zeroed). Used by tomorrow-morning /
    /// tomorrow-evening.
    private static func nextWeekday(
        after now: Date, addingDays days: Int, hour: Int, calendar: Calendar
    ) -> Date {
        let base = calendar.date(byAdding: .day, value: days, to: now) ?? now
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps) ?? base
    }

    /// Next occurrence of a specific weekday (Calendar.Component
    /// .weekday — 1 = Sunday … 7 = Saturday) strictly after `after`,
    /// at the given hour.
    static func next(
        weekday: Int, hour: Int, after: Date, calendar: Calendar
    ) -> Date {
        let currentWeekday = calendar.component(.weekday, from: after)
        var delta = weekday - currentWeekday
        if delta <= 0 { delta += 7 }
        return nextWeekday(after: after, addingDays: delta,
                           hour: hour, calendar: calendar)
    }
}
