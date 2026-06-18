import SwiftUI
import MaxMailCore

@main
struct MaxMailApp: App {
    @State private var model = MailViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    await model.bootstrap()
                }
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import mbox…") {
                    model.requestImport()
                }
                .keyboardShortcut("i", modifiers: [.command])
                Button("Refresh") {
                    Task { await model.refreshLiveMail() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isRefreshing)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About maxmailin") {
                    model.showAbout = true
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("Keyboard shortcuts") {
                    model.showShortcuts = true
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
                Button("Show welcome…") {
                    model.showWelcome = true
                }
            }
        }
    }
}
