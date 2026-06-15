import Foundation

/// JMAP credentials store. Non-secret metadata lives in UserDefaults;
/// the bearer token is held in the system Keychain.
///
/// The public API is unchanged from the UserDefaults-only v1: callers
/// hand in / receive a fully populated `StoredConfig` with the token.
/// Auto-migration moves any v1 token blobs out of UserDefaults into
/// Keychain on first access.
public struct JMAPConfigStore {
    public struct StoredConfig: Sendable {
        public let displayName: String
        public let sessionURL: String
        public let bearerToken: String
        public let senderEmail: String

        public init(displayName: String, sessionURL: String, bearerToken: String, senderEmail: String) {
            self.displayName = displayName
            self.sessionURL = sessionURL
            self.bearerToken = bearerToken
            self.senderEmail = senderEmail
        }
    }

    // MARK: - Storage keys

    private static let metadataKey      = "maxmailin.jmap.metadata.v2"
    private static let legacyKey        = "maxmailin.jmap.configs.v1"
    private static let migrationFlagKey = "maxmailin.jmap.migrated.v2"
    private static let keychainService  = "com.maxmailin.jmap.bearer"

    // MARK: - Public API

    public static func all() -> [StoredConfig] {
        migrateIfNeeded()
        return loadMetadata().compactMap { meta in
            guard let token = Keychain.getSecret(
                service: keychainService, account: meta.displayName
            ) else {
                return nil    // metadata present but no token — skip
            }
            return StoredConfig(
                displayName: meta.displayName,
                sessionURL:  meta.sessionURL,
                bearerToken: token,
                senderEmail: meta.senderEmail
            )
        }
    }

    public static func first() -> StoredConfig? { all().first }

    public static func upsert(_ cfg: StoredConfig) {
        migrateIfNeeded()
        var metas = loadMetadata()
        let meta = Metadata(
            displayName: cfg.displayName,
            sessionURL:  cfg.sessionURL,
            senderEmail: cfg.senderEmail
        )
        if let idx = metas.firstIndex(where: { $0.displayName == cfg.displayName }) {
            metas[idx] = meta
        } else {
            metas.append(meta)
        }
        saveMetadata(metas)
        _ = Keychain.setSecret(cfg.bearerToken,
                               service: keychainService,
                               account: cfg.displayName)
    }

    public static func remove(displayName: String) {
        migrateIfNeeded()
        var metas = loadMetadata()
        metas.removeAll { $0.displayName == displayName }
        saveMetadata(metas)
        _ = Keychain.deleteSecret(service: keychainService, account: displayName)
    }

    // MARK: - Persisted shapes

    private struct Metadata: Codable {
        let displayName: String
        let sessionURL: String
        let senderEmail: String
    }

    /// v1 layout — kept around only to drive one-time migration.
    private struct LegacyConfig: Codable {
        let displayName: String
        let sessionURL: String
        let bearerToken: String
        let senderEmail: String
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

    // MARK: - Migration

    private static func migrateIfNeeded() {
        if UserDefaults.standard.bool(forKey: migrationFlagKey) { return }
        defer { UserDefaults.standard.set(true, forKey: migrationFlagKey) }

        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode([LegacyConfig].self, from: data)
        else { return }

        var migrated = loadMetadata()
        for old in legacy {
            if !migrated.contains(where: { $0.displayName == old.displayName }) {
                migrated.append(Metadata(
                    displayName: old.displayName,
                    sessionURL:  old.sessionURL,
                    senderEmail: old.senderEmail
                ))
            }
            _ = Keychain.setSecret(old.bearerToken,
                                   service: keychainService,
                                   account: old.displayName)
        }
        saveMetadata(migrated)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
