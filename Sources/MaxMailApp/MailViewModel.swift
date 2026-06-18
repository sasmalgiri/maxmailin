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
    let unread: Int64
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
    var showIMAPSettings: Bool = false
    var isSending: Bool = false
    var sendStatus: String = ""
    var sendError: String?

    // Compose draft (single in-progress draft; survives sheet close)
    var draftTo: String = ""
    var draftSubject: String = ""
    var draftBody: String = ""
    var draftInReplyTo: String?
    var draftReferences: [String] = []
    var lastSentEmailID: String?

    // Live sync + flag state
    var isRefreshing: Bool = false
    var refreshStatus: String = ""
    var showAbout: Bool = false
    var showShortcuts: Bool = false
    var showWelcome: Bool = false

    /// True while the JMAP push channel is connected.
    var isLivePushConnected: Bool = false
    private var liveEventSource: JMAPEventSource?

    var isBackgroundAnalyzing: Bool = false
    var analyticsProgress: AnalysisProgress = AnalysisProgress(analyzed: 0, total: 0)
    var analyticsDistribution: SentimentDistribution = SentimentDistribution(
        veryNegative: 0, negative: 0, neutral: 0, positive: 0, veryPositive: 0
    )
    var analyticsTimeline: [SentimentMonth] = []
    var analyticsKeywords: [KeywordCount] = []
    var analyticsEntities: [EntityCount] = []
    var analyticsSenders: [SenderStat] = []

    var selectedSender: SenderStat?
    var selectedSenderMessages: [MessageHeader] = []
    var showSenderDetail: Bool = false

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
            startLivePush()
            // First launch — show the welcome flow. Re-launches don't.
            if !WelcomeShownStore.hasShown {
                showWelcome = true
            }
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
                let counts = try await store.folderCounts(accountID: acc.id, folder: p)
                out.append(FolderSummary(path: p, count: counts.total, unread: counts.unread))
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
            analyticsSenders      = try await store.topSenders(accountID: acc.id, limit: 15)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSenderDetail(_ stat: SenderStat) async {
        guard let store, let acc = selectedAccount else { return }
        do {
            let recent = try await store.messagesFromSender(
                accountID: acc.id, address: stat.address, limit: 12
            )
            selectedSender = stat
            selectedSenderMessages = recent
            showSenderDetail = true
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

    /// Send the current draft. Dispatches to JMAP submission when a JMAP
    /// account is configured, falling back to SMTP otherwise.
    func sendCurrentDraft() async -> String? {
        sendError = nil
        let recipients = draftTo
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !recipients.isEmpty else { sendError = "No recipients"; return nil }
        if JMAPConfigStore.first() != nil {
            return await sendCurrentDraftJMAP(recipients: recipients)
        }
        if IMAPConfigStore.first() != nil {
            return await sendCurrentDraftSMTP(recipients: recipients)
        }
        sendError = "No mail account configured"
        return nil
    }

    private func sendCurrentDraftJMAP(recipients: [String]) async -> String? {
        guard let cfg = JMAPConfigStore.first(),
              let url = URL(string: cfg.sessionURL),
              let store else {
            sendError = "No JMAP account configured"
            return nil
        }
        isSending = true
        sendStatus = "Connecting…"
        defer { isSending = false }
        do {
            let client = JMAPClient(config: .init(sessionURL: url,
                                                  credential: .bearer(cfg.bearerToken)))
            let accID = try await store.upsertAccount(
                name: cfg.displayName, address: cfg.senderEmail, kind: "jmap"
            )
            let sync = JMAPSync(client: client, store: store, localAccountID: accID)
            sendStatus = "Sending…"
            let id = try await sync.sendPlainEmail(
                from: cfg.senderEmail, to: recipients,
                subject: draftSubject, body: draftBody,
                inReplyTo: draftInReplyTo, references: draftReferences
            )
            sendStatus = "Sent."
            lastSentEmailID = id
            clearDraft()
            return id
        } catch {
            sendError = error.localizedDescription
            return nil
        }
    }

    private func sendCurrentDraftSMTP(recipients: [String]) async -> String? {
        guard let cfg = IMAPConfigStore.first() else {
            sendError = "No IMAP account configured"
            return nil
        }
        isSending = true
        sendStatus = "Connecting…"
        defer { isSending = false }
        do {
            let smtp = SMTPClient(config: SMTPConfig(
                host: cfg.smtpHost, port: cfg.smtpPort, useTLS: true,
                username: cfg.username, password: cfg.password
            ))
            try await smtp.connect()
            sendStatus = "Authenticating…"
            try await smtp.authLogin()
            sendStatus = "Sending…"
            let messageID = "<\(UUID().uuidString)@maxmailin.local>"
            let queued = try await smtp.send(SMTPClient.OutboundMessage(
                from: cfg.senderEmail,
                to: recipients,
                subject: draftSubject,
                plainBody: draftBody,
                messageID: messageID,
                inReplyTo: draftInReplyTo,
                references: draftReferences
            ))
            await smtp.disconnect()
            sendStatus = "Sent."
            lastSentEmailID = queued
            clearDraft()
            return messageID
        } catch {
            sendError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Draft state

    func newMessage() {
        clearDraft()
        showCompose = true
    }

    func startReply(replyAll: Bool = false) {
        guard let header = selectedHeader else { return }
        let originalBody = currentBody?.plain ?? ""
        let sender = JMAPConfigStore.first()?.senderEmail ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            var refs: [String] = []
            if let store = self.store,
               let t = try? await store.messageThreading(rowID: header.id) {
                refs = t.references
            }
            let draft = ComposePrefill.build(
                mode: replyAll ? .replyAll : .reply,
                originalSubject: header.subject,
                originalFrom: header.fromAddress,
                originalTo: [],
                originalCc: [],
                originalDate: header.date,
                originalBody: originalBody,
                originalMessageID: header.messageID,
                originalReferences: refs,
                currentUserAddress: sender
            )
            self.applyDraft(draft)
            self.showCompose = true
        }
    }

    func startForward() {
        guard let header = selectedHeader else { return }
        let originalBody = currentBody?.plain ?? ""
        let sender = JMAPConfigStore.first()?.senderEmail ?? ""
        let draft = ComposePrefill.build(
            mode: .forward,
            originalSubject: header.subject,
            originalFrom: header.fromAddress,
            originalTo: [],
            originalCc: [],
            originalDate: header.date,
            originalBody: originalBody,
            originalMessageID: header.messageID,
            originalReferences: [],
            currentUserAddress: sender
        )
        applyDraft(draft)
        showCompose = true
    }

    func persistDraft() {
        let draft = currentDraftSnapshot()
        ComposeDraftStore.save(draft)
    }

    func restoreDraftFromDisk() {
        if let stored = ComposeDraftStore.load() {
            applyDraft(stored)
        }
    }

    func clearDraft() {
        draftTo = ""
        draftSubject = ""
        draftBody = ""
        draftInReplyTo = nil
        draftReferences = []
        sendError = nil
        ComposeDraftStore.clear()
    }

    private func applyDraft(_ d: ComposeDraft) {
        draftTo = d.to
        draftSubject = d.subject
        draftBody = d.body
        draftInReplyTo = d.inReplyTo
        draftReferences = d.references
    }

    private func currentDraftSnapshot() -> ComposeDraft {
        ComposeDraft(
            to: draftTo,
            subject: draftSubject,
            body: draftBody,
            inReplyTo: draftInReplyTo,
            references: draftReferences
        )
    }

    private var selectedHeader: MessageHeader? {
        guard let id = selectedMessageID else { return nil }
        if let h = headers.first(where: { $0.id == id }) { return h }
        if let hit = searchResults.first(where: { $0.id == id }) {
            return MessageHeader(
                id: hit.id, messageID: hit.messageID, folder: "",
                subject: hit.subject, fromAddress: hit.fromAddress,
                date: hit.date, sizeBytes: 0, flags: [], snippet: nil
            )
        }
        return nil
    }

    // MARK: - Live JMAP push

    /// Open the EventSource stream and run refreshLiveMail on every state
    /// change the server pushes. Reconnects with backoff if the stream drops.
    /// No JMAP credentials → silent no-op so dev / archive-only use stays
    /// quiet.
    func startLivePush() {
        guard let cfg = JMAPConfigStore.first(),
              let url = URL(string: cfg.sessionURL) else { return }
        let client = JMAPClient(config: .init(sessionURL: url,
                                              credential: .bearer(cfg.bearerToken)))
        let source = JMAPEventSource(client: client)
        liveEventSource = source
        Task.detached { @MainActor [weak self] in
            await source.start { @Sendable event in
                await MailViewModel.handlePushEvent(event)
            }
        }
    }

    func stopLivePush() {
        let source = liveEventSource
        liveEventSource = nil
        isLivePushConnected = false
        Task.detached { await source?.stop() }
    }

    /// Static dispatcher routes events back onto the main actor without
    /// capturing self (the @Sendable closure can't hold an isolated ref).
    @MainActor
    private static func handlePushEvent(_ event: JMAPEventSource.Event) {
        let vm = MailViewModel.shared
        switch event {
        case .connected:
            vm.isLivePushConnected = true
            vm.statusMessage = "Live"
        case .stateChange:
            Task { await vm.refreshLiveMail() }
        case .disconnected(let reason):
            vm.isLivePushConnected = false
            vm.statusMessage = "Disconnected — \(reason)"
            // Try once more after 30s; gentle, not a tight retry loop.
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                vm.startLivePush()
            }
        }
    }

    // MARK: - Live JMAP refresh

    /// Sync against whichever live account is configured. We prefer JMAP
    /// (push-aware + delta-friendly) when present and fall back to IMAP
    /// for everything else (Gmail/iCloud/Yahoo via app passwords).
    func refreshLiveMail() async {
        if JMAPConfigStore.first() != nil {
            await refreshLiveMailJMAP()
        } else if IMAPConfigStore.first() != nil {
            await refreshLiveMailIMAP()
        } else {
            errorMessage = "No mail account configured"
        }
    }

    private func refreshLiveMailIMAP() async {
        guard let cfg = IMAPConfigStore.first(), let store else { return }
        isRefreshing = true
        refreshStatus = "Connecting…"
        defer { isRefreshing = false }
        do {
            let accID = try await store.upsertAccount(
                name: cfg.displayName, address: cfg.senderEmail, kind: "imap"
            )
            let client = IMAPClient(config: IMAPConfig(
                host: cfg.host, port: cfg.port, useTLS: cfg.useTLS,
                username: cfg.username, password: cfg.password
            ))
            let sync = IMAPSync(client: client, store: store, localAccountID: accID)
            refreshStatus = "Syncing INBOX…"
            let result = try await sync.pullRecent(folder: "INBOX",
                                                   since: Date().addingTimeInterval(-30 * 86_400))
            refreshStatus = result.ingested > 0 ? "\(result.ingested) new" : "Up to date"
            await refreshAccountsAndFolders()
            await loadHeaders()
            if result.ingested > 0 {
                let example = self.headers.first?.fromAddress
                Task.detached {
                    await MailNotifications.postNewMail(
                        count: result.ingested, exampleSender: example
                    )
                }
            }
        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// Sync against the configured JMAP server. For each known mailbox we
    /// prefer Email/changes (when a sync-state cursor exists) and fall back
    /// to pullRecent — which itself seeds the cursor for next time.
    private func refreshLiveMailJMAP() async {
        guard let cfg = JMAPConfigStore.first(),
              let url = URL(string: cfg.sessionURL),
              let store else {
            errorMessage = "No JMAP account configured"
            return
        }
        isRefreshing = true
        refreshStatus = "Connecting…"
        defer { isRefreshing = false }
        do {
            let client = JMAPClient(config: .init(sessionURL: url,
                                                  credential: .bearer(cfg.bearerToken)))
            let accID = try await store.upsertAccount(
                name: cfg.displayName, address: cfg.senderEmail, kind: "jmap"
            )
            let sync = JMAPSync(client: client, store: store, localAccountID: accID)
            let mailboxes = try await sync.listMailboxes()
            refreshStatus = "Found \(mailboxes.count) mailboxes…"
            var totalNew = 0
            for box in mailboxes {
                refreshStatus = "Syncing \(box.name)…"
                let session = try await client.currentSession()
                let scope = "email:\(session.primaryMailAccountID ?? "")"
                if let _ = try await store.syncState(accountID: accID, scope: scope) {
                    if let res = try? await sync.syncIncremental(
                        mailboxHint: box, folderName: box.name
                    ) {
                        totalNew += res.added
                    }
                } else {
                    if let res = try? await sync.pullRecent(
                        mailbox: box, folderName: box.name, limit: 200
                    ) {
                        totalNew += res.ingested
                    }
                }
            }
            refreshStatus = totalNew > 0 ? "\(totalNew) new" : "Up to date"
            await refreshAccountsAndFolders()
            await loadHeaders()
            if totalNew > 0 {
                let example = self.headers.first?.fromAddress
                Task.detached {
                    await MailNotifications.postNewMail(
                        count: totalNew, exampleSender: example
                    )
                }
            }
        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Flag mutation

    func toggleSeen(rowID: Int64) async {
        await applyFlagChange(rowID: rowID, keyword: "$seen") { $0.contains(.seen) ? false : true }
    }

    func toggleFlagged(rowID: Int64) async {
        await applyFlagChange(rowID: rowID, keyword: "$flagged") { $0.contains(.flagged) ? false : true }
    }

    private func applyFlagChange(
        rowID: Int64,
        keyword: String,
        newValue: (MessageFlags) -> Bool
    ) async {
        guard let store else { return }
        do {
            let current = (try await store.messageFlags(messageRowID: rowID)) ?? []
            let target = newValue(current)
            let isLive = try await store.isJMAPLinked(messageRowID: rowID)
            if isLive,
               let cfg = JMAPConfigStore.first(),
               let url = URL(string: cfg.sessionURL) {
                let client = JMAPClient(config: .init(sessionURL: url,
                                                      credential: .bearer(cfg.bearerToken)))
                guard let acc = selectedAccount else { return }
                let sync = JMAPSync(client: client, store: store, localAccountID: acc.id)
                try await sync.setKeyword(localRowID: rowID, keyword: keyword, value: target)
            } else {
                // Local-only message — just flip the bit locally.
                let bit: MessageFlags = (keyword == "$seen") ? .seen : .flagged
                var f = current
                if target { f.insert(bit) } else { f.remove(bit) }
                try await store.updateMessageFlags(messageRowID: rowID, flags: f)
            }
            await loadHeaders()
            await loadFolders()
        } catch {
            errorMessage = error.localizedDescription
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
