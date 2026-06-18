import Foundation
import Network

public enum SMTPError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case authFailed(String)
    case protocolError(String)
    case commandFailed(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "SMTP connection not open"
        case .connectionFailed(let m): return "SMTP connect failed: \(m)"
        case .authFailed(let m): return "SMTP auth failed: \(m)"
        case .protocolError(let m): return "SMTP protocol error: \(m)"
        case .commandFailed(let c, let m): return "SMTP error \(c): \(m)"
        }
    }
}

public struct SMTPConfig: Sendable {
    public var host: String
    public var port: UInt16        // 465 implicit TLS recommended
    public var useTLS: Bool
    public var username: String
    public var password: String

    public init(host: String, port: UInt16 = 465, useTLS: Bool = true,
                username: String, password: String) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.password = password
    }
}

/// Outbound SMTP client. Implicit TLS (port 465 / SMTPS) for first cut —
/// no STARTTLS upgrade dance. Most modern servers (Gmail / iCloud /
/// Outlook / Fastmail / Stalwart) support 465.
///
/// Streaming discipline: send bodies are written in one shot (typical
/// outbound mail is small kB scale). If we ever need to stream a multi-GB
/// attachment, the same chunked-write pattern from IMAPWire applies.
public actor SMTPClient {

    public let config: SMTPConfig
    private var connection: NWConnection?
    private var rxBuffer = Data()

    public init(config: SMTPConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        let params: NWParameters = config.useTLS ? .tls : .tcp
        let endpoint = NWEndpoint.hostPort(
            host: .init(config.host),
            port: NWEndpoint.Port(rawValue: config.port) ?? 465
        )
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume()
                case .failed(let e): resumed = true
                    cont.resume(throwing: SMTPError.connectionFailed(e.localizedDescription))
                case .cancelled: resumed = true
                    cont.resume(throwing: SMTPError.connectionFailed("cancelled"))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }

        // Server greeting: "220 ..."
        let greeting = try await readResponse()
        guard greeting.code == 220 else {
            throw SMTPError.protocolError("greeting was \(greeting.code) \(greeting.message)")
        }
        // EHLO to enter ESMTP mode.
        try await sendCommand("EHLO maxmailin.local", expectCode: 250)
    }

    public func disconnect() async {
        _ = try? await sendCommand("QUIT", expectCode: 221)
        connection?.cancel()
        connection = nil
        rxBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - AUTH

    /// AUTH LOGIN — wider compatibility than AUTH PLAIN. Username and
    /// password are base64-encoded line-at-a-time per RFC 4954.
    public func authLogin() async throws {
        let resp1 = try await sendCommand("AUTH LOGIN", expectCode: 334)
        _ = resp1
        try await sendBase64Line(config.username, expectCode: 334)
        try await sendBase64Line(config.password, expectCode: 235)
    }

    private func sendBase64Line(_ s: String, expectCode: Int) async throws {
        let encoded = Data(s.utf8).base64EncodedString()
        try await sendCommand(encoded, expectCode: expectCode)
    }

    // MARK: - Send

    public struct Recipient: Sendable {
        public let address: String
        public init(_ address: String) { self.address = address }
    }

    public struct OutboundMessage: Sendable {
        public let from: String
        public let to: [String]
        public let cc: [String]
        public let bcc: [String]
        public let subject: String
        public let plainBody: String
        public let messageID: String     // "<unique@host>"
        public let inReplyTo: String?
        public let references: [String]

        public init(from: String, to: [String], cc: [String] = [], bcc: [String] = [],
                    subject: String, plainBody: String, messageID: String,
                    inReplyTo: String? = nil, references: [String] = []) {
            self.from = from; self.to = to; self.cc = cc; self.bcc = bcc
            self.subject = subject; self.plainBody = plainBody
            self.messageID = messageID
            self.inReplyTo = inReplyTo; self.references = references
        }
    }

    /// MAIL FROM / RCPT TO (×N) / DATA / body / "." / 250 OK.
    /// Returns the server's queued-id text from the final 250 response.
    public func send(_ msg: OutboundMessage) async throws -> String {
        try await sendCommand("MAIL FROM:<\(msg.from)>", expectCode: 250)
        let allRecipients = msg.to + msg.cc + msg.bcc
        for rcpt in allRecipients {
            try await sendCommand("RCPT TO:<\(rcpt)>", expectCode: 250)
        }
        let dataResp = try await sendCommand("DATA", expectCode: 354)
        _ = dataResp

        let body = Self.encode(msg)
        try await writeRaw(body)
        // Terminator: CRLF.CRLF
        try await writeRaw(Data("\r\n.\r\n".utf8))
        let queued = try await readResponse()
        guard queued.code == 250 else {
            throw SMTPError.commandFailed(code: queued.code, message: queued.message)
        }
        return queued.message
    }

    /// Build a minimal RFC 5322 + MIME plain-text message with proper
    /// dot-stuffing (any body line starting with "." gets an extra "."
    /// prefix so it doesn't terminate the DATA payload).
    static func encode(_ msg: OutboundMessage) -> Data {
        var lines: [String] = []
        lines.append("From: \(msg.from)")
        lines.append("To: \(msg.to.joined(separator: ", "))")
        if !msg.cc.isEmpty { lines.append("Cc: \(msg.cc.joined(separator: ", "))") }
        lines.append("Subject: \(msg.subject)")
        lines.append("Message-ID: \(msg.messageID)")
        if let irt = msg.inReplyTo { lines.append("In-Reply-To: \(irt)") }
        if !msg.references.isEmpty {
            lines.append("References: \(msg.references.joined(separator: " "))")
        }
        lines.append("Date: \(rfc5322Now())")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("")   // blank line ends headers

        // Dot-stuff the body.
        for line in msg.plainBody.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(".") {
                lines.append("." + line)
            } else {
                lines.append(String(line))
            }
        }
        // Join with CRLF (RFC 5321 line terminator).
        let joined = lines.joined(separator: "\r\n")
        return Data(joined.utf8)
    }

    private static func rfc5322Now() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        return f.string(from: Date())
    }

    // MARK: - Wire

    private struct SMTPResponse {
        let code: Int
        let message: String
    }

    @discardableResult
    private func sendCommand(_ line: String, expectCode: Int) async throws -> SMTPResponse {
        try ensureConnected()
        try await writeRaw(Data((line + "\r\n").utf8))
        let resp = try await readResponse()
        guard resp.code == expectCode else {
            // SMTP soft-fails like 535 (auth) carry meaningful messages.
            if (400...599).contains(resp.code) {
                throw SMTPError.commandFailed(code: resp.code, message: resp.message)
            }
            throw SMTPError.protocolError(
                "expected \(expectCode), got \(resp.code) \(resp.message)")
        }
        return resp
    }

    /// Read one full SMTP response — multi-line responses use a hyphen
    /// after the code on every line except the last (e.g.
    /// "250-PIPELINING" / "250 OK").
    private func readResponse() async throws -> SMTPResponse {
        var collected = ""
        var lastCode = 0
        while true {
            let line = try await readLine()
            // Lines look like "<code><sep><text>" where sep is '-' or ' '.
            guard line.count >= 4 else {
                throw SMTPError.protocolError("short response: \(line)")
            }
            let codeStr = String(line.prefix(3))
            guard let code = Int(codeStr) else {
                throw SMTPError.protocolError("non-numeric code in \(line)")
            }
            let sep = line[line.index(line.startIndex, offsetBy: 3)]
            let text = String(line.dropFirst(4))
            if !collected.isEmpty { collected += "\n" }
            collected += text
            lastCode = code
            if sep == " " { return SMTPResponse(code: lastCode, message: collected) }
            // sep == "-" means continuation; loop.
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let nl = rxBuffer.range(of: Data([0x0D, 0x0A])) {
                let line = rxBuffer.subdata(in: rxBuffer.startIndex..<nl.lowerBound)
                rxBuffer.removeSubrange(rxBuffer.startIndex..<nl.upperBound)
                return String(data: line, encoding: .utf8)
                    ?? String(data: line, encoding: .isoLatin1) ?? ""
            }
            try await receiveMore()
        }
    }

    private func receiveMore() async throws {
        guard let conn = connection else { throw SMTPError.notConnected }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    cont.resume(throwing: SMTPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: data ?? Data())
                }
            }
        }
        if data.isEmpty {
            throw SMTPError.connectionFailed("server closed connection")
        }
        rxBuffer.append(data)
    }

    private func writeRaw(_ data: Data) async throws {
        guard let conn = connection else { throw SMTPError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: SMTPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func ensureConnected() throws {
        guard connection != nil else { throw SMTPError.notConnected }
    }
}
