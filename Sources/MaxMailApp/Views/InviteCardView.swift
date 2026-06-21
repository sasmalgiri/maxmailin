import SwiftUI
import MaxMailCore

/// Compact card that surfaces a parsed iCalendar invite in the
/// message detail pane. Shows the event summary, when, where, who,
/// and quick RSVP buttons.
///
/// The RSVP actions in this slice are intentionally stubbed: they
/// set a transient status string ("Accept queued") so the user
/// gets feedback that the click registered. Composing the IMIP
/// REPLY iCalendar payload + queuing it through the existing
/// SMTP outbox lives in the follow-up slice; doing it here would
/// blow up the change set.
struct InviteCardView: View {
    let invite: CalendarInvite
    @State private var status: String = ""

    private var dateLine: String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = invite.isAllDay ? .none : .short
        let start = f.string(from: invite.start)
        guard let end = invite.end else { return start }
        // Same-day: trim the redundant day.
        let cal = Calendar.current
        if cal.isDate(invite.start, inSameDayAs: end) && !invite.isAllDay {
            let timeOnly = DateFormatter()
            timeOnly.dateStyle = .none
            timeOnly.timeStyle = .short
            return "\(start) – \(timeOnly.string(from: end))"
        }
        return "\(start) – \(f.string(from: end))"
    }

    private var headlineIcon: String {
        switch invite.method?.uppercased() {
        case "CANCEL":  return "calendar.badge.minus"
        case "REPLY":   return "calendar.badge.checkmark"
        default:        return "calendar.badge.plus"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: headlineIcon)
                    .foregroundStyle(.tint)
                Text(invite.summary.isEmpty ? "(no title)" : invite.summary)
                    .font(.headline)
                Spacer()
                if let method = invite.method, method != "REQUEST" {
                    Text(method.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                }
            }
            Label(dateLine, systemImage: "clock")
                .font(.callout)
            if let location = invite.location, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let organizer = invite.organizer {
                Label("Organizer: \(organizer.displayName ?? organizer.address)",
                      systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !invite.attendees.isEmpty {
                Label(attendeeSummary, systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Accept") { rsvp("Accept") }
                    .buttonStyle(.borderedProminent)
                Button("Tentative") { rsvp("Tentative") }
                    .buttonStyle(.bordered)
                Button("Decline") { rsvp("Decline") }
                    .buttonStyle(.bordered)
                Spacer()
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var attendeeSummary: String {
        let count = invite.attendees.count
        let head = invite.attendees.prefix(2)
            .map { $0.displayName ?? $0.address }
            .joined(separator: ", ")
        if count <= 2 { return head }
        return "\(head), +\(count - 2)"
    }

    private func rsvp(_ label: String) {
        // RSVP send isn't wired yet — surface a clear placeholder so
        // the user knows the action registered while the IMIP REPLY
        // pipeline lands in the next slice.
        status = "\(label) queued (RSVP send not wired yet)"
    }
}
