import Foundation
import MaxMailCore
import Observation

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
    var currentNLP: EmailNLP?
    var currentForensics: ForensicResult?
    var currentAnomalies: [EmailAnomaly] = []

    var searchText: String = ""
    var searchResults: [SearchHit] = []
    var isSearching: Bool = false

    var isImporting: Bool = false
    var importProgress: Double = 0
    var importStatus: String = ""
    var showImportPicker: Bool = false

    var showAnalytics: Bool = false
    var showCompose: Bool = false
    var showJMAPSettings: Bool = false
    var isSending: Bool = false
    var sendStatus: String = ""
    var sendError: String?
    var isBackgroundAnalyzing: Bool = false
    var analyticsProgress: AnalysisProgress = AnalysisProgress(analyzed: 0, total: 0)
    var analyticsDistribution: SentimentDistribution = SentimentDistribution(
        veryNegative: 0, negative: 0, neutral: 0, positive: 0, veryPositive: 0
    )
    var analyticsTimeline: [SentimentMonth] = []
    var analyticsKeywords: [KeywordCount] = []
    var analyticsEntities: [EntityCount] = []

    private var analyzer: BackgroundAnalyzer?

    var statusMessage: String = "Loading…"
    var errorMessage: String?

    func bootstrap() async {
        Self.sharedInstance = self
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
        currentNLP = nil
        currentForensics = nil
        currentAnomalies = []
        guard let store else { return }
        do {
            let body = try await store.loadBody(messageRowID: rowID)
            let atts = try await store.attachments(messageRowID: rowID)
            self.currentBody = body
            self.currentAttachments = atts
            // Anomalies are cheap (3 indexed lookups) — compute synchronously.
            self.currentAnomalies = (try? await store.anomalies(forMessageRowID: rowID)) ?? []
            // Kick off NLP + forensics lazily; selection of *another* message
            // before this completes is fine because we re-check rowID below.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let nlp = try await store.ensureNLP(messageRowID: rowID)
                    let forensics = try await store.ensureForensics(messageRowID: rowID)
                    if self.selectedMessageID == rowID {
                        self.currentNLP = nlp
                        self.currentForensics = forensics
                    }
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
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

    // MARK: - Analytics + background NLP

    func refreshAnalytics() async {
        guard let store, let acc = selectedAccount else { return }
        do {
            analyticsProgress     = try await store.analysisProgress(accountID: acc.id)
            analyticsDistribution = try await store.sentimentDistribution(accountID: acc.id)
            analyticsTimeline     = try await store.sentimentTimeline(accountID: acc.id)
            analyticsKeywords     = try await store.topKeywords(accountID: acc.id, limit: 25)
            analyticsEntities     = try await store.topEntities(accountID: acc.id, limit: 25)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startAnalysis() async {
        guard let store, let acc = selectedAccount else { return }
        if analyzer == nil { analyzer = BackgroundAnalyzer(store: store) }
        isBackgroundAnalyzing = true
        await analyzer?.start(accountID: acc.id, batchSize: 50) { @Sendable progress in
            await Self.deliverProgress(progress)
        }
    }

    /// Routes progress updates from the background analyzer's Task.detached
    /// context back to the main-actor view model singleton. We resolve the
    /// shared instance via a static lookup so the @Sendable closure never
    /// captures `self`.
    @MainActor
    private static func deliverProgress(_ progress: AnalysisProgress) {
        let vm = MailViewModel.shared
        vm.analyticsProgress = progress
        if progress.analyzed >= progress.total {
            vm.isBackgroundAnalyzing = false
            Task { await vm.refreshAnalytics() }
        }
    }

    /// Singleton handle so background callbacks can deliver back to the
    /// owning view model without capturing it. Only one MailViewModel is
    /// ever instantiated (by MaxMailApp.scene); registered in bootstrap.
    @MainActor private static weak var sharedInstance: MailViewModel?
    @MainActor static var shared: MailViewModel {
        guard let s = sharedInstance else {
            preconditionFailure("MailViewModel.shared accessed before bootstrap()")
        }
        return s
    }

    func stopAnalysis() async {
        await analyzer?.cancel()
        isBackgroundAnalyzing = false
        await refreshAnalytics()
    }

    // MARK: - Compose + send

    /// Send a plain-text email through the saved JMAP config. Returns the
    /// server-assigned email id on success, or nil if anything failed —
    /// in which case `sendError` carries the user-visible message.
    func sendMail(from sender: String, to: [String], subject: String, body: String) async -> String? {
        sendError = nil
        guard !to.isEmpty else { sendError = "No recipients"; return nil }
        guard let cfg = JMAPConfigStore.first(),
              let url = URL(string: cfg.sessionURL) else {
            sendError = "No JMAP account configured"
            return nil
        }
        guard let store else { sendError = "Store not ready"; return nil }
        isSending = true
        sendStatus = "Connecting…"
        defer { isSending = false }
        do {
            let client = JMAPClient(config: .init(sessionURL: url,
                                                  credential: .bearer(cfg.bearerToken)))
            let accID = try await store.upsertAccount(
                name: cfg.displayName, address: sender, kind: "jmap"
            )
            let sync = JMAPSync(client: client, store: store, localAccountID: accID)
            sendStatus = "Sending…"
            let id = try await sync.sendPlainEmail(
                from: sender, to: to, subject: subject, body: body
            )
            sendStatus = "Sent."
            return id
        } catch {
            sendError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Attachment download

    func downloadAttachment(_ ref: AttachmentRef) async {
        guard let store else { return }
        guard let cfg = JMAPConfigStore.first(),
              let url = URL(string: cfg.sessionURL) else {
            errorMessage = "No JMAP account configured for download"
            return
        }
        guard let acc = selectedAccount else { return }
        do {
            let client = JMAPClient(config: .init(sessionURL: url,
                                                  credential: .bearer(cfg.bearerToken)))
            let sync = JMAPSync(client: client, store: store, localAccountID: acc.id)
            let updated = try await sync.downloadAttachment(attachmentID: ref.id)
            // Reflect locally — replace in current list.
            if let idx = currentAttachments.firstIndex(where: { $0.id == ref.id }) {
                currentAttachments[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Import

    /// Trigger the SwiftUI .fileImporter sheet. Actual file selection comes
    /// back through importMbox(at:) once the user picks something.
    func requestImport() {
        showImportPicker = true
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
