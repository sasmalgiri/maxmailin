import XCTest
@testable import MaxMailCore

final class JMAPTests: XCTestCase {

    // MARK: - Stub URL protocol

    /// Stubs requests for a custom URLSession. Two routes: GET → session
    /// JSON, POST → method-call JSON. Captures the last POST body so tests
    /// can assert what the client actually sent.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var sessionJSON: Data = Data()
        nonisolated(unsafe) static var postJSON: Data = Data()
        nonisolated(unsafe) static var lastPostBody: Data?
        nonisolated(unsafe) static var lastPostHeaders: [String: String] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url ?? URL(string: "stub://nowhere")!
            let method = request.httpMethod ?? "GET"
            let body: Data
            if method == "POST" {
                Self.lastPostBody = request.bodySteamReadAllData() ?? request.httpBody
                Self.lastPostHeaders = request.allHTTPHeaderFields ?? [:]
                body = Self.postJSON
            } else {
                body = Self.sessionJSON
            }
            let resp = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> JMAPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let cfg = JMAPConfig(
            sessionURL: URL(string: "https://example.com/.well-known/jmap")!,
            credential: .bearer("fake-token")
        )
        return JMAPClient(config: cfg, urlSession: session)
    }

    // MARK: - Discovery

    func testDiscoverParsesSession() async throws {
        StubProtocol.sessionJSON = Data("""
        {
          "username": "alice@example.com",
          "apiUrl": "https://example.com/jmap/api/",
          "downloadUrl": "https://example.com/jmap/download/{accountId}/{blobId}",
          "uploadUrl": "https://example.com/jmap/upload/{accountId}/",
          "eventSourceUrl": "https://example.com/jmap/events/",
          "accounts": {
            "A1": { "name": "Alice", "isPersonal": true, "isReadOnly": false }
          },
          "primaryAccounts": {
            "urn:ietf:params:jmap:mail": "A1"
          },
          "state": "S1"
        }
        """.utf8)

        let client = makeClient()
        let session = try await client.discover()
        XCTAssertEqual(session.username, "alice@example.com")
        XCTAssertEqual(session.apiUrl.absoluteString, "https://example.com/jmap/api/")
        XCTAssertEqual(session.primaryMailAccountID, "A1")
        XCTAssertEqual(session.accounts["A1"]?.name, "Alice")
    }

    func testInvokeSendsAuthAndUsing() async throws {
        StubProtocol.sessionJSON = Data("""
        {
          "username": "a@x", "apiUrl": "https://x.example/api/",
          "downloadUrl": "https://x.example/dl",
          "uploadUrl": "https://x.example/up",
          "accounts": { "A1": {"name":"a","isPersonal":true,"isReadOnly":false} },
          "primaryAccounts": {"urn:ietf:params:jmap:mail":"A1"}
        }
        """.utf8)
        StubProtocol.postJSON = Data("""
        {
          "methodResponses": [["Mailbox/get", {"list": []}, "0"]],
          "sessionState": "S2"
        }
        """.utf8)

        let client = makeClient()
        _ = try await client.discover()
        _ = try await client.invoke(methodCalls: [["Mailbox/get", ["accountId":"A1"], "0"]])
        XCTAssertEqual(StubProtocol.lastPostHeaders["Authorization"], "Bearer fake-token")
        guard let body = StubProtocol.lastPostBody,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { XCTFail("missing POST body"); return }
        let using = obj["using"] as? [String]
        XCTAssertTrue(using?.contains("urn:ietf:params:jmap:mail") == true)
    }

    // MARK: - Mailbox listing

    func testListMailboxes() async throws {
        StubProtocol.sessionJSON = sessionFixture
        StubProtocol.postJSON = Data("""
        {
          "methodResponses": [["Mailbox/get", {
            "list": [
              {"id":"M1","name":"Inbox","role":"inbox","totalEmails":120,"unreadEmails":3},
              {"id":"M2","name":"Sent","role":"sent","totalEmails":40,"unreadEmails":0},
              {"id":"M3","name":"Old projects","role":null,"totalEmails":12,"unreadEmails":0}
            ]
          }, "0"]],
          "sessionState": "S"
        }
        """.utf8)

        let client = makeClient()
        _ = try await client.discover()

        let dbDir = tempDir()
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let accID = try await store.upsertAccount(name: "JMAP", address: "a@x", kind: "jmap")
        let sync = JMAPSync(client: client, store: store, localAccountID: accID)

        let boxes = try await sync.listMailboxes()
        XCTAssertEqual(boxes.count, 3)
        XCTAssertEqual(boxes.first?.name, "Inbox")
        XCTAssertEqual(boxes.first?.role, "inbox")
        XCTAssertEqual(boxes.first?.totalEmails, 120)
    }

    // MARK: - End-to-end pull

    func testPullRecentIngestsIntoMailStore() async throws {
        StubProtocol.sessionJSON = sessionFixture
        StubProtocol.postJSON = Data("""
        {
          "methodResponses": [
            ["Email/query", {"ids":["E1","E2"], "accountId":"A1"}, "q"],
            ["Email/get", {"list":[
              {
                "id": "E1",
                "messageId": ["m1@x"],
                "subject": "Project update",
                "from": [{"name":"Alice","email":"alice@example.com"}],
                "to":   [{"name":"Bob","email":"bob@example.com"}],
                "receivedAt": "2026-04-01T12:00:00Z",
                "size": 1280,
                "keywords": {"$seen": true},
                "hasAttachment": false,
                "textBody": [{"partId":"P1","type":"text/plain"}],
                "htmlBody": [],
                "bodyValues": {"P1": {"value":"Body of the project update email."}}
              },
              {
                "id": "E2",
                "messageId": ["m2@x"],
                "subject": "Lunch?",
                "from": [{"name":"Carol","email":"carol@example.com"}],
                "to": [{"name":"Alice","email":"alice@example.com"}],
                "receivedAt": "2026-04-02T15:30:00.123Z",
                "size": 540,
                "keywords": {},
                "hasAttachment": false,
                "textBody": [{"partId":"P1"}],
                "htmlBody": [],
                "bodyValues": {"P1": {"value":"Want pizza?"}}
              }
            ]}, "g"]
          ],
          "sessionState": "S2"
        }
        """.utf8)

        let dbDir = tempDir()
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let accID = try await store.upsertAccount(name: "JMAP", address: "a@x", kind: "jmap")
        let client = makeClient()
        _ = try await client.discover()
        let sync = JMAPSync(client: client, store: store, localAccountID: accID)

        let (n, skipped) = try await sync.pullRecent(
            mailbox: JMAPMailbox(id: "M1", name: "Inbox", role: "inbox",
                                 totalEmails: 2, unreadEmails: 1),
            folderName: "INBOX",
            limit: 50
        )
        XCTAssertEqual(n, 2)
        XCTAssertEqual(skipped, 0)

        let headers = try await store.headers(in: "INBOX", accountID: accID, limit: 10)
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(headers.first?.subject, "Lunch?", "newest first")
        XCTAssertEqual(headers.first?.fromAddress, "carol@example.com")

        // Search hits both (Body / Lunch).
        let hits = try await store.search("project", limit: 10)
        XCTAssertEqual(hits.first?.subject, "Project update")

        // Re-pull is a no-op (idempotent).
        StubProtocol.postJSON = StubProtocol.postJSON  // reuse same fixture
        let (n2, skipped2) = try await sync.pullRecent(
            mailbox: JMAPMailbox(id: "M1", name: "Inbox", role: "inbox",
                                 totalEmails: 2, unreadEmails: 1),
            folderName: "INBOX"
        )
        XCTAssertEqual(n2, 0)
        XCTAssertEqual(skipped2, 2)
    }

    // MARK: - Fixtures

    private let sessionFixture: Data = Data("""
    {
      "username": "a@x", "apiUrl": "https://x.example/api/",
      "downloadUrl": "https://x.example/dl/{accountId}/{blobId}",
      "uploadUrl": "https://x.example/up/{accountId}/",
      "accounts": { "A1": {"name":"a","isPersonal":true,"isReadOnly":false} },
      "primaryAccounts": {"urn:ietf:params:jmap:mail":"A1"}
    }
    """.utf8)

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jmap-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Helper to read POST bodies via URLRequest

private extension URLRequest {
    /// URLRequest's httpBody is nil when the body was uploaded via a stream;
    /// `httpBodyStream` carries the bytes in that case. We need this because
    /// URLSession often promotes JSON bodies to streams under the hood.
    func bodySteamReadAllData() -> Data? {
        guard let stream = self.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
