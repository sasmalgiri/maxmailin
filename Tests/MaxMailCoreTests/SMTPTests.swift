import XCTest
@testable import MaxMailCore

final class SMTPTests: XCTestCase {

    func testEncodeWritesStandardHeadersAndCRLFTerminatedBody() {
        let msg = SMTPClient.OutboundMessage(
            from: "alice@example.com",
            to: ["bob@example.com"],
            subject: "Hello",
            plainBody: "Body line 1\nBody line 2",
            messageID: "<m1@maxmailin.local>"
        )
        let bytes = SMTPClient.encode(msg)
        guard let text = String(data: bytes, encoding: .utf8) else {
            XCTFail("non-utf8 output"); return
        }
        XCTAssertTrue(text.contains("From: alice@example.com"))
        XCTAssertTrue(text.contains("To: bob@example.com"))
        XCTAssertTrue(text.contains("Subject: Hello"))
        XCTAssertTrue(text.contains("Message-ID: <m1@maxmailin.local>"))
        XCTAssertTrue(text.contains("MIME-Version: 1.0"))
        XCTAssertTrue(text.contains("Content-Type: text/plain"))
        // Body lines must use CRLF separators per RFC 5321.
        XCTAssertTrue(text.contains("Body line 1\r\nBody line 2"))
    }

    func testEncodeDotStuffsBodyLinesStartingWithPeriod() {
        let msg = SMTPClient.OutboundMessage(
            from: "a@x", to: ["b@x"],
            subject: "S",
            plainBody: ".secret\nNormal line\n.another secret",
            messageID: "<m@x>"
        )
        let text = String(data: SMTPClient.encode(msg), encoding: .utf8)!
        // Every body line starting with "." must be prefixed with another
        // "." so the SMTP terminator "." can't be triggered mid-message.
        XCTAssertTrue(text.contains("..secret"))
        XCTAssertTrue(text.contains("..another secret"))
        XCTAssertTrue(text.contains("Normal line"))
    }

    func testEncodeIncludesCcAndThreadingHeadersWhenSet() {
        let msg = SMTPClient.OutboundMessage(
            from: "a@x", to: ["b@x"], cc: ["c@x", "d@x"],
            subject: "Re: thread",
            plainBody: "ok",
            messageID: "<m2@x>",
            inReplyTo: "<m1@x>",
            references: ["<m0@x>", "<m1@x>"]
        )
        let text = String(data: SMTPClient.encode(msg), encoding: .utf8)!
        XCTAssertTrue(text.contains("Cc: c@x, d@x"))
        XCTAssertTrue(text.contains("In-Reply-To: <m1@x>"))
        XCTAssertTrue(text.contains("References: <m0@x> <m1@x>"))
    }

    func testSMTPSendBeforeConnectErrors() async {
        let smtp = SMTPClient(config: SMTPConfig(
            host: "smtp.example.com",
            username: "u", password: "p"
        ))
        do {
            _ = try await smtp.send(SMTPClient.OutboundMessage(
                from: "a@x", to: ["b@x"], subject: "S",
                plainBody: "x", messageID: "<m@x>"
            ))
            XCTFail("expected notConnected")
        } catch let e as SMTPError {
            if case .notConnected = e { return }
            XCTFail("wrong error: \(e)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
