import SwiftUI
import MaxMailCore

struct SidebarView: View {
    @Environment(MailViewModel.self) private var model

    var body: some View {
        List(selection: Binding<String?>(
            get: { model.selectedFolder },
            set: { newValue in
                model.selectedFolder = newValue
                Task { await model.loadHeaders() }
            }
        )) {
            if model.accounts.isEmpty {
                Section("Welcome") {
                    Text("No mail yet.\nUse **Import mbox…** in the toolbar to bring in an archive.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            } else {
                ForEach(model.accounts) { account in
                    Section(account.name) {
                        if model.folders.isEmpty {
                            Text("No folders yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.folders) { folder in
                                Label {
                                    HStack {
                                        Text(folder.path)
                                        Spacer()
                                        Text("\(folder.count)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: iconForFolder(folder.path))
                                }
                                .tag(folder.path)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("maxmailin")
    }

    private func iconForFolder(_ path: String) -> String {
        switch path.lowercased() {
        case "inbox":   return "tray"
        case "sent":    return "paperplane"
        case "archive": return "archivebox"
        case "drafts":  return "doc"
        case "trash":   return "trash"
        case "spam":    return "xmark.octagon"
        default:        return "folder"
        }
    }
}
