import Foundation

/// Wrap an underlying AsyncThrowingStream factory so that errors
/// trigger a backoff-paced retry instead of terminating the consumer.
/// Used by the IMAP IDLE auto-reconnect path and the JMAP EventSource
/// reconnect path so a dropped network never strands the live channel.
///
/// Contract:
/// - Calls `open()` to get a fresh stream.
/// - Yields every event to the returned stream.
/// - On error: sleeps the next `Backoff` delay (with jitter), then
///   re-opens. Calls `onRetry(delay, error)` first so the UI can show
///   a "reconnecting in 2 s…" affordance.
/// - On successful event flow: resets the backoff so a brief blip
///   doesn't carry penalty into the next normal session.
/// - Termination of the returned stream (consumer cancels, e.g.
///   `for-await` task ends) cancels the wrapper Task, which exits
///   the loop on the next cancellation check.
public func resilientStream<E: Sendable>(
    backoff: Backoff = Backoff(),
    onRetry: @escaping @Sendable (TimeInterval, Error) async -> Void = { _, _ in },
    open: @escaping @Sendable () async throws -> AsyncThrowingStream<E, Error>
) -> AsyncThrowingStream<E, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var current = backoff
            while !Task.isCancelled {
                var sawEvent = false
                do {
                    let stream = try await open()
                    for try await event in stream {
                        sawEvent = true
                        continuation.yield(event)
                    }
                    // Stream finished cleanly. If we got at least one
                    // event the previous attempt was healthy — reset
                    // the backoff so the next blip doesn't start
                    // mid-schedule.
                    if sawEvent { current.reset() }
                    // No error but no events either: avoid a hot loop
                    // by waiting at least the initial delay.
                    if !sawEvent {
                        try? await Task.sleep(nanoseconds: UInt64(current.initial * 1_000_000_000))
                    }
                } catch {
                    if Task.isCancelled { break }
                    let delay = current.nextDelay()
                    await onRetry(delay, error)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
