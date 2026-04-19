import Foundation

/// Trusted SSH host fingerprints keyed by host IP. These are not secrets, so
/// UserDefaults is sufficient and mirrors known_hosts-style persistence.
final class HostKeyStore {
    static let shared = HostKeyStore()

    private let defaults: UserDefaults
    private let storageKey = "handoff.trustedHostKeys.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func fingerprint(for host: String) -> HostKeyFingerprint? {
        loadAll()[host]
    }

    func trust(_ fingerprint: HostKeyFingerprint, for host: String) {
        var all = loadAll()
        all[host] = fingerprint
        persist(all)
    }

    func forget(host: String) {
        var all = loadAll()
        all.removeValue(forKey: host)
        persist(all)
    }

    func forgetAll() {
        defaults.removeObject(forKey: storageKey)
    }

    func hasTrust(for host: String) -> Bool {
        fingerprint(for: host) != nil
    }

    private func loadAll() -> [String: HostKeyFingerprint] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([String: HostKeyFingerprint].self, from: data) else {
            return [:]
        }
        return stored
    }

    private func persist(_ fingerprints: [String: HostKeyFingerprint]) {
        if fingerprints.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }

        if let data = try? JSONEncoder().encode(fingerprints) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
