// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import Foundation
import Security
import OSLog

/// Synchronous Keychain storage for secrets owned by settings objects.
///
/// Settings properties are read synchronously while their shared instances are created, so the
/// actor-based `KeychainService` used by server credentials is not a good fit here. This store
/// deliberately keeps only opaque strings and never logs their values.
nonisolated enum SensitiveSettingsStore {
    private static let service = "app.cassette.integration-credentials"

    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        guard !value.isEmpty else {
            let status = SecItemDelete(itemQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Logger.keychain.error("Integration credential update failed for key '\(key, privacy: .public)' — OSStatus \(updateStatus)")
            return false
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ].merging(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.keychain.error("Integration credential write failed for key '\(key, privacy: .public)' — OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    /// Moves a legacy plaintext preference into the Keychain on first read.
    static func migratedString(forKey key: String, defaults: UserDefaults = .standard) -> String {
        if let stored = string(forKey: key) {
            defaults.removeObject(forKey: key)
            return stored
        }

        let legacy = defaults.string(forKey: key) ?? ""
        guard !legacy.isEmpty else { return "" }
        if set(legacy, forKey: key) {
            defaults.removeObject(forKey: key)
        }
        return legacy
    }
}
