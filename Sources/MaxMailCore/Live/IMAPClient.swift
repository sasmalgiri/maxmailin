import Foundation

public struct IMAPConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    public var username: String
    public var password: String

    public init(host: String, port: UInt16 = 993, useTLS: Bool = true,
                username: String, password: String) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.password = password
    }
}

public struct IMAPFolder: Sendable, Hashable {
    public let name: String
    public let attributes: [String]
}

public struct IMAPSelected: Sendable {
    public let folder: String
    public let exists: Int
    public let uidValidity: Int64
    public let uidNext: Int64
}

/// One streamed message from UID FETCH BODY[].
public struct IMAPMessage: Sendable {
    public let uid: Int64
    public let flags: [String]
    public let raw: Data    // RFC 5322 bytes — feed to RFC5322Parser
}

/// High-level IMAP protocol client. Strictly streams — `fetchAllMessages`
/// has no peer here. Anything that returns a folder's mail does so via
/// AsyncThrowingStream so the memory budget stays bounded to one chunk.
public actor IMAPClient {

    private let config: IMAPConfig
    private let wire: IMAPConnection
    private var nextTagCounter: Int = 0
    private var loggedIn = false

    public init(config: IMAPConfig) {
        self.config = config
        self.wire = IMAPConnection(host: config.host, port: config.port, useTLS: config.useTLS)
    }

    // MARK: - Connect / login

    public func connect() async throws {
        try await wire.connect()
    }

    public func login() async throws {
        let cmd = "LOGIN \(quoted(config.username)) \(quoted(config.password))"
        let resp = try await wire.send(tag: nextTag(), command: cmd)
        guard resp.isOK else {
            throw IMAPError.authFailed(resp.resultText)
        }
        loggedIn = true
    }

    /// SASL XOAUTH2 — Gmail / Microsoft 365 / Yahoo modern auth.
    /// `accessToken` is a current bearer token from the provider's
    /// OAuth flow (refresh is the caller's responsibility via
    /// OAuthTokenProvider). The initial response is sent inline per
    /// RFC 7628 so the happy path completes in one round-trip.
    ///
    /// On failure the server sends `+ <base64-error>` to ask us for
    /// an empty acknowledgement, then replies tagged NO. We send the
    /// empty line and surface `IMAPError.authFailed` with the
    /// resultText so the UI can prompt for re-auth.
    public func authXOAUTH2(accessToken: String) async throws {
        let sasl = XOAUTH2.saslInitialResponse(
            username: config.username, accessToken: accessToken
        )
        let tag = nextTag()
        try await wire.sendRawCommand("\(tag) AUTHENTICATE XOAUTH2 \(sasl)\r\n")
        // Server either sends a tagged completion (success) or a `+ ...`
        // continuation asking for an empty line on failure. The wire's
        // higher-level send() swallows `+` lines, so we drive this
        // exchange against the raw read path.
        while true {
            let line = try await wire.readUntaggedOrContinuation()
            if line.hasPrefix("\(tag) ") {
                let rest = line.dropFirst(tag.count + 1)
                if rest.hasPrefix("OK") {
                    loggedIn = true
                    return
                }
                throw IMAPError.authFailed(String(rest))
            }
            if line.hasPrefix("+") {
                // Acknowledge the failure continuation so the server
                // can issue the tagged NO with a real error message.
                try await wire.sendRawCommand("\r\n")
                continue
            }
            // Untagged informational line; loop until we see the tag.
        }
    }

    public func disconnect() async {
        if loggedIn {
            _ = try? await wire.send(tag: nextTag(), command: "LOGOUT")
            loggedIn = false
        }
        await wire.disconnect()
    }

    public func capabilities() async throws -> [String] {
        let resp = try await wire.send(tag: nextTag(), command: "CAPABILITY")
        guard resp.isOK else { throw IMAPError.commandFailed(resp.resultText) }
        for line in resp.untagged where line.text.hasPrefix("* CAPABILITY ") {
            return line.text
                .dropFirst("* CAPABILITY ".count)
                .split(separator: " ")
                .map { String($0).uppercased() }
        }
        return []
    }

    // MARK: - Folders

    public func listFolders() async throws -> [IMAPFolder] {
        // LIST "" "*" returns all folders. Reference is empty string,
        // mailbox is "*" wildcard.
        let resp = try await wire.send(tag: nextTag(), command: "LIST \"\" \"*\"")
        guard resp.isOK else { throw IMAPError.commandFailed(resp.resultText) }
        var folders: [IMAPFolder] = []
        for line in resp.untagged where line.text.hasPrefix("* LIST ") {
            if let parsed = parseListLine(line.text) {
                folders.append(parsed)
            }
        }
        return folders
    }

    @discardableResult
    public func select(folder: String) async throws -> IMAPSelected {
        let resp = try await wire.send(
            tag: nextTag(),
            command: "SELECT \(quoted(folder))"
        )
        guard resp.isOK else { throw IMAPError.commandFailed(resp.resultText) }

        var exists = 0
        var uidValidity: Int64 = 0
        var uidNext: Int64 = 0
        for line in resp.untagged {
            let t = line.text
            // * <N> EXISTS
            if t.hasSuffix(" EXISTS"), t.hasPrefix("* ") {
                if let n = Int(t.dropFirst(2).dropLast(" EXISTS".count)) {
                    exists = n
                }
            }
            // * OK [UIDVALIDITY 12345] ...
            if let r = t.range(of: "UIDVALIDITY ") {
                let after = t[r.upperBound...]
                if let endBracket = after.firstIndex(of: "]"),
                   let n = Int64(after[after.startIndex..<endBracket]) {
                    uidValidity = n
                }
            }
            // * OK [UIDNEXT 12346] ...
            if let r = t.range(of: "UIDNEXT ") {
                let after = t[r.upperBound...]
                if let endBracket = after.firstIndex(of: "]"),
                   let n = Int64(after[after.startIndex..<endBracket]) {
                    uidNext = n
                }
            }
        }
        return IMAPSelected(folder: folder, exists: exists,
                            uidValidity: uidValidity, uidNext: uidNext)
    }

    // MARK: - Search

    /// UID SEARCH SINCE <date> — returns the matching UIDs as a sorted set.
    /// SINCE is the RFC 3501 date format ("01-Jan-2024").
    public func uidSearch(since: Date?) async throws -> [Int64] {
        let cmd: String
        if let since {
            let df = DateFormatter()
            df.dateFormat = "dd-MMM-yyyy"
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            cmd = "UID SEARCH SINCE \(df.string(from: since))"
        } else {
            cmd = "UID SEARCH ALL"
        }
        let resp = try await wire.send(tag: nextTag(), command: cmd)
        guard resp.isOK else { throw IMAPError.commandFailed(resp.resultText) }
        for line in resp.untagged where line.text.hasPrefix("* SEARCH") {
            // "* SEARCH 100 105 200 …"
            let parts = line.text.dropFirst("* SEARCH".count).split(separator: " ")
            return parts.compactMap { Int64($0) }
        }
        return []
    }

    // MARK: - Streaming fetch

    /// Walk the given UIDs in `chunkSize` windows. For each chunk we issue a
    /// single UID FETCH (FLAGS BODY.PEEK[]) command and yield each parsed
    /// message immediately, releasing the chunk buffer before the next
    /// FETCH. Memory stays bounded to one chunk × per-message body bytes.
    ///
    /// `BODY.PEEK[]` is used (not `BODY[]`) so the server doesn't auto-flip
    /// the \Seen flag on the messages we touch — that's mailin's bug we
    /// don't want to inherit.
    public nonisolated func streamMessages(
        uids: [Int64],
        chunkSize: Int = 500
    ) -> AsyncThrowingStream<IMAPMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var i = 0
                    while i < uids.count {
                        let end = min(i + chunkSize, uids.count)
                        let range = uids[i..<end]
                        i = end
                        try await self.fetchChunk(uids: Array(range)) { msg in
                            continuation.yield(msg)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func fetchChunk(uids: [Int64], onMessage: (IMAPMessage) -> Void) async throws {
        let set = uids.map { String($0) }.joined(separator: ",")
        let resp = try await wire.send(
            tag: nextTag(),
            command: "UID FETCH \(set) (UID FLAGS BODY.PEEK[])"
        )
        guard resp.isOK else { throw IMAPError.commandFailed(resp.resultText) }

        for line in resp.untagged {
            guard line.text.contains(" FETCH "),
                  let body = line.literal,
                  let uid = parseUIDFromFetchLine(line.text)
            else { continue }
            let flags = parseFlagsFromFetchLine(line.text)
            onMessage(IMAPMessage(uid: uid, flags: flags, raw: body))
        }
    }

    // MARK: - Flag writes (UID STORE)

    /// Add or remove an IMAP system flag on a single message by UID.
    /// `keyword` is the literal flag with backslash, e.g. "\Seen", "\Flagged".
    public func setFlag(uid: Int64, keyword: String, add: Bool) async throws {
        let op = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        let resp = try await wire.send(
            tag: nextTag(),
            command: "UID STORE \(uid) \(op) (\(keyword))"
        )
        guard resp.isOK else { throw IMAPError.commandFailed(resp.resultText) }
    }

    public func setSeen(uid: Int64, _ seen: Bool) async throws {
        try await setFlag(uid: uid, keyword: "\\Seen", add: seen)
    }

    public func setFlagged(uid: Int64, _ flagged: Bool) async throws {
        try await setFlag(uid: uid, keyword: "\\Flagged", add: flagged)
    }

    // MARK: - IDLE push

    public enum IdleEvent: Sendable {
        /// Server announced a new EXISTS count. Trigger an incremental sync.
        case exists(Int)
        /// Server announced an EXPUNGE (sequence number deleted).
        case expunge(Int)
        /// Heartbeat / other untagged. Useful for "connection still alive".
        case heartbeat(String)
        case disconnected(String)
    }

    /// Stream IDLE events from the currently selected folder. Single
    /// IDLE window; caller is responsible for re-issuing it before the
    /// server timeout. For long-lived push, use `idleWithAutoRestart`
    /// which handles the RFC 2177 ≤29-minute refresh internally.
    public nonisolated func idle() -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runIdleWindow(restartAfter: nil) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Long-lived IDLE push with automatic re-issue. Every
    /// `restartAfter` seconds we send DONE, read the server's tagged
    /// completion, and immediately open a fresh IDLE — so the
    /// connection never sits idle long enough to hit RFC 2177's
    /// 29-minute ceiling. The consumer sees a single continuous event
    /// stream across the rolling windows.
    ///
    /// Cancellation: cancelling the iteration (e.g. `for-await` task
    /// goes away) cancels the inner Task, which in turn fires a final
    /// DONE so the server-side IDLE state closes cleanly rather than
    /// being torn down with the connection.
    public nonisolated func idleWithAutoRestart(
        restartAfter: TimeInterval = 28 * 60
    ) -> AsyncThrowingStream<IdleEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        try await self.runIdleWindow(restartAfter: restartAfter) { event in
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One IDLE window. When `restartAfter` is non-nil, a side task
    /// fires DONE after that many seconds (or as soon as the
    /// surrounding Task is cancelled, whichever comes first) so the
    /// window closes cleanly. The main loop reads lines until it sees
    /// the IDLE's own tagged completion, then returns.
    private func runIdleWindow(
        restartAfter: TimeInterval?,
        emit: @Sendable (IdleEvent) -> Void
    ) async throws {
        // We can't reuse send() — IDLE doesn't return a tagged completion
        // until the client sends DONE. Talk to the wire directly for it.
        let tag = nextTag()
        try await wire.sendRawCommand("\(tag) IDLE\r\n")
        // Wait for the "+ idling" continuation.
        let ack = try await wire.readUntaggedOrContinuation()
        guard ack.hasPrefix("+") else {
            throw IMAPError.protocolError("expected + idling, got \(ack)")
        }

        // Terminator task: sleeps until the window closes, then fires
        // DONE. If the surrounding Task gets cancelled, `try? await
        // Task.sleep` returns immediately and we still send DONE so the
        // server-side IDLE state isn't orphaned.
        let wireRef = wire
        let terminator: Task<Void, Never>? = restartAfter.map { interval in
            Task {
                let ns = UInt64(max(interval, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                try? await wireRef.sendRawCommand("DONE\r\n")
            }
        }
        defer { terminator?.cancel() }

        while true {
            let line = try await wire.readUntaggedOrContinuation()
            if line.hasPrefix("\(tag) ") {
                // Server acknowledged DONE — this IDLE window is over.
                return
            }
            if line.hasPrefix("*") {
                let body = line.dropFirst(2)
                if body.hasSuffix(" EXISTS"),
                   let n = Int(body.dropLast(" EXISTS".count)) {
                    emit(.exists(n))
                } else if body.hasSuffix(" EXPUNGE"),
                          let n = Int(body.dropLast(" EXPUNGE".count)) {
                    emit(.expunge(n))
                } else {
                    emit(.heartbeat(String(body)))
                }
            }
            // For the bounded-window case the terminator drives DONE.
            // For the open-ended `idle()` case, surface caller
            // cancellation here so the wire doesn't read forever after
            // the consumer goes away.
            if restartAfter == nil, Task.isCancelled {
                try await wire.sendRawCommand("DONE\r\n")
                _ = try? await wire.readUntilTagged(tag: tag)
                return
            }
        }
    }

    // MARK: - Helpers

    private func nextTag() -> String {
        nextTagCounter += 1
        return "A\(String(format: "%04d", nextTagCounter))"
    }

    private func quoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func parseListLine(_ s: String) -> IMAPFolder? {
        // * LIST (\HasNoChildren) "." "INBOX"
        guard let firstParen = s.firstIndex(of: "("),
              let endParen = s[firstParen...].firstIndex(of: ")") else {
            return nil
        }
        let attrs = s[s.index(after: firstParen)..<endParen]
            .split(separator: " ")
            .map { String($0) }
        // Folder name is the last quoted string on the line.
        guard let lastQuote = s.lastIndex(of: "\"") else { return nil }
        let before = s[..<lastQuote]
        guard let openQuote = before.lastIndex(of: "\"") else { return nil }
        let name = String(s[s.index(after: openQuote)..<lastQuote])
        return IMAPFolder(name: name, attributes: attrs)
    }

    private func parseUIDFromFetchLine(_ s: String) -> Int64? {
        guard let r = s.range(of: "UID ") else { return nil }
        let after = s[r.upperBound...]
        let digits = after.prefix(while: { $0.isNumber })
        return Int64(digits)
    }

    private func parseFlagsFromFetchLine(_ s: String) -> [String] {
        guard let r = s.range(of: "FLAGS (") else { return [] }
        let after = s[r.upperBound...]
        guard let close = after.firstIndex(of: ")") else { return [] }
        return after[after.startIndex..<close]
            .split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }
}
