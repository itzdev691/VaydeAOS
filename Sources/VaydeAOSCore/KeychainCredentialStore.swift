import Foundation
import Security

public protocol CredentialStoring {
    func load(for endpoint: String) throws -> String?
    func save(_ key: String, for endpoint: String) throws
}

public struct KeychainCredentialStore: CredentialStoring {
    private static let service = "dev.vaydeaos.api"

    public init() {}

    public func load(for endpoint: String) throws -> String? {
        var query = try query(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.unreadableValue
        }
        return key
    }

    public func save(_ key: String, for endpoint: String) throws {
        var query = try query(for: endpoint)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError.keychain(status)
            }
            return
        }

        let data = Data(key.utf8)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
    }

    private func query(for endpoint: String) throws -> [String: Any] {
        let normalizedEndpoint = try ConnectionSettings(
            baseURL: endpoint,
            model: "credential-account"
        ).validated().baseURL

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: normalizedEndpoint
        ]
    }
}

public enum CredentialStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)
    case unreadableValue

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String?
            return "Could not access the API key in Keychain: \(reason ?? "error \(status)")."
        case .unreadableValue:
            return "The saved API key could not be read from Keychain. Save it again."
        }
    }
}
