import Foundation

/// JMAP push channel (RFC 8620 §7.3).
///
/// Opens a long-lived Server-Sent Events stream against `session.eventSourceUrl`
/// and emits one `Event.stateChange` per push from the server. The caller
/// reacts by running `JMAPSync.syncIncremental(...)` — we never poll, we
/// only fetch when the server tells us something actually changed.
public actor JMAPEventSource {

    public enum Event: Sendable {
        case connected
        case stateChange
        case disconnected(reason: String)
    }

    public typealias Handler = @Sendable (Event) async -> Void

    private let client: JMAPClient
    private let urlSession: URLSession
    private var task: Task<Void, Never>?

    public init(client: JMAPClient, urlSession: URLSession = .shared) {
        self.client = client
        self.urlSession = urlSession
    }

    /// Begin the push stream. `onEvent` runs every time the server emits an
    /// SSE message. Subscribing twice cancels the previous stream first so
    /// callers can freely re-invoke after credentials change.
    public func start(onEvent: @escaping Handler) {
        stop()
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.run(onEvent: onEvent)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public var isRunning: Bool { task != nil }

    private func run(onEvent: @escaping Handler) async {
        do {
            let session = try await client.currentSession()
            guard let raw = session.eventSourceUrl,
                  let url = Self.buildEventSourceURL(rawTemplate: raw) else {
                await onEvent(.disconnected(reason: "server advertises no eventSourceUrl"))
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            // Mirror the JMAPClient's auth so the stream is associated with
            // the same account.
            await client.stampAuth(on: &req)

            let (bytes, response) = try await urlSession.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                await onEvent(.disconnected(reason: "HTTP \(http.statusCode)"))
                return
            }
            await onEvent(.connected)

            // SSE: events are separated by blank lines; we only care that
            // *something* came in — the body itself tells us "stuff changed".
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    await onEvent(.stateChange)
                }
                // event: / id: / : (comment ping) / blank — all ignored.
            }
            await onEvent(.disconnected(reason: "stream closed"))
        } catch {
            await onEvent(.disconnected(reason: error.localizedDescription))
        }
    }

    /// Build the subscription URL by appending the documented query params.
    /// Subscribing only to Email keeps the stream cheap; closeafter=no means
    /// the server keeps the connection open after each push; ping=30 gets
    /// us a keep-alive frame every 30 seconds so a dead TCP connection is
    /// detected within the minute.
    static func buildEventSourceURL(rawTemplate: String) -> URL? {
        // The session may advertise a templated URL with {types}/{closeafter}/
        // {ping} placeholders, a query string carrying those params already,
        // or a bare URL with neither. We handle the three cases by checking
        // the original template — never the post-substitution result.
        let hasPlaceholders = rawTemplate.contains("{types}")
        let hasTypesQuery   = rawTemplate.contains("types=")
        if hasPlaceholders {
            let substituted = rawTemplate
                .replacingOccurrences(of: "{types}",      with: "Email")
                .replacingOccurrences(of: "{closeafter}", with: "no")
                .replacingOccurrences(of: "{ping}",       with: "30")
            return URL(string: substituted)
        }
        if hasTypesQuery {
            return URL(string: rawTemplate)
        }
        let sep = rawTemplate.contains("?") ? "&" : "?"
        return URL(string: rawTemplate + sep + "types=Email&closeafter=no&ping=30")
    }
}

// Cross-actor helper so the event-source actor can stamp the JMAPClient's
// configured bearer / basic auth onto a fresh URLRequest before opening
// the SSE stream.
extension JMAPClient {
    func stampAuth(on req: inout URLRequest) async {
        applyAuth(to: &req)
    }
}
