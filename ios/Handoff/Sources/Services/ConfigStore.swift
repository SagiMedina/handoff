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
        static let protocolVersion = "handoff.protocolVersion"
        static let nonce = "handoff.nonce"
        static let pendingVerification = "handoff.pendingVerification"
        static let appLockEnabled = "handoff.appLockEnabled"
        static let terminalFontSize = "handoff.terminalFontSize"
    }

    static let defaultTerminalFontSize = 14
    static let minTerminalFontSize = 11
    static let maxTerminalFontSize = 24

    @Published private(set) var config: ConnectionConfig?
    @Published private(set) var appLockEnabled: Bool

    /// True immediately after a v2 QR is scanned and false once the device has
    /// completed the verification handshake with the Mac (or for any v1
    /// pairing, which has no verification step). Persisted so a mid-pair
    /// force-quit still routes back to the verification screen on relaunch.
    @Published private(set) var pendingVerification: Bool = false
    @Published private(set) var terminalFontSize: Int

    init() {
        let storedFontSize = defaults.integer(forKey: Keys.terminalFontSize)
        self.terminalFontSize = Self.clampedTerminalFontSize(
            storedFontSize == 0 ? Self.defaultTerminalFontSize : storedFontSize
        )
        self.config = nil
        self.appLockEnabled = defaults.bool(forKey: Keys.appLockEnabled)
        self.pendingVerification = defaults.bool(forKey: Keys.pendingVerification)
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
        defaults.set(config.protocolVersion, forKey: Keys.protocolVersion)
        defaults.set(config.nonce, forKey: Keys.nonce)

        // v2 pairings enter the verification handshake next; v1 has no such
        // step and is considered ready for Sessions immediately.
        let needsVerification = config.protocolVersion >= 2
        defaults.set(needsVerification, forKey: Keys.pendingVerification)

        self.config = config
        self.pendingVerification = needsVerification
    }

    /// Marks the device as verified after a successful gate handshake. Safe to
    /// call repeatedly.
    func markVerified() {
        defaults.set(false, forKey: Keys.pendingVerification)
        pendingVerification = false
    }

    func setAppLockEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.appLockEnabled)
        appLockEnabled = enabled
    }

    func setTerminalFontSize(_ size: Int) {
        let clamped = Self.clampedTerminalFontSize(size)
        defaults.set(clamped, forKey: Keys.terminalFontSize)
        terminalFontSize = clamped
    }

    // MARK: - Load

    func load() -> ConnectionConfig? {
        guard let ip = defaults.string(forKey: Keys.ip),
              let user = defaults.string(forKey: Keys.user),
              let tmuxPath = defaults.string(forKey: Keys.tmuxPath),
              let privateKey = loadFromKeychain() else {
            return nil
        }

        // protocolVersion defaults to 1 for pre-v2 installs: a missing key reads
        // back as 0, which we treat as v1 so old pairings keep working after the
        // app is upgraded.
        let storedVersion = defaults.integer(forKey: Keys.protocolVersion)
        let protocolVersion = storedVersion == 0 ? 1 : storedVersion
        let nonce = defaults.string(forKey: Keys.nonce) ?? ""

        return ConnectionConfig(
            ip: ip,
            user: user,
            privateKey: privateKey,
            tmuxPath: tmuxPath,
            protocolVersion: protocolVersion,
            nonce: nonce
        )
    }

    // MARK: - Unpair

    func unpair() {
        if let host = defaults.string(forKey: Keys.ip) {
            HostKeyStore.shared.forget(host: host)
        }
        deleteFromKeychain()
        defaults.removeObject(forKey: Keys.ip)
        defaults.removeObject(forKey: Keys.user)
        defaults.removeObject(forKey: Keys.tmuxPath)
        defaults.removeObject(forKey: Keys.protocolVersion)
        defaults.removeObject(forKey: Keys.nonce)
        defaults.removeObject(forKey: Keys.pendingVerification)
        defaults.removeObject(forKey: Keys.appLockEnabled)
        config = nil
        appLockEnabled = false
        pendingVerification = false
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

    private static func clampedTerminalFontSize(_ size: Int) -> Int {
        min(max(size, minTerminalFontSize), maxTerminalFontSize)
    }
}
