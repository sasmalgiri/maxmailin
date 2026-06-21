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
                    Section {
                        // Only render folders for the *currently
                        // selected* account — model.folders is bound
                        // to it, and showing the same list under every
                        // section was misleading. Other accounts
                        // expand on click via the section header.
                        if account.id == model.selectedAccount?.id {
                            if model.folders.isEmpty {
                                Text("No folders yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(model.folders) { folder in
                                    Label {
                                        HStack {
                                            Text(folder.path)
                                                .fontWeight(folder.unread > 0 ? .semibold : .regular)
                                            Spacer()
                                            if folder.unread > 0 {
                                                Text("\(folder.unread)")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.accentColor, in: Capsule())
                                            } else {
                                                Text("\(folder.count)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    } icon: {
                                        Image(systemName: iconForFolder(folder.path))
                                    }
                                    .tag(folder.path)
                                }
                            }
                        }
                    } header: {
                        Button {
                            Task { await model.selectAccount(account) }
                        } label: {
                            HStack(spacing: 6) {
                                if account.isUnified {
                                    Image(systemName: "tray.2")
                                        .foregroundStyle(.tint)
                                }
                                Text(account.name)
                                    .fontWeight(account.id == model.selectedAccount?.id ? .semibold : .regular)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
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
