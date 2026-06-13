import Foundation
import MaxMailCore
import Observation
#if canImport(AppKit)
import AppKit
#endif

struct AccountSummary: Identifiable, Hashable {
    let id: Int64
    let name: String
    let address: String
}

struct FolderSummary: Identifiable, Hashable {
    let path: String
    let count: Int64
    var id: String { path }
}

@MainActor
@Observable
final class MailViewModel {
    var store: MailStore?
    var accounts: [AccountSummary] = []
    var selectedAccount: AccountSummary?

    var folders: [FolderSummary] = []
    var selectedFolder: String?

    var headers: [MessageHeader] = []
    var selectedMessageID: Int64?

    var currentBody: (plain: String?, html: String?)?
    var currentAttachments: [AttachmentRef] = []

    var searchText: String = ""
    var searchResults: [SearchHit] = []
    var isSearching: Bool = false

    var isImporting: Bool = false
    var importProgress: Double = 0
    var importStatus: String = ""

    var statusMessage: String = "Loading…"
    var errorMessage: String?

    func bootstrap() async {
        do {
            let url = Self.defaultDBURL()
            let s = try MailStore(url: url)
            self.store = s
            statusMessage = "Ready"
            await refreshAccountsAndFolders()
            await loadHeaders()
        } catch {
            errorMessage = "Failed to open store: \(error.localizedDescription)"
        }
    }

    static func defaultDBURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("maxmailin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mail.sqlite")
    }

    func refreshAccountsAndFolders() async {
        guard let store else { return }
        do {
            let raw = try await store.accountsList()
            self.accounts = raw.map { AccountSummary(id: $0.id, name: $0.name, address: $0.address) }
            if selectedAccount == nil { selectedAccount = accounts.first }
            await loadFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadFolders() async {
        guard let store, let acc = selectedAccount else {
            folders = []; selectedFolder = nil
            return
        }
        do {
            let paths = try await store.folders(accountID: acc.id)
            var out: [FolderSummary] = []
            for p in paths {
                let n = try await store.messageCount(accountID: acc.id, folder: p)
                out.append(FolderSummary(path: p, count: n))
            }
            self.folders = out
            if selectedFolder == nil || !paths.contains(selectedFolder!) {
                selectedFolder = paths.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadHeaders() async {
        guard let store,
              let acc = selectedAccount,
              let folder = selectedFolder else {
            headers = []; return
        }
        do {
            headers = try await store.headers(in: folder, accountID: acc.id, limit: 200)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectMessage(rowID: Int64) async {
        selectedMessageID = rowID
        guard let store else { return }
        do {
            let body = try await store.loadBody(messageRowID: rowID)
            let atts = try await store.attachments(messageRowID: rowID)
            self.currentBody = body
            self.currentAttachments = atts
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runSearch() async {
        guard let store else { return }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = []; isSearching = false; return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await store.search(
                q, accountID: selectedAccount?.id, limit: 100
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        isSearching = false
    }

    // MARK: - Import

    func importMbox() async {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Choose an mbox file to import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        await importMbox(at: url)
        #endif
    }

    func importMbox(at url: URL) async {
        guard let store else { return }
        do {
            let accID = try await store.upsertAccount(
                name: "Local Archive", address: "local@maxmailin", kind: "local"
            )
            isImporting = true
            importProgress = 0
            importStatus = "Starting…"
            let importer = MboxImporter(
                store: store,
                accountID: accID,
                options: .init(batchSize: 1_000, folder: "INBOX")
            )
            let result = try await importer.importFile(at: url) { @Sendable [weak self] p in
                Task { @MainActor in
                    guard let self else { return }
                    self.importProgress = p.percentComplete
                    let pct = Int(p.percentComplete * 100)
                    self.importStatus = "\(pct)% — \(p.messagesIngested) ingested"
                }
            }
            isImporting = false
            importStatus = "Imported \(result.ingested), skipped \(result.skipped)"
            await refreshAccountsAndFolders()
            await loadHeaders()
        } catch {
            isImporting = false
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
