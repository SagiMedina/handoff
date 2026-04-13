import Foundation
import Security

/// Persists connection configuration.
/// SSH private key goes in Keychain; non-secret metadata in UserDefaults.
final class ConfigStore: ObservableObject {

    static let shared = ConfigStore()

    private let defaults = UserDefaults.standard
    private let keychainService = "com.handoff.ssh-key"
    private let keychainAccount = "phone-key"

    private enum Keys {
        static let ip = "handoff.ip"
        static let user = "handoff.user"
        static let tmuxPath = "handoff.tmuxPath"
    }

    @Published private(set) var config: ConnectionConfig?

    init() {
        self.config = load()
    }

    var isPaired: Bool { config != nil }

    // MARK: - Save

    func save(_ config: ConnectionConfig) {
        // Save private key to Keychain
        saveToKeychain(config.privateKey)

        // Save non-secret fields to UserDefaults
        defaults.set(config.ip, forKey: Keys.ip)
        defaults.set(config.user, forKey: Keys.user)
        defaults.set(config.tmuxPath, forKey: Keys.tmuxPath)

        self.config = config
    }

    // MARK: - Load

    func load() -> ConnectionConfig? {
        guard let ip = defaults.string(forKey: Keys.ip),
              let user = defaults.string(forKey: Keys.user),
              let tmuxPath = defaults.string(forKey: Keys.tmuxPath),
              let privateKey = loadFromKeychain() else {
            return nil
        }

        return ConnectionConfig(ip: ip, user: user, privateKey: privateKey, tmuxPath: tmuxPath)
    }

    // MARK: - Unpair

    func unpair() {
        deleteFromKeychain()
        defaults.removeObject(forKey: Keys.ip)
        defaults.removeObject(forKey: Keys.user)
        defaults.removeObject(forKey: Keys.tmuxPath)
        config = nil
    }

    // MARK: - Keychain

    private func saveToKeychain(_ value: String) {
        // Delete existing item first
        deleteFromKeychain()

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
