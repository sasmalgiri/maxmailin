import XCTest
@testable import MaxMailCore

final class JMAPTests: XCTestCase {

    // MARK: - Stub URL protocol

    /// Stubs requests for a custom URLSession. Two routes: GET → session
    /// JSON, POST → method-call JSON. Captures the last POST body so tests
    /// can assert what the client actually sent.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var sessionJSON: Data = Data()
        /// Fallback POST body — used when the queue is empty.
        nonisolated(unsafe) static var postJSON: Data = Data()
        /// Queue of POST responses consumed in order. Each test that issues
        /// multiple POSTs in sequence (e.g., listMailboxes + Identity/get +
        /// send) enqueues one Data per expected POST.
        nonisolated(unsafe) static var postQueue: [Data] = []
        nonisolated(unsafe) static var lastPostBody: Data?
        nonisolated(unsafe) static var lastPostHeaders: [String: String] = [:]

        static func reset() {
            sessionJSON = Data()
            postJSON = Data()
            postQueue = []
            lastPostBody = nil
            lastPostHeaders = [:]
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url ?? URL(string: "stub://nowhere")!
            let method = request.httpMethod ?? "GET"
            let body: Data
            if method == "POST" {
                Self.lastPostBody = request.bodySteamReadAllData() ?? request.httpBody
                Self.lastPostHeaders = request.allHTTPHeaderFields ?? [:]
                if !Self.postQueue.isEmpty {
                    body = Self.postQueue.removeFirst()
                } else {
                    body = Self.postJSON
                }
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

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
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

    // MARK: - Incremental sync via Email/changes

    func testSyncIncrementalAppliesAddsUpdatesAndDeletes() async throws {
        StubProtocol.sessionJSON = sessionFixture
        // First call: pullRecent seeds two messages + state token "S1".
        StubProtocol.postJSON = Data("""
        {
          "methodResponses": [
            ["Email/query", {"ids":["E1","E2"], "accountId":"A1"}, "q"],
            ["Email/get", {"state":"S1","list":[
              {"id":"E1","messageId":["m1@x"],"subject":"First",
               "from":[{"email":"a@x"}],"to":[{"email":"b@x"}],
               "receivedAt":"2026-04-01T12:00:00Z","size":100,
               "keywords":{},"hasAttachment":false,
               "textBody":[{"partId":"P1"}],"htmlBody":[],
               "bodyValues":{"P1":{"value":"first body"}}},
              {"id":"E2","messageId":["m2@x"],"subject":"Second",
               "from":[{"email":"c@x"}],"to":[{"email":"d@x"}],
               "receivedAt":"2026-04-02T12:00:00Z","size":100,
               "keywords":{},"hasAttachment":false,
               "textBody":[{"partId":"P1"}],"htmlBody":[],
               "bodyValues":{"P1":{"value":"second body"}}}
            ]}, "g"]
          ],
          "sessionState":"S0"
        }
        """.utf8)

        let dbDir = tempDir()
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let accID = try await store.upsertAccount(name: "JMAP", address: "a@x", kind: "jmap")
        let client = makeClient()
        _ = try await client.discover()
        let sync = JMAPSync(client: client, store: store, localAccountID: accID)

        let mailbox = JMAPMailbox(id: "M1", name: "Inbox", role: "inbox",
                                  totalEmails: 2, unreadEmails: 0)
        let (added, _) = try await sync.pullRecent(mailbox: mailbox, folderName: "INBOX")
        XCTAssertEqual(added, 2)
        let seeded = try await store.syncState(accountID: accID, scope: "email:A1")
        XCTAssertEqual(seeded, "S1")

        // Capture the row IDs while they still exist for later assertions.
        let e1Local = try await store.localRowID(forJMAPEmailID: "E1")
        let e2Local = try await store.localRowID(forJMAPEmailID: "E2")
        XCTAssertNotNil(e1Local)
        XCTAssertNotNil(e2Local)

        // Second call: Email/changes returns one create (E3), one update
        // (E1 now $seen), one destroy (E2). Email/get returns details.
        StubProtocol.postJSON = Data("""
        {
          "methodResponses": [
            ["Email/changes", {
              "accountId":"A1",
              "oldState":"S1","newState":"S2",
              "hasMoreChanges": false,
              "created":["E3"],
              "updated":["E1"],
              "destroyed":["E2"]
            }, "c"],
            ["Email/get", {"state":"S2","list":[
              {"id":"E3","messageId":["m3@x"],"subject":"Third",
               "from":[{"email":"e@x"}],"to":[{"email":"f@x"}],
               "receivedAt":"2026-04-03T12:00:00Z","size":100,
               "keywords":{"$flagged":true},"hasAttachment":false,
               "textBody":[{"partId":"P1"}],"htmlBody":[],
               "bodyValues":{"P1":{"value":"third body"}}}
            ]}, "gnew"],
            ["Email/get", {"state":"S2","list":[
              {"id":"E1","keywords":{"$seen":true}}
            ]}, "gupd"]
          ],
          "sessionState":"S2"
        }
        """.utf8)

        let result = try await sync.syncIncremental(mailboxHint: mailbox, folderName: "INBOX")
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.removed, 1)

        // E2 should be gone.
        let e2After = try await store.localRowID(forJMAPEmailID: "E2")
        XCTAssertNil(e2After)
        // E1's flags should now include .seen.
        let e1Flags = try await store.messageFlags(messageRowID: e1Local!)
        XCTAssertTrue(e1Flags?.contains(.seen) == true)
        // E3 should now exist + be linked.
        let e3Local = try await store.localRowID(forJMAPEmailID: "E3")
        XCTAssertNotNil(e3Local)
        // Sync state should advance.
        let advanced = try await store.syncState(accountID: accID, scope: "email:A1")
        XCTAssertEqual(advanced, "S2")
    }

    // MARK: - Flag writes

    func testSetSeenSendsEmailSetAndUpdatesLocalFlags() async throws {
        StubProtocol.sessionJSON = sessionFixture
        StubProtocol.postJSON = Data("""
        {
          "methodResponses": [
            ["Email/query", {"ids":["E1"], "accountId":"A1"}, "q"],
            ["Email/get", {"state":"S1","list":[
              {"id":"E1","messageId":["m1@x"],"subject":"Only",
               "from":[{"email":"a@x"}],"to":[{"email":"b@x"}],
               "receivedAt":"2026-04-01T12:00:00Z","size":100,
               "keywords":{},"hasAttachment":false,
               "textBody":[{"partId":"P1"}],"htmlBody":[],
               "bodyValues":{"P1":{"value":"body"}}}
            ]}, "g"]
          ]
        }
        """.utf8)

        let dbDir = tempDir()
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let accID = try await store.upsertAccount(name: "JMAP", address: "a@x", kind: "jmap")
        let client = makeClient()
        _ = try await client.discover()
        let sync = JMAPSync(client: client, store: store, localAccountID: accID)
        _ = try await sync.pullRecent(
            mailbox: JMAPMailbox(id: "M1", name: "Inbox", role: "inbox",
                                 totalEmails: 1, unreadEmails: 1),
            folderName: "INBOX"
        )
        let local = try await store.localRowID(forJMAPEmailID: "E1")!

        // Server confirms the update.
        StubProtocol.postJSON = Data("""
        {
          "methodResponses": [
            ["Email/set", {"accountId":"A1","updated":{"E1":null}}, "u"]
          ]
        }
        """.utf8)

        try await sync.setSeen(localRowID: local, true)

        // Verify the body we sent really was a keywords/$seen=true update.
        guard let body = StubProtocol.lastPostBody,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let calls = obj["methodCalls"] as? [[Any]] else {
            XCTFail("missing or malformed POST"); return
        }
        XCTAssertEqual(calls.first?[0] as? String, "Email/set")
        let args = calls.first?[1] as? [String: Any]
        let update = args?["update"] as? [String: [String: Any]]
        let perEmail = update?["E1"]
        XCTAssertEqual(perEmail?["keywords/$seen"] as? Bool, true)

        // Local flags reflect the new state.
        let flags = try await store.messageFlags(messageRowID: local)
        XCTAssertTrue(flags?.contains(.seen) == true)
    }

    // MARK: - Send (Email/set + EmailSubmission/set)

    func testSendPlainEmailIssuesCorrectMethodCalls() async throws {
        StubProtocol.sessionJSON = sessionFixture
        // sendPlainEmail makes three POSTs in sequence:
        //   1. Mailbox/get          — find Drafts
        //   2. Identity/get         — find first identity
        //   3. Email/set + EmailSubmission/set — create draft and submit
        StubProtocol.postQueue = [
            Data("""
            {"methodResponses":[["Mailbox/get",{"list":[
              {"id":"M_DRAFT","name":"Drafts","role":"drafts","totalEmails":0,"unreadEmails":0}
            ]}, "0"]]}
            """.utf8),
            Data("""
            {"methodResponses":[["Identity/get",
              {"list":[{"id":"ID1","email":"alice@example.com"}]}, "i"]]}
            """.utf8),
            Data("""
            {"methodResponses":[
              ["Email/set", {"accountId":"A1","created":{"draft":{"id":"E_NEW"}}}, "draft"],
              ["EmailSubmission/set", {"accountId":"A1","created":{"sub":{"id":"SUB1"}}}, "submit"]
            ]}
            """.utf8)
        ]

        let dbDir = tempDir()
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let accID = try await store.upsertAccount(name: "JMAP", address: "a@x", kind: "jmap")
        let client = makeClient()
        _ = try await client.discover()
        let sync = JMAPSync(client: client, store: store, localAccountID: accID)

        let emailID = try await sync.sendPlainEmail(
            from: "alice@example.com",
            to: ["bob@example.com"],
            subject: "Hello",
            body: "This is the body."
        )
        XCTAssertEqual(emailID, "E_NEW")

        // Last POST is the send round-trip — verify the using[] includes the
        // submission capability so the server actually accepts the call.
        guard let body = StubProtocol.lastPostBody,
              let obj  = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let using = obj["using"] as? [String],
              let calls = obj["methodCalls"] as? [[Any]] else {
            XCTFail("missing POST"); return
        }
        XCTAssertTrue(using.contains("urn:ietf:params:jmap:submission"))
        let methodNames = calls.compactMap { $0.first as? String }
        XCTAssertEqual(methodNames, ["Email/set", "EmailSubmission/set"])
    }

    // MARK: - Attachment download

    func testDownloadAttachmentFetchesBlobAndPatchesRow() async throws {
        // Override the stub for this test to also handle GET requests:
        // any non-POST will be answered with the configured attachment bytes
        // so the download path is exercised end-to-end.
        StubProtocol.sessionJSON = Data("""
        {
          "username":"a@x","apiUrl":"https://x.example/api/",
          "downloadUrl":"https://x.example/dl/{accountId}/{blobId}/{type}/{name}",
          "uploadUrl":"https://x.example/up/",
          "accounts":{"A1":{"name":"a","isPersonal":true,"isReadOnly":false}},
          "primaryAccounts":{"urn:ietf:params:jmap:mail":"A1"}
        }
        """.utf8)
        // Initial Email/query + Email/get returns one email with one attachment.
        StubProtocol.postQueue = [
            Data("""
            {"methodResponses":[
              ["Email/query", {"ids":["E1"], "accountId":"A1"}, "q"],
              ["Email/get", {"state":"S1","list":[
                {"id":"E1","messageId":["m1@x"],"subject":"with attachment",
                 "from":[{"email":"a@x"}],"to":[{"email":"b@x"}],
                 "receivedAt":"2026-04-01T12:00:00Z","size":2048,
                 "keywords":{},"hasAttachment":true,
                 "textBody":[{"partId":"P1"}],"htmlBody":[],
                 "bodyValues":{"P1":{"value":"see attached"}},
                 "attachments":[
                   {"partId":"P2","blobId":"BLOB1","size":4,
                    "name":"hi.bin","type":"application/octet-stream"}
                 ]}
              ]}, "g"]
            ]}
            """.utf8)
        ]

        // Stub a separate GET stream for the blob download: we use a tiny
        // helper subclass so a single test can short-circuit the GET into
        // 4 bytes ("DATA") instead of routing through sessionJSON.
        AttachmentByteStub.bytes = Data("DATA".utf8)

        let dbDir = tempDir()
        let store = try MailStore(url: dbDir.appendingPathComponent("mail.sqlite"))
        let accID = try await store.upsertAccount(name: "JMAP", address: "a@x", kind: "jmap")
        let client = makeClientWithByteStub()
        _ = try await client.discover()
        let sync = JMAPSync(client: client, store: store, localAccountID: accID)

        _ = try await sync.pullRecent(
            mailbox: JMAPMailbox(id: "M1", name: "Inbox", role: "inbox",
                                 totalEmails: 1, unreadEmails: 1),
            folderName: "INBOX"
        )

        // The attachment row should already exist with externalID set and
        // size populated from the JMAP size hint, but no sha256 yet.
        let local = try await store.localRowID(forJMAPEmailID: "E1")!
        let attsBefore = try await store.attachments(messageRowID: local)
        XCTAssertEqual(attsBefore.count, 1)
        XCTAssertEqual(attsBefore.first?.externalID, "BLOB1")
        XCTAssertEqual(attsBefore.first?.sizeBytes, 4)
        XCTAssertNil(attsBefore.first?.sha256Hex)

        // Download the bytes — should write through to BlobStore.
        let result = try await sync.downloadAttachment(attachmentID: attsBefore.first!.id)
        XCTAssertEqual(result.sizeBytes, 4)
        XCTAssertNotNil(result.sha256Hex)

        // Round-trip the bytes via the BlobStore.
        let raw = await store.loadAttachmentData(sha256Hex: result.sha256Hex!)
        XCTAssertEqual(raw, Data("DATA".utf8))
    }

    private func makeClientWithByteStub() -> JMAPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AttachmentByteStub.self]
        let session = URLSession(configuration: config)
        let cfg = JMAPConfig(
            sessionURL: URL(string: "https://example.com/.well-known/jmap")!,
            credential: .bearer("fake-token")
        )
        return JMAPClient(config: cfg, urlSession: session)
    }

    /// Variant of StubProtocol that returns `bytes` for any GET request and
    /// otherwise delegates to the standard postQueue / sessionJSON behavior.
    final class AttachmentByteStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var bytes: Data = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url ?? URL(string: "stub://nowhere")!
            let method = request.httpMethod ?? "GET"
            let body: Data
            if method == "GET" && url.path.contains("/dl/") {
                body = Self.bytes
            } else if method == "POST" {
                StubProtocol.lastPostBody = request.bodySteamReadAllData() ?? request.httpBody
                if !StubProtocol.postQueue.isEmpty {
                    body = StubProtocol.postQueue.removeFirst()
                } else {
                    body = StubProtocol.postJSON
                }
            } else {
                body = StubProtocol.sessionJSON
            }
            let resp = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
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
