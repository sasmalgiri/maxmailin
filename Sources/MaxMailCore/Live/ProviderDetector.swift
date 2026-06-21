import Foundation

/// One-table-lookup mail-provider detector. Given an email address,
/// returns a fully-populated `ProviderProfile` with IMAP / SMTP / JMAP
/// endpoints + the auth mechanism the provider requires. Powers the
/// "type your address → Continue" account-setup flow — no host / port
/// questions, no fumbling with which port number is implicit TLS vs
/// STARTTLS.
///
/// Coverage: the providers that account for the long tail of real
/// users (Gmail, iCloud, Outlook / M365, Fastmail, Yahoo). Domains
/// outside the table return nil so the UI can fall back to manual
/// entry rather than guessing wrong.
public enum ProviderDetector {

    public enum AuthMechanism: Sendable, Equatable {
        case oauth(scopes: [String])    // XOAUTH2 against the provider's OAuth flow
        case appPassword                // user generates an app-specific password in the provider's web UI
        case basic                      // username + password (legacy, mostly internal/IT)
    }

    public struct ProviderProfile: Sendable, Equatable {
        public let displayName: String
        public let imap: IMAPEndpoint
        public let smtp: SMTPEndpoint
        public let jmapEndpoint: URL?      // nil when the provider doesn't support JMAP
        public let auth: AuthMechanism
        public let helpURL: URL?            // shown next to the address field when auth needs human setup

        public init(displayName: String, imap: IMAPEndpoint, smtp: SMTPEndpoint,
                    jmapEndpoint: URL?, auth: AuthMechanism, helpURL: URL?) {
            self.displayName = displayName
            self.imap = imap
            self.smtp = smtp
            self.jmapEndpoint = jmapEndpoint
            self.auth = auth
            self.helpURL = helpURL
        }
    }

    public struct IMAPEndpoint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let useTLS: Bool
        public init(host: String, port: UInt16, useTLS: Bool) {
            self.host = host; self.port = port; self.useTLS = useTLS
        }
    }

    public struct SMTPEndpoint: Sendable, Equatable {
        public let host: String
        public let port: UInt16
        public let encryption: SMTPEncryption
        public init(host: String, port: UInt16, encryption: SMTPEncryption) {
            self.host = host; self.port = port; self.encryption = encryption
        }
    }

    /// Look up the provider for an email address. Returns nil when the
    /// domain isn't in the table; the caller should fall back to
    /// manual host / port entry. Case-insensitive on the domain.
    public static func detect(emailAddress: String) -> ProviderProfile? {
        let trimmed = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: at)...]).lowercased()
        return profile(forDomain: domain)
    }

    /// Direct lookup for tests / UI previews that already have a domain.
    public static func profile(forDomain domain: String) -> ProviderProfile? {
        switch domain {
        case "gmail.com", "googlemail.com":
            return ProviderProfile(
                displayName: "Gmail",
                imap: .init(host: "imap.gmail.com", port: 993, useTLS: true),
                smtp: .init(host: "smtp.gmail.com", port: 587, encryption: .startTLS),
                jmapEndpoint: nil,
                auth: .oauth(scopes: [
                    "https://mail.google.com/",
                    "https://www.googleapis.com/auth/userinfo.email"
                ]),
                helpURL: URL(string: "https://developers.google.com/identity/protocols/oauth2")
            )
        case "icloud.com", "me.com", "mac.com":
            // iCloud requires an app-specific password — no OAuth path
            // exposed to third-party mail clients. Link the user
            // straight at Apple's "App-Specific Passwords" page.
            return ProviderProfile(
                displayName: "iCloud",
                imap: .init(host: "imap.mail.me.com", port: 993, useTLS: true),
                smtp: .init(host: "smtp.mail.me.com", port: 587, encryption: .startTLS),
                jmapEndpoint: nil,
                auth: .appPassword,
                helpURL: URL(string: "https://support.apple.com/en-us/HT204397")
            )
        case "outlook.com", "hotmail.com", "live.com", "msn.com", "office365.com":
            return ProviderProfile(
                displayName: "Outlook / Microsoft 365",
                imap: .init(host: "outlook.office365.com", port: 993, useTLS: true),
                smtp: .init(host: "smtp.office365.com", port: 587, encryption: .startTLS),
                jmapEndpoint: nil,
                auth: .oauth(scopes: [
                    "https://outlook.office.com/IMAP.AccessAsUser.All",
                    "https://outlook.office.com/SMTP.Send",
                    "offline_access"
                ]),
                helpURL: URL(string: "https://learn.microsoft.com/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth")
            )
        case "fastmail.com", "fastmail.fm":
            // Fastmail is the only major consumer provider with a
            // production JMAP endpoint, so we light it up here. IMAP
            // stays available as a fallback for the existing code path.
            return ProviderProfile(
                displayName: "Fastmail",
                imap: .init(host: "imap.fastmail.com", port: 993, useTLS: true),
                smtp: .init(host: "smtp.fastmail.com", port: 465, encryption: .implicit),
                jmapEndpoint: URL(string: "https://api.fastmail.com/jmap/session"),
                auth: .appPassword,
                helpURL: URL(string: "https://www.fastmail.help/hc/en-us/articles/360058752854")
            )
        case "yahoo.com", "ymail.com", "rocketmail.com":
            return ProviderProfile(
                displayName: "Yahoo",
                imap: .init(host: "imap.mail.yahoo.com", port: 993, useTLS: true),
                smtp: .init(host: "smtp.mail.yahoo.com", port: 465, encryption: .implicit),
                jmapEndpoint: nil,
                auth: .appPassword,
                helpURL: URL(string: "https://help.yahoo.com/kb/SLN15241.html")
            )
        case "aol.com":
            return ProviderProfile(
                displayName: "AOL",
                imap: .init(host: "imap.aol.com", port: 993, useTLS: true),
                smtp: .init(host: "smtp.aol.com", port: 465, encryption: .implicit),
                jmapEndpoint: nil,
                auth: .appPassword,
                helpURL: URL(string: "https://help.aol.com/articles/Create-and-manage-app-password")
            )
        default:
            return nil
        }
    }
}
