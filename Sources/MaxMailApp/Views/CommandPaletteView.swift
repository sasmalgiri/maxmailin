import SwiftUI
import MaxMailCore

/// ⌘K command palette. Filtered list of every actionable thing in the app
/// so a power user can stay on the keyboard. Mirrors Cmd+K UX from VS Code /
/// Linear / Raycast — type to filter, arrows to move, Enter to execute,
/// Esc to close.
struct CommandPaletteView: View {
    @Environment(MailViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let cmds = filteredCommands
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Type a command — Compose, Refresh, Insights…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(14)
            Divider()

            if cmds.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(height: 240)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(cmds.enumerated()), id: \.element.id) { idx, cmd in
                                CommandRow(command: cmd, selected: idx == selection)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture { execute(cmd) }
                                    .onHover { hovering in
                                        if hovering { selection = idx }
                                    }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(cmds.count) * 50, 320))
                    .onChange(of: selection) { _, new in
                        withAnimation(.linear(duration: 0.08)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { focused = true }
        // SwiftUI .onKeyPress (macOS 14+) handles arrows + return without
        // needing an NSViewRepresentable.
        .onKeyPress(.upArrow) {
            if selection > 0 { selection -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selection < cmds.count - 1 { selection += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            if let cmd = cmds[safe: selection] { execute(cmd) }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint("↑↓", "navigate")
            KeyHint("↵", "run")
            KeyHint("esc", "close")
            Spacer()
            Text("\(filteredCommands.count) commands")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    // MARK: - Actions

    private func execute(_ cmd: Command) {
        dismiss()
        // Defer the action one runloop tick so the dismiss can complete
        // before any new sheet is presented.
        DispatchQueue.main.async { cmd.action() }
    }

    private var filteredCommands: [Command] {
        let all = Self.commands(model: model)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { cmd in
            cmd.title.lowercased().contains(q)
            || cmd.keywords.contains(where: { $0.contains(q) })
        }
    }

    // MARK: - Catalog

    /// Single source of truth for everything ⌘K knows about. Each entry
    /// is a (title, subtitle, icon, search keywords, action) tuple.
    static func commands(model: MailViewModel) -> [Command] {
        [
            .init(id: "compose",
                  title: "Compose new message",
                  subtitle: "Write a new email",
                  icon: "square.and.pencil",
                  keywords: ["new", "write", "draft", "email"],
                  action: { model.newMessage() }),
            .init(id: "refresh",
                  title: "Refresh mail",
                  subtitle: "Sync the configured live account",
                  icon: "arrow.clockwise",
                  keywords: ["sync", "fetch", "pull"],
                  action: { Task { await model.refreshLiveMail() } }),
            .init(id: "import",
                  title: "Import mbox archive…",
                  subtitle: "Stream an mbox / Gmail Takeout into the local store",
                  icon: "tray.and.arrow.down",
                  keywords: ["mbox", "takeout", "archive", "open"],
                  action: { model.requestImport() }),
            .init(id: "insights",
                  title: "Open Insights dashboard",
                  subtitle: "Sentiment timeline, top contacts, keywords",
                  icon: "chart.line.uptrend.xyaxis",
                  keywords: ["analytics", "dashboard", "stats", "graph"],
                  action: { model.showAnalytics = true }),
            .init(id: "reply",
                  title: "Reply to current message",
                  subtitle: "Pre-fills sender + Re: subject + quoted body",
                  icon: "arrowshape.turn.up.left",
                  keywords: ["respond"],
                  action: { model.startReply() }),
            .init(id: "replyall",
                  title: "Reply All to current message",
                  icon: "arrowshape.turn.up.left.2",
                  keywords: ["respond all"],
                  action: { model.startReply(replyAll: true) }),
            .init(id: "forward",
                  title: "Forward current message",
                  icon: "arrowshape.turn.up.right",
                  keywords: ["fwd"],
                  action: { model.startForward() }),
            .init(id: "rules",
                  title: "Manage rules…",
                  subtitle: "Auto-flag, mark read, sort into folders",
                  icon: "line.3.horizontal.decrease.circle",
                  keywords: ["filter", "automation", "sort", "label"],
                  action: { model.showRules = true }),
            .init(id: "jmap",
                  title: "JMAP account settings…",
                  subtitle: "Fastmail / Stalwart credentials",
                  icon: "gearshape",
                  keywords: ["fastmail", "stalwart", "session", "account"],
                  action: { model.showJMAPSettings = true }),
            .init(id: "imap",
                  title: "IMAP account settings…",
                  subtitle: "Gmail / iCloud / Yahoo / Outlook credentials",
                  icon: "gearshape",
                  keywords: ["imap", "smtp", "gmail", "icloud", "yahoo", "outlook", "account"],
                  action: { model.showIMAPSettings = true }),
            .init(id: "security",
                  title: "Security settings…",
                  subtitle: "App lock with Touch ID / Face ID / device password",
                  icon: "lock.shield",
                  keywords: ["touchid", "faceid", "biometric", "lock"],
                  action: { model.showSecurity = true }),
            .init(id: "about",
                  title: "About maxmailin",
                  icon: "info.circle",
                  keywords: ["info", "version"],
                  action: { model.showAbout = true }),
            .init(id: "shortcuts",
                  title: "Keyboard shortcuts",
                  icon: "keyboard",
                  keywords: ["help", "keys"],
                  action: { model.showShortcuts = true }),
            .init(id: "welcome",
                  title: "Show welcome tour",
                  icon: "sparkles",
                  keywords: ["intro", "onboarding", "guide"],
                  action: { model.showWelcome = true })
        ]
    }

    struct Command: Identifiable {
        let id: String
        let title: String
        var subtitle: String? = nil
        let icon: String
        let keywords: [String]
        let action: () -> Void
    }
}

private struct CommandRow: View {
    let command: CommandPaletteView.Command
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.icon)
                .frame(width: 22)
                .foregroundStyle(selected ? .white : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .foregroundStyle(selected ? .white : .primary)
                if let sub = command.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor : Color.clear)
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
