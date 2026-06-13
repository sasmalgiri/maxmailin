import SwiftUI
import MaxMailCore

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
                } else {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.importMbox() }
                } label: {
                    Label("Import mbox…", systemImage: "tray.and.arrow.down")
                }
                .disabled(model.isImporting)
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
