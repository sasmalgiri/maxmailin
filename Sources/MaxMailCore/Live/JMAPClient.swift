import Foundation

// MARK: - Errors

public enum JMAPError: Error, LocalizedError, Sendable {
    case notConnected
    case http(Int, String)
    case invalidResponse(String)
    case methodError(String)
    case missingAuth

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "JMAP session not established. Call discover() first."
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .invalidResponse(let msg): return "Invalid JMAP response: \(msg)"
        case .methodError(let msg): return "JMAP method error: \(msg)"
        case .missingAuth: return "JMAP client has no credentials configured."
        }
    }
}

// MARK: - Session types

/// Minimal slice of the RFC 8620 session resource. We carry only the fields
/// we currently consume — accountId lookup, request endpoint, download URL
/// template. The full response is also kept in `raw` so callers can inspect
/// capabilities they need without us having to model every field upfront.
public struct JMAPSession: @unchecked Sendable {
    public let username: String
    public let apiUrl: URL
    public let downloadUrl: String   // template: contains {accountId}/{blobId}/{type}/{name}
    public let uploadUrl: String
    public let eventSourceUrl: String?
    /// Map of accountId → account metadata.
    public let accounts: [String: JMAPAccount]
    /// Map of capability URN → primary accountId for that capability.
    public let primaryAccounts: [String: String]
    public let state: String?
    public let raw: [String: Any]

    /// Convenience: the accountId that handles `urn:ietf:params:jmap:mail`.
    public var primaryMailAccountID: String? {
        primaryAccounts["urn:ietf:params:jmap:mail"]
    }
}

public struct JMAPAccount: Sendable {
    public let name: String
    public let isPersonal: Bool
    public let isReadOnly: Bool
}

// MARK: - Configuration

public struct JMAPConfig: Sendable {
    public enum Credential: Sendable {
        case bearer(String)
        case basic(username: String, password: String)
    }

    public var sessionURL: URL
    public var credential: Credential

    public init(sessionURL: URL, credential: Credential) {
        self.sessionURL = sessionURL
        self.credential = credential
    }
}

// MARK: - Client

/// Async JMAP client. One actor per logical account so writes serialize
/// against the per-server rate budget and the discovered session cache.
/// Network I/O is performed via the injected URLSession, which makes
/// stubbing for tests trivial via a custom URLProtocol.
public actor JMAPClient {
    private let config: JMAPConfig
    private let urlSession: URLSession
    private var session: JMAPSession?

    public init(config: JMAPConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    /// GET the session resource and cache it.
    @discardableResult
    public func discover() async throws -> JMAPSession {
        var req = URLRequest(url: config.sessionURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &req)
        let (data, resp) = try await urlSession.data(for: req)
        try validate(resp, data: data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JMAPError.invalidResponse("session root is not an object")
        }
        guard
            let username = root["username"] as? String,
            let apiURLString = root["apiUrl"] as? String,
            let apiURL = URL(string: apiURLString),
            let downloadUrl = root["downloadUrl"] as? String,
            let uploadUrl = root["uploadUrl"] as? String,
            let accountsRaw = root["accounts"] as? [String: [String: Any]],
            let primaryAccounts = root["primaryAccounts"] as? [String: String]
        else {
            throw JMAPError.invalidResponse("session missing required fields")
        }

        let accounts = accountsRaw.mapValues { dict -> JMAPAccount in
            JMAPAccount(
                name: dict["name"] as? String ?? "",
                isPersonal: dict["isPersonal"] as? Bool ?? false,
                isReadOnly: dict["isReadOnly"] as? Bool ?? false
            )
        }
        let sess = JMAPSession(
            username: username,
            apiUrl: apiURL,
            downloadUrl: downloadUrl,
            uploadUrl: uploadUrl,
            eventSourceUrl: root["eventSourceUrl"] as? String,
            accounts: accounts,
            primaryAccounts: primaryAccounts,
            state: root["state"] as? String,
            raw: root
        )
        self.session = sess
        return sess
    }

    /// Returns the cached session, discovering if needed.
    public func currentSession() async throws -> JMAPSession {
        if let session { return session }
        return try await discover()
    }

    /// Send one or more method calls. Returns the full response object so the
    /// caller can pull both `methodResponses` and `sessionState`. Each method
    /// call is `[methodName, argsDict, callId]`.
    public func invoke(
        using capabilities: [String] = [
            "urn:ietf:params:jmap:core",
            "urn:ietf:params:jmap:mail"
        ],
        methodCalls: [[Any]]
    ) async throws -> JMAPInvocationResult {
        let sess = try await currentSession()
        var req = URLRequest(url: sess.apiUrl)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &req)
        let body: [String: Any] = [
            "using": capabilities,
            "methodCalls": methodCalls
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, resp) = try await urlSession.data(for: req)
        try validate(resp, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JMAPError.invalidResponse("response root is not an object")
        }
        guard let methodResponses = json["methodResponses"] as? [[Any]] else {
            throw JMAPError.invalidResponse("missing methodResponses")
        }
        return JMAPInvocationResult(
            methodResponses: methodResponses,
            sessionState: json["sessionState"] as? String,
            raw: json
        )
    }

    /// Download blob bytes from the session's downloadUrl template.
    /// Performs `{accountId}` / `{blobId}` / `{type}` / `{name}` substitution
    /// per RFC 8620 §6.2 and issues an authenticated GET.
    public func downloadBlob(
        accountID: String,
        blobID: String,
        mimeType: String,
        filename: String
    ) async throws -> Data {
        let sess = try await currentSession()
        let template = sess.downloadUrl
        let url = template
            .replacingOccurrences(of: "{accountId}", with: percentEscape(accountID))
            .replacingOccurrences(of: "{blobId}",    with: percentEscape(blobID))
            .replacingOccurrences(of: "{type}",      with: percentEscape(mimeType))
            .replacingOccurrences(of: "{name}",      with: percentEscape(filename))
        guard let u = URL(string: url) else {
            throw JMAPError.invalidResponse("malformed downloadUrl: \(url)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        applyAuth(to: &req)
        let (data, resp) = try await urlSession.data(for: req)
        try validate(resp, data: data)
        return data
    }

    // MARK: - Helpers

    private func percentEscape(_ s: String) -> String {
        // RFC 8620 implementations use plain URL-path escaping. Keep the
        // characters allowed in URL paths intact.
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func applyAuth(to req: inout URLRequest) {
        switch config.credential {
        case .bearer(let token):
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .basic(let user, let pass):
            let raw = Data("\(user):\(pass)".utf8).base64EncodedString()
            req.setValue("Basic \(raw)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if (200...299).contains(http.statusCode) { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw JMAPError.http(http.statusCode, body)
    }
}

// MARK: - Invocation result

public struct JMAPInvocationResult: @unchecked Sendable {
    public let methodResponses: [[Any]]
    public let sessionState: String?
    public let raw: [String: Any]

    /// Find the first method response with the given name (and optional callId).
    public func first(method: String, callID: String? = nil) -> [String: Any]? {
        for r in methodResponses {
            guard r.count >= 3,
                  let name = r[0] as? String,
                  let args = r[1] as? [String: Any],
                  let id = r[2] as? String
            else { continue }
            if name != method { continue }
            if let callID, id != callID { continue }
            return args
        }
        return nil
    }
}
