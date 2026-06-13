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
                    Task { await model.importMbox() }
                }
                .keyboardShortcut("i", modifiers: [.command])
            }
        }
    }
}
