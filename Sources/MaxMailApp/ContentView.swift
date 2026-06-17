import SwiftUI
import MaxMailCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(MailViewModel.self) private var model

    var body: some View {
        @Bindable var bindable = model
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 220)
        } content: {
            MessageListView()
                .frame(minWidth: 320)
        } detail: {
            MessageDetailView()
                .frame(minWidth: 400)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if model.isImporting {
                    ProgressView(value: model.importProgress) {
                        Text(model.importStatus).font(.caption)
                    }
                    .frame(width: 200)
                } else if model.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.refreshStatus).font(.caption)
                    }
                } else {
                    HStack(spacing: 6) {
                        if model.isLivePushConnected {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text("Live")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(model.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshLiveMail() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isRefreshing || JMAPConfigStore.first() == nil)
                .help("Sync with the configured JMAP server")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.newMessage()
                } label: {
                    Label("New message", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showAnalytics = true
                } label: {
                    Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                }
                .disabled(model.selectedAccount == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestImport()
                } label: {
                    Label("Import mbox…", systemImage: "tray.and.arrow.down")
                }
                .disabled(model.isImporting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showJMAPSettings = true
                } label: {
                    Label("JMAP settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $bindable.showAnalytics) {
            AnalyticsView()
                .environment(model)
        }
        .sheet(isPresented: $bindable.showCompose) {
            ComposeView()
                .environment(model)
        }
        .sheet(isPresented: $bindable.showJMAPSettings) {
            JMAPSettingsView()
                .environment(model)
        }
        .sheet(isPresented: $bindable.showAbout) { AboutView() }
        .sheet(isPresented: $bindable.showShortcuts) { ShortcutsView() }
        .fileImporter(
            isPresented: $bindable.showImportPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await model.importMbox(at: url) } }
            case .failure(let error):
                model.errorMessage = "File picker: \(error.localizedDescription)"
            }
        }
        .searchable(text: $bindable.searchText, prompt: "Search mail")
        .onChange(of: model.searchText) { _, new in
            // Debounced search would be nicer; for now run on every change.
            Task { await model.runSearch() }
        }
        .alert("Something went wrong",
               isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
               )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
