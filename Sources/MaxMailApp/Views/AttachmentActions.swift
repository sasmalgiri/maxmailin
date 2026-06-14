import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Open / save helpers for an attachment that has already been fetched
/// out of the BlobStore. We write the bytes into a temp file under the
/// original filename so the OS-level "open with" handler picks the right app.
enum AttachmentActions {
    static func writeToTemp(data: Data, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxmailin-attachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename.isEmpty ? "attachment" : filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    #if canImport(AppKit)
    @MainActor
    static func open(data: Data, filename: String) {
        do {
            let url = try writeToTemp(data: data, filename: filename)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    @MainActor
    static func revealInFinder(data: Data, filename: String) {
        do {
            let url = try writeToTemp(data: data, filename: filename)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    @MainActor
    static func saveAs(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let target = panel.url {
            try? data.write(to: target, options: .atomic)
        }
    }
    #elseif canImport(UIKit)
    @MainActor
    static func open(data: Data, filename: String, from view: UIViewController) {
        do {
            let url = try writeToTemp(data: data, filename: filename)
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            view.present(activity, animated: true)
        } catch {
            // Surface upstream — first cut, just no-op.
        }
    }
    #endif
}
