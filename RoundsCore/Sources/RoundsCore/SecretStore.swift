import Foundation
#if canImport(Security)
import Security
#endif

public enum SecretKey: String, CaseIterable, Sendable {
    case clientID = "reddit.clientID"
    case deviceID = "reddit.deviceID"
    case appToken = "reddit.appToken"
    case userAccessToken = "reddit.userAccessToken"
    case userRefreshToken = "reddit.userRefreshToken"
    case username = "reddit.username"
}

/// Storage for the client ID and OAuth tokens.
public protocol SecretStore: Sendable {
    func string(for key: SecretKey) -> String?
    func set(_ value: String?, for key: SecretKey)
}

/// Thread-safe in-memory store, used by tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [SecretKey: String]
    private let lock = NSLock()

    public init(_ values: [SecretKey: String] = [:]) {
        self.values = values
    }

    public func string(for key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func set(_ value: String?, for key: SecretKey) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

#if canImport(Security)
/// Generic-password items in the login Keychain.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.naren.rounds") {
        self.service = service
    }

    private func query(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    public func string(for key: SecretKey) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String?, for key: SecretKey) {
        let q = query(key)
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(q as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
#endif
