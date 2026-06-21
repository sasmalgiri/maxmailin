import XCTest
@testable import MaxMailCore

final class ProviderDetectorTests: XCTestCase {

    // MARK: - Big providers

    func testGmailDomainMapsToOAuthAndSTARTTLS() {
        let p = ProviderDetector.detect(emailAddress: "alice@gmail.com")
        XCTAssertEqual(p?.displayName, "Gmail")
        XCTAssertEqual(p?.imap.host, "imap.gmail.com")
        XCTAssertEqual(p?.imap.port, 993)
        XCTAssertEqual(p?.smtp.host, "smtp.gmail.com")
        XCTAssertEqual(p?.smtp.port, 587)
        XCTAssertEqual(p?.smtp.encryption, .startTLS)
        if case .oauth = p?.auth { /* ok */ } else {
            XCTFail("Gmail must require OAuth")
        }
    }

    func testGoogleMailDotComAliasesToGmail() {
        let p = ProviderDetector.detect(emailAddress: "alice@googlemail.com")
        XCTAssertEqual(p?.displayName, "Gmail")
    }

    func testICloudAliasesAndUsesAppPassword() {
        for addr in ["alice@icloud.com", "alice@me.com", "alice@mac.com"] {
            let p = ProviderDetector.detect(emailAddress: addr)
            XCTAssertEqual(p?.displayName, "iCloud", "addr \(addr)")
            XCTAssertEqual(p?.imap.host, "imap.mail.me.com")
            XCTAssertEqual(p?.auth, .appPassword)
            XCTAssertNotNil(p?.helpURL, "app-password providers must link the user to setup help")
        }
    }

    func testOutlookFamilyAllRouteToM365Endpoints() {
        for addr in ["alice@outlook.com", "alice@hotmail.com",
                     "alice@live.com", "alice@msn.com",
                     "alice@office365.com"] {
            let p = ProviderDetector.detect(emailAddress: addr)
            XCTAssertEqual(p?.imap.host, "outlook.office365.com",
                           "addr \(addr) must route to M365 IMAP")
            XCTAssertEqual(p?.smtp.host, "smtp.office365.com",
                           "addr \(addr) must route to M365 SMTP")
            if case .oauth = p?.auth { /* ok */ } else {
                XCTFail("Outlook family must require OAuth (addr \(addr))")
            }
        }
    }

    func testFastmailIsTheOnlyConsumerProviderWithJMAP() {
        let fm = ProviderDetector.detect(emailAddress: "alice@fastmail.com")
        XCTAssertNotNil(fm?.jmapEndpoint)
        XCTAssertEqual(fm?.jmapEndpoint?.absoluteString,
                       "https://api.fastmail.com/jmap/session")
        // Sanity check: every other provider has nil jmapEndpoint.
        for addr in ["alice@gmail.com", "alice@icloud.com",
                     "alice@outlook.com", "alice@yahoo.com",
                     "alice@aol.com"] {
            XCTAssertNil(ProviderDetector.detect(emailAddress: addr)?.jmapEndpoint,
                         "addr \(addr) should not advertise JMAP")
        }
    }

    func testYahooFamilyUsesAppPassword() {
        for addr in ["alice@yahoo.com", "alice@ymail.com", "alice@rocketmail.com"] {
            XCTAssertEqual(ProviderDetector.detect(emailAddress: addr)?.auth,
                           .appPassword)
        }
    }

    // MARK: - Fallback

    func testUnknownDomainReturnsNilSoUIFallsBackToManualEntry() {
        XCTAssertNil(ProviderDetector.detect(emailAddress: "alice@example.com"))
        XCTAssertNil(ProviderDetector.detect(emailAddress: "alice@corp.local"))
    }

    func testMalformedAddressReturnsNil() {
        XCTAssertNil(ProviderDetector.detect(emailAddress: ""))
        XCTAssertNil(ProviderDetector.detect(emailAddress: "no-at-sign"))
    }

    // MARK: - Robustness

    func testDetectionIsCaseInsensitiveOnDomain() {
        let a = ProviderDetector.detect(emailAddress: "Alice@GMAIL.com")
        let b = ProviderDetector.detect(emailAddress: "alice@gmail.com")
        XCTAssertEqual(a, b)
    }

    func testDetectionTrimsSurroundingWhitespace() {
        let p = ProviderDetector.detect(emailAddress: "  alice@gmail.com  ")
        XCTAssertEqual(p?.displayName, "Gmail")
    }

    // MARK: - Direct domain entry

    func testProfileForDomainSkipsTheLocalPartParse() {
        XCTAssertEqual(ProviderDetector.profile(forDomain: "gmail.com")?.displayName, "Gmail")
        XCTAssertNil(ProviderDetector.profile(forDomain: "unknown.tld"))
    }
}
