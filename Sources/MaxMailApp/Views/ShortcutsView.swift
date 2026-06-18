import SwiftUI

struct ShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("File", [
            ("⌘N", "New message"),
            ("⌘I", "Import mbox…"),
            ("⌘R", "Refresh JMAP / IMAP"),
            ("⌘K", "Command palette")
        ]),
        ("View", [
            ("⌘F", "Search mail"),
            ("⇧⌘A", "About maxmailin"),
            ("⇧⌘?", "Keyboard shortcuts")
        ]),
        ("Compose", [
            ("⌘N", "Start a new message"),
            ("Right-click → Reply", "Reply prefilled with quote + threading"),
            ("Right-click → Forward", "Forward with original headers + body")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard shortcuts").font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.0).font(.headline).foregroundStyle(.secondary)
                    ForEach(group.1, id: \.0) { pair in
                        HStack {
                            Text(pair.0)
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .frame(minWidth: 60, alignment: .leading)
                            Text(pair.1)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 380, height: 320)
    }
}
