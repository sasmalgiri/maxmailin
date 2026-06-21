import Foundation

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

/// How SMTP wraps the connection in TLS.
///   - `.implicit` — TLS starts at the TCP layer, before any SMTP I/O.
///     Conventional port is 465 (SMTPS).
///   - `.startTLS`  — Plain-text dial, EHLO, STARTTLS command, then
///     `URLSessionStreamTask.startSecureConnection()` upgrades the
///     *same* socket to TLS per RFC 3207. Conventional port is 587.
///   - `.plaintext` — No TLS. Only for development against a local
///     relay; never for the public internet.
public enum SMTPEncryption: Sendable, Equatable {
    case implicit
    case startTLS
    case plaintext
}

public struct SMTPConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var encryption: SMTPEncryption
    public var username: String
    public var password: String

    /// Designated init.
    public init(host: String, port: UInt16 = 465,
                encryption: SMTPEncryption = .implicit,
                username: String, password: String) {
        self.host = host
        self.port = port
        self.encryption = encryption
        self.username = username
        self.password = password
    }

    /// Backwards-compatible init for callers still passing the
    /// pre-STARTTLS `useTLS: Bool` shape. True → implicit TLS,
    /// false → plaintext. Callers that want STARTTLS must move to
    /// the encryption-aware init.
    public init(host: String, port: UInt16 = 465, useTLS: Bool,
                username: String, password: String) {
        self.init(
            host: host, port: port,
            encryption: useTLS ? .implicit : .plaintext,
            username: username, password: password
        )
    }
}

/// Outbound SMTP client. Built on `URLSessionStreamTask` so we can
/// support both implicit TLS (port 465) and STARTTLS (port 587) on top
/// of one wire layer — `startSecureConnection()` does the mid-stream
/// TLS upgrade on the same underlying socket, which is what RFC 3207
/// requires (close-and-reopen-with-TLS would defeat the security
/// guarantee).
///
/// Streaming discipline: send bodies are written in one shot (typical
/// outbound mail is small kB scale). Multi-GB sends would need a
/// chunked write loop the same as IMAPWire uses.
public actor SMTPClient {

    public let config: SMTPConfig
    private var task: URLSessionStreamTask?
    private var rxBuffer = Data()

    public init(config: SMTPConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        let task = URLSession.shared.streamTask(
            withHostName: config.host, port: Int(config.port)
        )
        task.resume()
        self.task = task

        // Implicit TLS: handshake before any SMTP bytes flow.
        if config.encryption == .implicit {
            task.startSecureConnection()
        }

        // Server greeting: "220 ..."
        let greeting = try await readResponse()
        guard greeting.code == 220 else {
            throw SMTPError.protocolError("greeting was \(greeting.code) \(greeting.message)")
        }
        try await sendCommand("EHLO maxmailin.local", expectCode: 250)

        // STARTTLS upgrade dance (RFC 3207). The post-TLS EHLO is
        // mandatory — server capabilities can differ between
        // pre-encryption and post-encryption sessions.
        if config.encryption == .startTLS {
            try await sendCommand("STARTTLS", expectCode: 220)
            task.startSecureConnection()
            try await sendCommand("EHLO maxmailin.local", expectCode: 250)
        }
    }

    public func disconnect() async {
        _ = try? await sendCommand("QUIT", expectCode: 221)
        task?.closeWrite()
        task?.cancel()
        task = nil
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

    /// SASL XOAUTH2 — Gmail / Microsoft 365 / Yahoo modern auth.
    /// On success the server replies 235 directly. On failure it
    /// replies 334 with a base64 JSON error blob expecting an empty
    /// continuation line, then the tagged failure (typically 535).
    public func authXOAUTH2(accessToken: String) async throws {
        let sasl = XOAUTH2.saslInitialResponse(
            username: config.username, accessToken: accessToken
        )
        try ensureConnected()
        try await writeRaw(Data("AUTH XOAUTH2 \(sasl)\r\n".utf8))
        let resp = try await readResponse()
        switch resp.code {
        case 235:
            return
        case 334:
            // Acknowledge the failure continuation; then the next
            // response will be the real 5xx with the human message.
            try await writeRaw(Data("\r\n".utf8))
            let final = try await readResponse()
            throw SMTPError.authFailed("\(final.code) \(final.message)")
        default:
            throw SMTPError.authFailed("\(resp.code) \(resp.message)")
        }
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

    public struct OutboundMessage: Sendable, Codable, Equatable {
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
        guard let task = task else { throw SMTPError.notConnected }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: 30) {
                data, _, error in
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
        guard let task = task else { throw SMTPError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: 30) { error in
                if let error {
                    cont.resume(throwing: SMTPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func ensureConnected() throws {
        guard task != nil else { throw SMTPError.notConnected }
    }
}
