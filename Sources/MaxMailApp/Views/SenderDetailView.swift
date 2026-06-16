import SwiftUI
import MaxMailCore

/// Per-sender drill-down. Stats up top, then a short list of their most
/// recent messages on this account.
struct SenderDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let address: String
    let stat: SenderStat
    let recentMessages: [MessageHeader]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsBlock
                    if !recentMessages.isEmpty {
                        recentBlock
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(address)
                    .font(.title3.weight(.semibold))
                Text("\(stat.messageCount) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    @ViewBuilder private var statsBlock: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                  spacing: 12) {
            StatTile(title: "First contact", value: shortDate(stat.firstSeen),
                     icon: "calendar.badge.clock")
            StatTile(title: "Last contact", value: shortDate(stat.lastSeen),
                     icon: "calendar")
            StatTile(title: "Attachments",
                     value: "\(stat.attachmentMessageCount) of \(stat.messageCount)",
                     icon: "paperclip")
            if let s = stat.meanSentiment {
                StatTile(title: "Mean sentiment",
                         value: String(format: "%.2f", s),
                         icon: sentimentIcon(s),
                         tint: sentimentColor(s))
            } else {
                StatTile(title: "Mean sentiment", value: "Not yet analyzed",
                         icon: "circle.slash", tint: .gray)
            }
        }
    }

    @ViewBuilder private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent messages")
                .font(.headline)
            ForEach(recentMessages, id: \.id) { header in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(header.subject.isEmpty ? "(No subject)" : header.subject)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Text(header.date, format: .dateTime.month(.abbreviated).day().year())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let s = header.snippet, !s.isEmpty {
                        Text(s)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }

    private func sentimentIcon(_ s: Double) -> String {
        if s > 0.2 { return "face.smiling" }
        if s < -0.2 { return "exclamationmark.triangle" }
        return "face.dashed"
    }
    private func sentimentColor(_ s: Double) -> Color {
        if s > 0.2 { return .green }
        if s < -0.2 { return .orange }
        return .gray
    }
    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
