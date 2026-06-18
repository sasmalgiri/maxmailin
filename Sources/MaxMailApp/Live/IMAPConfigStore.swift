import Foundation

/// IMAP credentials store. Same shape as JMAPConfigStore: non-secret
/// metadata in UserDefaults, password in the system Keychain. The
/// keychain account name is the displayName; service is fixed.
public struct IMAPConfigStore {
    public struct StoredConfig: Sendable {
        public let displayName: String
        public let host: String
        public let port: UInt16
        public let useTLS: Bool
        public let username: String
        public let password: String
        public let senderEmail: String
        // SMTP submission (port 465 implicit TLS for first cut). Same
        // credentials are reused — Gmail/iCloud/Outlook all accept one
        // app password for both IMAP and SMTP.
        public let smtpHost: String
        public let smtpPort: UInt16

        public init(displayName: String, host: String, port: UInt16, useTLS: Bool,
                    username: String, password: String, senderEmail: String,
                    smtpHost: String, smtpPort: UInt16) {
            self.displayName = displayName
            self.host = host
            self.port = port
            self.useTLS = useTLS
            self.username = username
            self.password = password
            self.senderEmail = senderEmail
            self.smtpHost = smtpHost
            self.smtpPort = smtpPort
        }
    }

    private static let metadataKey     = "maxmailin.imap.metadata.v1"
    private static let keychainService = "com.maxmailin.imap.password"

    public static func all() -> [StoredConfig] {
        loadMetadata().compactMap { meta in
            guard let pwd = Keychain.getSecret(service: keychainService,
                                               account: meta.displayName) else {
                return nil
            }
            return StoredConfig(
                displayName: meta.displayName,
                host: meta.host,
                port: meta.port,
                useTLS: meta.useTLS,
                username: meta.username,
                password: pwd,
                senderEmail: meta.senderEmail,
                smtpHost: meta.smtpHost ?? defaultSMTPHost(for: meta.host),
                smtpPort: meta.smtpPort ?? 465
            )
        }
    }

    /// "imap.gmail.com" → "smtp.gmail.com" — a sensible default when the
    /// caller didn't fill in the SMTP host explicitly.
    private static func defaultSMTPHost(for imapHost: String) -> String {
        if imapHost.hasPrefix("imap.") {
            return "smtp." + imapHost.dropFirst("imap.".count)
        }
        return imapHost
    }

    public static func first() -> StoredConfig? { all().first }

    public static func upsert(_ cfg: StoredConfig) {
        var metas = loadMetadata()
        let meta = Metadata(
            displayName: cfg.displayName,
            host: cfg.host, port: cfg.port, useTLS: cfg.useTLS,
            username: cfg.username, senderEmail: cfg.senderEmail,
            smtpHost: cfg.smtpHost, smtpPort: cfg.smtpPort
        )
        if let idx = metas.firstIndex(where: { $0.displayName == cfg.displayName }) {
            metas[idx] = meta
        } else {
            metas.append(meta)
        }
        saveMetadata(metas)
        _ = Keychain.setSecret(cfg.password,
                               service: keychainService,
                               account: cfg.displayName)
    }

    public static func remove(displayName: String) {
        var metas = loadMetadata()
        metas.removeAll { $0.displayName == displayName }
        saveMetadata(metas)
        _ = Keychain.deleteSecret(service: keychainService, account: displayName)
    }

    private struct Metadata: Codable {
        let displayName: String
        let host: String
        let port: UInt16
        let useTLS: Bool
        let username: String
        let senderEmail: String
        // Optional because pre-v2 metadata didn't carry them — we derive
        // sensible defaults at read time when nil.
        let smtpHost: String?
        let smtpPort: UInt16?
    }

    private static func loadMetadata() -> [Metadata] {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([Metadata].self, from: data)
        else { return [] }
        return decoded
    }

    private static func saveMetadata(_ metas: [Metadata]) {
        let data = (try? JSONEncoder().encode(metas)) ?? Data()
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
}
