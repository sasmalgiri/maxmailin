import XCTest
@testable import MaxMailCore

final class IMAPTests: XCTestCase {

    // MARK: - IMAPSync.flags

    func testFlagsMappingCovers4StandardImapKeywords() {
        let mapped = IMAPSync.flags(from: ["\\Seen", "\\Flagged", "\\Answered", "\\Draft", "$user"])
        XCTAssertTrue(mapped.contains(.seen))
        XCTAssertTrue(mapped.contains(.flagged))
        XCTAssertTrue(mapped.contains(.answered))
        XCTAssertTrue(mapped.contains(.draft))
        // Unknown keywords are dropped, not crashed on.
    }

    func testFlagsMappingIsCaseInsensitive() {
        let mapped = IMAPSync.flags(from: ["\\SEEN", "\\flagged"])
        XCTAssertTrue(mapped.contains(.seen))
        XCTAssertTrue(mapped.contains(.flagged))
    }

    // MARK: - Wire-level guard rails

    func testIMAPSendBeforeConnectErrors() async {
        let conn = IMAPConnection(host: "imap.example.com", port: 993, useTLS: true)
        do {
            _ = try await conn.send(tag: "A001", command: "NOOP")
            XCTFail("expected notConnected")
        } catch let e as IMAPError {
            if case .notConnected = e { return }
            XCTFail("wrong error: \(e)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Streaming contract

    func testStreamMessagesReturnsAnAsyncSequence() {
        // We can't really exercise the stream without a live server, but
        // the type signature is the contract: streamMessages returns
        // AsyncThrowingStream<IMAPMessage, Error>, not [IMAPMessage].
        // If this compiles, the streaming discipline is preserved.
        let client = IMAPClient(config: IMAPConfig(
            host: "imap.example.com",
            username: "u", password: "p"
        ))
        let stream: AsyncThrowingStream<IMAPMessage, Error> =
            client.streamMessages(uids: [], chunkSize: 100)
        Task { for try await _ in stream {} }   // structural check
        XCTAssertNotNil(stream)
    }
}
