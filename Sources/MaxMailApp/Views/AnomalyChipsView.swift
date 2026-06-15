import SwiftUI
import MaxMailCore

struct AnomalyChipsView: View {
    let anomalies: [EmailAnomaly]

    var body: some View {
        if !anomalies.isEmpty {
            HStack(spacing: 6) {
                ForEach(anomalies, id: \.self) { a in
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: a.kind))
                            .font(.caption2)
                        Text(label(for: a.kind))
                        Text("·").foregroundStyle(.secondary)
                        Text(a.detail)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(background(for: a.severity), in: Capsule())
                }
                Spacer()
            }
        }
    }

    private func icon(for k: EmailAnomaly.Kind) -> String {
        switch k {
        case .firstTimeContact:     return "person.crop.circle.badge.plus"
        case .dormantSenderRevival: return "clock.arrow.circlepath"
        case .offHoursArrival:      return "moon.stars"
        }
    }

    private func label(for k: EmailAnomaly.Kind) -> String {
        switch k {
        case .firstTimeContact:     return "First message"
        case .dormantSenderRevival: return "Returning sender"
        case .offHoursArrival:      return "Off-hours"
        }
    }

    private func background(for severity: EmailAnomaly.Severity) -> Color {
        switch severity {
        case .info:    return Color.secondary.opacity(0.12)
        case .notable: return Color.blue.opacity(0.18)
        case .high:    return Color.orange.opacity(0.22)
        }
    }
}
