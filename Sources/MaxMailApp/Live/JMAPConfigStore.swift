import Foundation

/// Minimal JMAP credentials store. Persists to UserDefaults for now so the
/// Compose flow has somewhere to read the session URL + token from. Keychain
/// migration is the obvious next move; the API stays the same.
public struct JMAPConfigStore {
    public struct StoredConfig: Sendable, Codable {
        public let displayName: String
        public let sessionURL: String
        public let bearerToken: String
        public let senderEmail: String
    }

    private static let key = "maxmailin.jmap.configs.v1"

    public static func all() -> [StoredConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([StoredConfig].self, from: data)
        else { return [] }
        return decoded
    }

    public static func save(_ configs: [StoredConfig]) {
        let data = (try? JSONEncoder().encode(configs)) ?? Data()
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func upsert(_ cfg: StoredConfig) {
        var current = all()
        if let idx = current.firstIndex(where: { $0.displayName == cfg.displayName }) {
            current[idx] = cfg
        } else {
            current.append(cfg)
        }
        save(current)
    }

    public static func remove(displayName: String) {
        var current = all()
        current.removeAll { $0.displayName == displayName }
        save(current)
    }

    public static func first() -> StoredConfig? { all().first }
}
