import Foundation

/// SASL XOAUTH2 helpers shared by IMAP and SMTP.
///
/// XOAUTH2 is the OAuth-2.0-based SASL mechanism Gmail, Microsoft 365,
/// and Yahoo accept in place of plain-text passwords. The wire format
/// per Google / Microsoft documentation:
///
///     "user=<address>\x01auth=Bearer <access_token>\x01\x01"
///
/// → base64-encoded, then sent as the IMAP `AUTHENTICATE XOAUTH2`
/// initial response or the SMTP `AUTH XOAUTH2` argument.
///
/// On failure the server replies with a `+` (IMAP) or `334` (SMTP)
/// continuation containing a base64 JSON error blob; the client is
/// expected to send an empty line so the server can finalise the
/// failure with a tagged NO / 535. The client surfaces don't have to
/// parse the JSON for v1 — the failure status code is enough.
public enum XOAUTH2 {

    /// Build the base64-encoded SASL initial response.
    public static func saslInitialResponse(
        username: String, accessToken: String
    ) -> String {
        let raw = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        return Data(raw.utf8).base64EncodedString()
    }
}

/// Provider-agnostic OAuth token holder. The app layer constructs one
/// of these per account and refreshes it via the provider's
/// authorization-code grant flow (Gmail / Microsoft 365 specifics
/// belong in the app-layer connector, not in Core).
public struct OAuthToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Treat the token as expired 30 seconds before its actual
    /// expiry so a refresh has time to land before the next IMAP
    /// auth attempt.
    public var isExpired: Bool {
        Date().addingTimeInterval(30) >= expiresAt
    }
}

/// The credential surface IMAP / SMTP need at auth time. Implementers
/// (Gmail connector, Microsoft Graph connector, the future
/// generic-OAuth helper) handle refresh internally so the protocol
/// clients never see a token-refresh dance.
public protocol OAuthTokenProvider: Sendable {
    /// Return a fresh, non-expired access token for the configured
    /// account. May refresh if the cached token is expired or close
    /// to expiry. Throws when the refresh itself fails — caller
    /// should surface to the user (re-auth needed).
    func accessToken() async throws -> String
}
