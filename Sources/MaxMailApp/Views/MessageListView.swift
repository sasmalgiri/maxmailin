import SwiftUI
import MaxMailCore

struct MessageListView: View {
    @Environment(MailViewModel.self) private var model

    var body: some View {
        // If the user has typed a search, the list switches to results.
        if !model.searchText.isEmpty {
            searchList
        } else {
            inboxList
        }
    }

    private var inboxList: some View {
        List(selection: Binding<Int64?>(
            get: { model.selectedMessageID },
            set: { newID in
                if let newID { Task { await model.selectMessage(rowID: newID) } }
            }
        )) {
            if model.groupByThread && !model.threads.isEmpty {
                threadedRows
            } else {
                flatRows
            }
        }
        .listStyle(.inset)
        .navigationTitle(model.selectedFolder ?? "")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: Binding<Bool>(
                    get: { model.groupByThread },
                    set: { on in Task { await model.setGroupByThread(on) } }
                )) {
                    Label("Group by thread",
                          systemImage: "bubble.left.and.bubble.right")
                }
                .help("Group replies into one row per conversation")
            }
        }
        // Vim-style next / previous message. Only fires when the list
        // itself is the keyboard responder (i.e., when the user is not
        // typing in the search bar or compose), so J/K still work as
        // text input in those contexts.
        .onKeyPress(.init("j")) {
            Task { await model.moveSelection(by: 1) }
            return .handled
        }
        .onKeyPress(.init("k")) {
            Task { await model.moveSelection(by: -1) }
            return .handled
        }
        .overlay {
            if model.headers.isEmpty {
                ContentUnavailableView(
                    "No messages",
                    systemImage: "tray",
                    description: Text("Try importing an mbox file from the toolbar.")
                )
            }
        }
    }

    @ViewBuilder
    private var threadedRows: some View {
        ForEach(model.threads, id: \.id) { thread in
            let isExpanded = model.expandedThreads.contains(thread.id)
            ThreadRow(thread: thread, isExpanded: isExpanded)
                .tag(thread.messageRowIDs.last ?? -1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    model.toggleThread(rootID: thread.id)
                }
                .onTapGesture(count: 1) {
                    // Selecting a collapsed thread opens its latest
                    // message — what every mail client does. If the
                    // user wants the root, they can expand and pick.
                    if let last = thread.messageRowIDs.last {
                        Task { await model.selectMessage(rowID: last) }
                    }
                }
            if isExpanded {
                ForEach(thread.messageRowIDs, id: \.self) { rowID in
                    if let h = model.headers.first(where: { $0.id == rowID }) {
                        MessageRow(header: h)
                            .padding(.leading, 24)
                            .tag(rowID)
                            .contextMenu { messageContextMenu(for: h) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var flatRows: some View {
        ForEach(model.headers, id: \.id) { header in
            MessageRow(header: header)
                .tag(header.id)
                .contextMenu { messageContextMenu(for: header) }
        }
    }

    @ViewBuilder
    private func messageContextMenu(for header: MessageHeader) -> some View {
        let isSeen = header.flags.contains(.seen)
        Button(isSeen ? "Mark as unread" : "Mark as read") {
            Task { await model.toggleSeen(rowID: header.id) }
        }
        Button(header.flags.contains(.flagged) ? "Unflag" : "Flag") {
            Task { await model.toggleFlagged(rowID: header.id) }
        }
        Divider()
        Menu("Snooze") {
            ForEach(SnoozeOption.allCases, id: \.self) { opt in
                Button {
                    Task { await model.snooze(rowID: header.id, option: opt) }
                } label: {
                    Label(opt.label, systemImage: opt.systemImage)
                }
            }
        }
        Divider()
        Button("Reply") {
            Task {
                await model.selectMessage(rowID: header.id)
                model.startReply()
            }
        }
        Button("Forward") {
            Task {
                await model.selectMessage(rowID: header.id)
                model.startForward()
            }
        }
    }

    private var subtitle: String {
        if model.groupByThread && !model.threads.isEmpty {
            return "\(model.threads.count) threads · \(model.headers.count) messages"
        }
        return "\(model.headers.count) shown"
    }

    private var searchList: some View {
        List(selection: Binding<Int64?>(
            get: { model.selectedMessageID },
            set: { newID in
                if let newID { Task { await model.selectMessage(rowID: newID) } }
            }
        )) {
            Section("\(model.searchResults.count) results for \"\(model.searchText)\"") {
                ForEach(model.searchResults, id: \.id) { hit in
                    SearchRow(hit: hit).tag(hit.id)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.isSearching && model.searchResults.isEmpty {
                ProgressView("Searching…")
            } else if model.searchResults.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .navigationTitle("Search")
    }
}

private struct ThreadRow: View {
    let thread: MailThread
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(participantSummary)
                        .font(.callout)
                        .fontWeight(thread.unreadCount > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if thread.count > 1 {
                        Text("(\(thread.count))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if thread.unreadCount > 0 {
                        Text("\(thread.unreadCount)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Text(thread.latestDate, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(thread.displaySubject.isEmpty ? "(No subject)" : thread.displaySubject)
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    /// "Alice, Bob, +2" — the first two participants explicitly,
    /// then a count tail for the rest. Keeps the row scannable.
    private var participantSummary: String {
        switch thread.participants.count {
        case 0: return "(unknown)"
        case 1: return thread.participants[0]
        case 2: return thread.participants.joined(separator: ", ")
        default:
            let head = thread.participants.prefix(2).joined(separator: ", ")
            return "\(head), +\(thread.participants.count - 2)"
        }
    }
}

private struct MessageRow: View {
    let header: MessageHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(header.fromAddress)
                    .font(.callout)
                    .fontWeight(header.flags.contains(.seen) ? .regular : .semibold)
                    .lineLimit(1)
                Spacer()
                Text(header.date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(header.subject.isEmpty ? "(No subject)" : header.subject)
                .font(.subheadline)
                .lineLimit(1)
            if let snippet = header.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SearchRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hit.fromAddress).font(.callout).lineLimit(1)
                Spacer()
                Text(hit.date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(hit.subject.isEmpty ? "(No subject)" : hit.subject)
                .font(.subheadline)
                .lineLimit(1)
            highlightedSnippet(hit.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }

    /// FTS5 returns snippet with ⟦…⟧ around matches. Convert to bolded AttributedString.
    private func highlightedSnippet(_ s: String) -> Text {
        var attributed = AttributedString()
        var i = s.startIndex
        while i < s.endIndex {
            if let openR = s.range(of: "⟦", range: i..<s.endIndex),
               let closeR = s.range(of: "⟧", range: openR.upperBound..<s.endIndex) {
                attributed.append(AttributedString(String(s[i..<openR.lowerBound])))
                var bold = AttributedString(String(s[openR.upperBound..<closeR.lowerBound]))
                bold.font = .caption.weight(.bold)
                bold.foregroundColor = .accentColor
                attributed.append(bold)
                i = closeR.upperBound
            } else {
                attributed.append(AttributedString(String(s[i..<s.endIndex])))
                break
            }
        }
        return Text(attributed)
    }
}
