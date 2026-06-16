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
            ForEach(model.headers, id: \.id) { header in
                MessageRow(header: header)
                    .tag(header.id)
                    .contextMenu {
                        let isSeen = header.flags.contains(.seen)
                        Button(isSeen ? "Mark as unread" : "Mark as read") {
                            Task { await model.toggleSeen(rowID: header.id) }
                        }
                        Button(header.flags.contains(.flagged) ? "Unflag" : "Flag") {
                            Task { await model.toggleFlagged(rowID: header.id) }
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
            }
        }
        .listStyle(.inset)
        .navigationTitle(model.selectedFolder ?? "")
        .navigationSubtitle("\(model.headers.count) shown")
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
