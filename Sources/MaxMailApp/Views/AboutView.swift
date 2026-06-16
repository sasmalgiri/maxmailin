import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .resizable().scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(.tint)
            Text("maxmailin")
                .font(.largeTitle.weight(.semibold))
            Text("Forensic-grade mail client. JMAP-ready, mbox-aware, on-device intelligence.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            VStack(alignment: .leading, spacing: 6) {
                row("Storage",   "SQLite + per-year FTS5 shards")
                row("Blobs",     "Content-addressed (SHA-256)")
                row("Live mail", "JMAP read / write / send")
                row("Imports",   "Streaming mbox + MIME multipart")
                row("AI",        "On-device NLP, forensics, anomaly")
            }
            .padding()
            .background(Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 460, height: 460)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout)
        }
    }
}
