import XCTest
@testable import MaxMailCore

final class XOAUTH2Tests: XCTestCase {

    /// Matches Google's published spec: SASL string is
    /// "user=<addr>\x01auth=Bearer <token>\x01\x01" base64-encoded.
    /// The expected base64 was computed once by hand from the literal
    /// bytes — if the formatter ever drifts (extra whitespace, wrong
    /// separator) this test catches it.
    func testSASLInitialResponseMatchesGoogleSpec() {
        let encoded = XOAUTH2.saslInitialResponse(
            username: "someuser@example.com",
            accessToken: "ya29.AHES6ZQ"
        )
        // Decode and verify the raw form byte-for-byte.
        let raw = Data(base64Encoded: encoded)
        XCTAssertNotNil(raw)
        let asString = String(data: raw!, encoding: .utf8)
        XCTAssertEqual(asString,
            "user=someuser@example.com\u{01}auth=Bearer ya29.AHES6ZQ\u{01}\u{01}")
    }

    func testSASLDifferentAccessTokensProduceDifferentResponses() {
        let a = XOAUTH2.saslInitialResponse(username: "u@x", accessToken: "tokenA")
        let b = XOAUTH2.saslInitialResponse(username: "u@x", accessToken: "tokenB")
        XCTAssertNotEqual(a, b)
    }

    func testOAuthTokenIsExpiredHonoursSafetyWindow() {
        // Token that expires in 10 seconds — well inside the 30s
        // pre-expiry safety window, so the helper must report it as
        // expired so callers refresh rather than try one last call
        // that would race the actual expiry.
        let soon = OAuthToken(accessToken: "t", refreshToken: "r",
                              expiresAt: Date().addingTimeInterval(10))
        XCTAssertTrue(soon.isExpired)

        // Token that expires in 5 minutes — comfortably fresh.
        let fresh = OAuthToken(accessToken: "t", refreshToken: "r",
                               expiresAt: Date().addingTimeInterval(300))
        XCTAssertFalse(fresh.isExpired)
    }
}
