import Foundation

/// Drives a long-running, cancellable, progress-reporting NLP catch-up over
/// every unanalyzed message in an account.
///
/// The actor owns the running task and exposes start / stop, so the UI can
/// safely toggle the run without worrying about double-launching. Each
/// MailStore.analyzeBatch call yields the actor between iterations so search
/// and pagination stay responsive while the catch-up is grinding.
public actor BackgroundAnalyzer {
    public typealias ProgressHandler = @Sendable (AnalysisProgress) async -> Void

    private let store: MailStore
    private var task: Task<Void, Never>?

    public init(store: MailStore) { self.store = store }

    public var isRunning: Bool { task != nil }

    /// Start (or restart) catch-up for `accountID`. Calling while already
    /// running is a no-op; cancel first if you want to change parameters.
    public func start(
        accountID: Int64,
        batchSize: Int = 100,
        onProgress: ProgressHandler? = nil
    ) {
        guard task == nil else { return }
        let store = self.store
        task = Task.detached { [weak self] in
            await self?.run(accountID: accountID, batchSize: batchSize,
                            store: store, onProgress: onProgress)
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(
        accountID: Int64,
        batchSize: Int,
        store: MailStore,
        onProgress: ProgressHandler?
    ) async {
        defer { self.task = nil }
        while !Task.isCancelled {
            do {
                let processed = try await store.processBatch(
                    accountID: accountID, batchSize: batchSize
                )
                let progress = (try? await store.processingProgress(accountID: accountID))
                    ?? AnalysisProgress(analyzed: 0, total: 0)
                if let onProgress { await onProgress(progress) }
                if processed == 0 { return }  // nothing left to do
                await Task.yield()
            } catch {
                // First cut: stop on the first error. The next start() will
                // pick up where we left off because the loop is idempotent.
                return
            }
        }
    }
}
