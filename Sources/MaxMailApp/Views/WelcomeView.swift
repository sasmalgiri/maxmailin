import SwiftUI

/// First-launch welcome experience. A paged tour of the things that
/// actually make maxmailin different — surfaces the feature set so the
/// user has somewhere to start beyond a blank inbox.
struct WelcomeView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private static let pages: [Page] = [
        Page(
            icon: "envelope.badge.shield.half.filled",
            tint: .blue,
            title: "Welcome to maxmailin",
            subtitle: "Forensic-grade mail. JMAP-ready. mbox-aware. On-device intelligence.",
            bullets: []
        ),
        Page(
            icon: "tray.and.arrow.down",
            tint: .mint,
            title: "Bring your archive in",
            subtitle: "Streaming mbox import — 1 TB takeouts page through, never blow up RAM.",
            bullets: [
                "Drag-drop or ⌘I to pick a file",
                "Gmail Takeout, Apple Mail, Thunderbird, EML / EMLX",
                "Year × month FTS5 shards keep search fast at scale"
            ]
        ),
        Page(
            icon: "antenna.radiowaves.left.and.right",
            tint: .purple,
            title: "Plug a live account",
            subtitle: "JMAP for Fastmail / Stalwart, IMAP+SMTP for everything else.",
            bullets: [
                "Bearer token or app password — both ride in Keychain",
                "JMAP push (Email/changes) or IMAP IDLE — never poll",
                "Threaded reply / forward / drafts wired to both"
            ]
        ),
        Page(
            icon: "sparkles",
            tint: .orange,
            title: "Insight on every message",
            subtitle: "Local-only — no mail bytes leave the device.",
            bullets: [
                "Sentiment, language, entities, keywords",
                "First-time / dormant / off-hours sender chips",
                "Phishing flags + PII counts in a coloured banner"
            ]
        ),
        Page(
            icon: "chart.line.uptrend.xyaxis",
            tint: .teal,
            title: "Per-account insights",
            subtitle: "Open the chart icon in the toolbar.",
            bullets: [
                "Sentiment timeline by month",
                "Top contacts, with mean tone + attachment ratio",
                "Top keywords + entities, ranked"
            ]
        ),
        Page(
            icon: "lock.shield",
            tint: .indigo,
            title: "Privacy is the default",
            subtitle: "Everything stays on disk — no third-party AI calls.",
            bullets: [
                "Bearer tokens / app passwords live in the macOS Keychain",
                "Attachments are content-addressed (SHA-256), deduped on import",
                "Forensic flags, NLP, anomaly detection — all on-device"
            ]
        )
    ]

    private struct Page: Sendable {
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
        let bullets: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { idx, p in
                    pageView(p).tag(idx)
                }
            }
            #if os(macOS)
            // Mac doesn't show the page dots in PageTabViewStyle; we'll
            // do our own.
            #endif
            HStack(spacing: 8) {
                ForEach(0..<Self.pages.count, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.vertical, 8)
            footer
        }
        .frame(minWidth: 560, minHeight: 540)
    }

    @ViewBuilder
    private func pageView(_ p: Page) -> some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 24)
            Image(systemName: p.icon)
                .resizable().scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(p.tint)
            Text(p.title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(p.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if !p.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(p.bullets, id: \.self) { b in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(p.tint)
                                .padding(.top, 2)
                            Text(b)
                        }
                    }
                }
                .padding(20)
                .background(Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 28)
            }
            Spacer()
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("Skip") {
                WelcomeShownStore.markShown()
                dismiss()
            }
            Spacer()
            if page > 0 {
                Button("Back") { page -= 1 }
            }
            Button(page == Self.pages.count - 1 ? "Get started" : "Next") {
                if page == Self.pages.count - 1 {
                    WelcomeShownStore.markShown()
                    dismiss()
                } else {
                    page += 1
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

/// Tracks whether the welcome flow has run at least once. Plain
/// UserDefaults flag — nothing security-sensitive.
enum WelcomeShownStore {
    private static let key = "maxmailin.welcome.shown"

    static var hasShown: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markShown() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Lets the user re-open the welcome flow from the Help menu.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
