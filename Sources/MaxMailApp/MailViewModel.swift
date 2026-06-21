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
    /// HMAC-chained audit log + Bates / custody / GDPR engines, bound to
    /// the open store. Built once the store is open in `bootstrap`; nil
    /// only between launch and the first successful bootstrap.
    var forensic: ForensicCoordinator?
    var accounts: [AccountSummary] = []
    var selectedAccount: AccountSummary?

    var folders: [FolderSummary] = []
    var selectedFolder: String?

    var headers: [MessageHeader] = []
    /// Thread groupings for the current `headers` page. Built lazily —
    /// only present after a `loadHeadersWithThreading()` call. Empty
    /// when threading is off, when there's nothing to render, or
    /// when the user is viewing a search result.
    var threads: [MailThread] = []
    var groupByThread: Bool = true
    /// Thread root → expanded? When false the list shows only the
    /// thread row; when true it shows every message in the chain.
    var expandedThreads: Set<String> = []
    var selectedMessageID: Int64?

    var currentBody: (plain: String?, html: String?)?
    var currentAttachments: [AttachmentRef] = []
    var currentNLP: EmailNLP?
    var currentForensics: ForensicResult?
    var currentAnomalies: [EmailAnomaly] = []

    // Custody / forensic state for the currently selected message.
    var currentMessageSeal: (sealedAt: Date, sha256Hex: String)?
    var currentMessageBates: String?
    var custodyStatus: String?
    var isCustodyBusy: Bool = false

    /// Snooze wake time for the currently selected message, when one
    /// is scheduled. The detail-pane chip reads this directly.
    var currentMessageSnoozeUntil: Date?

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
    var showCommandPalette: Bool = false
    var showRules: Bool = false
    var showSecurity: Bool = false
    var showForensicCenter: Bool = false
    var showForensicSettings: Bool = false
    var isLocked: Bool = false
    private var lastBackgroundedAt: Date?

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
            self.forensic = ForensicCoordinator.makeDefault(store: s)
            statusMessage = "Ready"
            await refreshAccountsAndFolders()
            await loadHeaders()
            startLivePush()
            // First launch — show the welcome flow. Re-launches don't.
            if !WelcomeShownStore.hasShown {
                showWelcome = true
            }
            // App lock: if the user has enabled biometric lock, start
            // locked so the next foreground action is to authenticate.
            if BiometricLock.enabled {
                isLocked = true
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
            headers = []; threads = []; return
        }
        do {
            if groupByThread {
                let rows = try await store.threadableHeaders(
                    in: folder, accountID: acc.id, limit: 200
                )
                headers = rows.map(\.header)
                threads = ThreadGrouper.group(rows)
            } else {
                headers = try await store.headers(in: folder, accountID: acc.id, limit: 200)
                threads = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Flip threaded ↔ flat. Reloads the current page so the list view
    /// switches over in one tick. The previously expanded set is kept
    /// so going threaded → flat → threaded leaves the user's open
    /// chains intact.
    func setGroupByThread(_ on: Bool) async {
        groupByThread = on
        await loadHeaders()
    }

    /// Toggle a thread's expanded/collapsed state by its root id.
    func toggleThread(rootID: String) {
        if expandedThreads.contains(rootID) {
            expandedThreads.remove(rootID)
        } else {
            expandedThreads.insert(rootID)
        }
    }

    /// Move selection by `offset` rows in the current message list
    /// (positive = down, negative = up). Used by J/K keyboard nav so
    /// the user can blaze through a folder without touching the mouse.
    /// No-op when the list is empty or the offset would land outside
    /// the visible range — caller can spam J past the end without
    /// causing wraparound or selection jumps.
    func moveSelection(by offset: Int) async {
        guard !headers.isEmpty else { return }
        let currentIndex: Int
        if let id = selectedMessageID,
           let i = headers.firstIndex(where: { $0.id == id }) {
            currentIndex = i
        } else {
            currentIndex = offset >= 0 ? -1 : headers.count
        }
        let target = currentIndex + offset
        guard target >= 0, target < headers.count else { return }
        await selectMessage(rowID: headers[target].id)
    }

    func selectMessage(rowID: Int64) async {
        selectedMessageID = rowID
        currentNLP = nil
        currentForensics = nil
        currentAnomalies = []
        currentMessageSeal = nil
        currentMessageBates = nil
        custodyStatus = nil
        currentMessageSnoozeUntil = nil
        guard let store else { return }
        await loadCustodyStatus(for: rowID)
        currentMessageSnoozeUntil = try? await store.snoozeUntil(messageRowID: rowID)
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

    // MARK: - Spam / block sender

    /// Move `rowID` into the Spam folder for the current account.
    func markAsSpam(rowID: Int64) async {
        guard let store, let acc = selectedAccount else { return }
        do {
            try await store.markAsSpam(messageRowID: rowID, accountID: acc.id)
            await loadHeaders()
            await loadFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rescue `rowID` from Spam back into the INBOX. Use this for
    /// false positives — explicit user "this is not spam" action.
    func markAsNotSpam(rowID: Int64) async {
        guard let store, let acc = selectedAccount else { return }
        do {
            try await store.markAsNotSpam(messageRowID: rowID, accountID: acc.id)
            await loadHeaders()
            await loadFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Block all future mail from `address` and dump the current
    /// `rowID` into Spam in the same gesture. The two-in-one is what
    /// a user means when they click "Block sender" — they don't want
    /// to also have to drag the offending message manually.
    func blockSender(address: String, currentRowID: Int64?) async {
        guard let store, let acc = selectedAccount else { return }
        do {
            try await store.blockSender(address: address, reason: nil)
            if let rowID = currentRowID {
                try await store.markAsSpam(messageRowID: rowID, accountID: acc.id)
            }
            await loadHeaders()
            await loadFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Snooze

    /// Hide `rowID` from headers queries until `until`. Caller picks
    /// the wake time — typically via `SnoozeOption.wakeTime(from:)`
    /// but a custom time works too. After the snooze lands the page
    /// is reloaded so the row drops out of the visible list
    /// immediately.
    func snooze(rowID: Int64, until: Date) async {
        guard let store else { return }
        do {
            try await store.snoozeMessage(messageRowID: rowID, until: until)
            if rowID == selectedMessageID {
                currentMessageSnoozeUntil = until
            }
            await loadHeaders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Convenience for the context-menu quick picks. Forwards through
    /// to `snooze(rowID:until:)` after resolving the option's wake
    /// time against `Date()`.
    func snooze(rowID: Int64, option: SnoozeOption) async {
        await snooze(rowID: rowID, until: option.wakeTime(from: Date()))
    }

    func unsnooze(rowID: Int64) async {
        guard let store else { return }
        do {
            try await store.unsnoozeMessage(messageRowID: rowID)
            if rowID == selectedMessageID {
                currentMessageSnoozeUntil = nil
            }
            await loadHeaders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Custody actions

    /// Refresh seal + Bates state for the currently selected message so
    /// the detail toolbar shows the right chips. Called from
    /// `selectMessage`; cheap (two indexed reads), so it doesn't run on
    /// a background task.
    func loadCustodyStatus(for rowID: Int64) async {
        guard let store else { return }
        let seal = try? await store.messageSeal(messageRowID: rowID)
        let bates = try? await store.batesAssignment(messageRowID: rowID)?.batesNumber
        if selectedMessageID == rowID {
            currentMessageSeal = seal
            currentMessageBates = bates
        }
    }

    /// Identity recorded on every audit entry. Uses the account address
    /// when one is selected; falls back to a generic "examiner" so the
    /// chain never has an empty actor (the audit canonicalisation
    /// distinguishes empty from missing, but downstream readers find
    /// "examiner" much clearer than "").
    private var custodyActorName: String {
        selectedAccount?.address ?? "examiner"
    }

    func sealCurrentMessage() async {
        guard let forensic, let rowID = selectedMessageID else { return }
        isCustodyBusy = true
        defer { isCustodyBusy = false }
        do {
            let report = try await forensic.custody.sealMessages(
                rowIDs: [rowID], actor: custodyActorName
            )
            custodyStatus = report.newlySealed > 0
                ? "Sealed at \(Self.formatTimeNow())"
                : "Already sealed"
            await loadCustodyStatus(for: rowID)
        } catch {
            custodyStatus = "Seal failed: \(error.localizedDescription)"
        }
    }

    func verifyCurrentMessage() async {
        guard let forensic, let rowID = selectedMessageID else { return }
        isCustodyBusy = true
        defer { isCustodyBusy = false }
        do {
            let v = try await forensic.custody.verifyMessages(
                rowIDs: [rowID], actor: custodyActorName
            )
            if v.unsealed.contains(rowID) {
                custodyStatus = "Not sealed yet — seal first"
            } else if !v.drifted.isEmpty {
                custodyStatus = "Tampered — content has changed since seal"
            } else {
                custodyStatus = "Verified at \(Self.formatTimeNow())"
            }
        } catch {
            custodyStatus = "Verify failed: \(error.localizedDescription)"
        }
    }

    func recordCustodyEvent(kind: CustodyEventKind, description: String) async {
        guard let forensic, let rowID = selectedMessageID else { return }
        isCustodyBusy = true
        defer { isCustodyBusy = false }
        do {
            _ = try await forensic.custody.recordEvent(
                kind: kind,
                actor: custodyActorName,
                subjectKind: "message",
                subjectID: String(rowID),
                description: description
            )
            custodyStatus = "\(kind.rawValue) recorded"
        } catch {
            custodyStatus = "Failed to record: \(error.localizedDescription)"
        }
    }

    private static func formatTimeNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
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

    // MARK: - App lock lifecycle

    /// Called when the app moves to the background (scenePhase change).
    /// We remember the timestamp so the foreground hook can decide
    /// whether the re-lock window has elapsed.
    func handleBackgrounded() {
        lastBackgroundedAt = Date()
    }

    /// Called when the app comes back to the foreground. Locks if the
    /// idle window has been crossed.
    func handleForegrounded() {
        guard BiometricLock.enabled else { return }
        guard let backgroundedAt = lastBackgroundedAt else { return }
        let elapsed = Date().timeIntervalSince(backgroundedAt)
        if elapsed >= BiometricLock.relockAfterSeconds {
            isLocked = true
        }
        lastBackgroundedAt = nil
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
