//
//  APIKeyStore.swift
//  AlbumAI
//

import Foundation
import Security

public enum APIKeyStoreError: LocalizedError, Sendable, Equatable {
    case missingKey
    case invalidData
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No Claude API key saved. Enter your key and tap Save."
        case .invalidData:
            return "The saved API key could not be read."
        case .unexpectedStatus(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(detail)"
        }
    }
}

/// Stores the API key as a generic password in the Keychain, available only
/// while the device is unlocked and never synced or restored to another device.
public struct APIKeyStore: Sendable {
    public static let claude = APIKeyStore(service: "AlbumAI", account: "claude-api-key")

    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let query = baseQuery.merging(attributes) { _, new in new }
            status = SecItemAdd(query as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }

    /// Returns the saved key, or nil when none is saved.
    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw APIKeyStoreError.invalidData
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }

    /// Returns the saved key, or throws `missingKey` when none is saved.
    public func load() throws -> String {
        guard let key = try read() else {
            throw APIKeyStoreError.missingKey
        }
        return key
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.unexpectedStatus(status)
        }
    }
}
