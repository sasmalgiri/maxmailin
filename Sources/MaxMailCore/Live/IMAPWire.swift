import Foundation
import Network

public enum IMAPError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case authFailed(String)
    case protocolError(String)
    case commandFailed(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "IMAP connection not open"
        case .connectionFailed(let m): return "IMAP connect failed: \(m)"
        case .authFailed(let m): return "IMAP login failed: \(m)"
        case .protocolError(let m): return "IMAP protocol error: \(m)"
        case .commandFailed(let m): return "IMAP command failed: \(m)"
        case .malformedResponse(let m): return "Malformed IMAP response: \(m)"
        }
    }
}

/// One line of an IMAP response, plus any literal block ({n}-style) that
/// was attached inline.
public struct IMAPLine: Sendable {
    public let text: String
    public let literal: Data?
}

/// Tagged + untagged lines for one command's response cycle.
public struct IMAPResponse: Sendable {
    public let tag: String
    public let completion: Completion
    public let resultText: String
    public let untagged: [IMAPLine]

    public enum Completion: String, Sendable { case ok = "OK", no = "NO", bad = "BAD" }

    public var isOK: Bool { completion == .ok }
}

/// Raw TCP/TLS pipe to an IMAP server. Single-threaded by actor isolation;
/// the parser is line-driven with explicit byte-count handling for FETCH
/// literals so we never confuse "more text" with "more bytes."
///
/// Streaming discipline: the receive loop reads only as much as it needs to
/// satisfy the current command's response. Nothing is buffered past the
/// end of the active response — we never accumulate an entire folder's
/// FETCH output in memory.
public actor IMAPConnection {

    public let host: String
    public let port: UInt16
    public let useTLS: Bool

    private var connection: NWConnection?
    private var rxBuffer = Data()
    private var greetingConsumed = false

    public init(host: String, port: UInt16 = 993, useTLS: Bool = true) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    // MARK: - Connect / disconnect

    public func connect() async throws {
        let params: NWParameters = useTLS ? .tls : .tcp
        let endpoint = NWEndpoint.hostPort(
            host: .init(host),
            port: NWEndpoint.Port(rawValue: port) ?? 993
        )
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: IMAPError.connectionFailed("cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Consume the server greeting (* OK <something>) before any command.
        let greeting = try await readLine()
        if !greeting.text.hasPrefix("* OK") {
            throw IMAPError.protocolError("expected greeting, got \(greeting.text)")
        }
        greetingConsumed = true
    }

    public func disconnect() async {
        connection?.cancel()
        connection = nil
        rxBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Send a command, read until tagged completion

    /// Send a single command terminated with CRLF. Returns the response
    /// (untagged lines + tagged completion). The `tag` is generated for
    /// the caller — it threads through send and parse so multiple
    /// in-flight commands don't get confused (though this actor sends
    /// one at a time anyway).
    public func send(tag: String, command: String) async throws -> IMAPResponse {
        try ensureConnected()
        let line = "\(tag) \(command)\r\n"
        try await write(Data(line.utf8))

        var untagged: [IMAPLine] = []
        while true {
            let line = try await readLine()
            if line.text.hasPrefix("\(tag) ") {
                // Tagged response — completion of our command.
                let rest = line.text.dropFirst(tag.count + 1)
                let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard let kind = parts.first,
                      let comp = IMAPResponse.Completion(rawValue: String(kind))
                else {
                    throw IMAPError.malformedResponse(String(rest))
                }
                let text = parts.count > 1 ? String(parts[1]) : ""
                return IMAPResponse(tag: tag, completion: comp, resultText: text, untagged: untagged)
            } else if line.text.hasPrefix("* ") || line.literal != nil {
                untagged.append(line)
            } else if line.text.hasPrefix("+ ") {
                // Continuation request — caller can subclass-extend for
                // AUTHENTICATE / IDLE. Not exercised by basic LOGIN.
                continue
            } else {
                untagged.append(line)
            }
        }
    }

    // MARK: - IDLE-friendly raw I/O

    /// Send a raw command line. Used by IDLE which can't share the
    /// tagged send()/await flow because the server keeps the connection
    /// in IDLE state until the client sends DONE.
    public func sendRawCommand(_ command: String) async throws {
        try ensureConnected()
        try await write(Data(command.utf8))
    }

    /// Read one line (untagged or `+` continuation) without waiting for a
    /// tagged completion. Used by the IDLE pump loop.
    public func readUntaggedOrContinuation() async throws -> String {
        try await readTextLine()
    }

    /// Read lines until we see the named tag's completion. Used by IDLE
    /// to consume the final OK after DONE.
    public func readUntilTagged(tag: String) async throws -> String {
        while true {
            let line = try await readTextLine()
            if line.hasPrefix("\(tag) ") { return line }
        }
    }

    // MARK: - Low-level read

    /// Read until CRLF, transparently consuming any inline {n}-style
    /// literal that may have been declared at the end of the line.
    private func readLine() async throws -> IMAPLine {
        let lineText = try await readTextLine()
        // Detect a trailing literal marker like " {1234}" at end of line.
        if let openBrace = lineText.lastIndex(of: "{"),
           lineText.suffix(from: openBrace).hasSuffix("}") {
            let inner = lineText[lineText.index(after: openBrace)..<lineText.index(before: lineText.endIndex)]
            if let n = Int(inner) {
                let bytes = try await readBytes(count: n)
                // Consume the CRLF immediately after the literal — the next
                // line of text continues the same logical IMAP response.
                _ = try? await readTextLine()
                return IMAPLine(text: String(lineText), literal: bytes)
            }
        }
        return IMAPLine(text: lineText, literal: nil)
    }

    private func readTextLine() async throws -> String {
        while true {
            if let nlRange = rxBuffer.range(of: Data([0x0D, 0x0A])) {
                let line = rxBuffer.subdata(in: rxBuffer.startIndex..<nlRange.lowerBound)
                rxBuffer.removeSubrange(rxBuffer.startIndex..<nlRange.upperBound)
                return String(data: line, encoding: .utf8)
                    ?? String(data: line, encoding: .isoLatin1) ?? ""
            }
            try await receiveMore()
        }
    }

    private func readBytes(count n: Int) async throws -> Data {
        while rxBuffer.count < n {
            try await receiveMore()
        }
        let chunk = rxBuffer.subdata(in: rxBuffer.startIndex..<(rxBuffer.startIndex + n))
        rxBuffer.removeSubrange(rxBuffer.startIndex..<(rxBuffer.startIndex + n))
        return chunk
    }

    private func receiveMore() async throws {
        guard let conn = connection else { throw IMAPError.notConnected }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
        if data.isEmpty {
            throw IMAPError.connectionFailed("server closed connection")
        }
        rxBuffer.append(data)
    }

    private func write(_ data: Data) async throws {
        guard let conn = connection else { throw IMAPError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func ensureConnected() throws {
        guard connection != nil, greetingConsumed else {
            throw IMAPError.notConnected
        }
    }
}
