// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Security
import OSLog

/// Updates an existing item before adding a missing one, without deleting a good credential.
nonisolated enum KeychainUpsert {
    static func perform(update: () -> OSStatus, add: () -> OSStatus) -> OSStatus {
        let updated = update()
        if updated != errSecItemNotFound { return updated }
        let added = add()
        // A second writer may have inserted the item between the update and add.
        return added == errSecDuplicateItem ? update() : added
    }
}

actor KeychainService: KeychainServiceProtocol {
    // kSecAttrService groups all Cassette credentials for bulk queries and cleanup.
    private let service = "app.cassette.server-credentials"

    func store<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        let data = try JSONEncoder().encode(value)

        let itemQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String:      data,
            // AfterFirstUnlock allows Keychain reads while the screen is locked,
            // required for auto-next playback transitions triggered on the lock screen.
            // Updating this attribute also migrates existing WhenUnlocked items in place.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addQuery = itemQuery.merging(attributes) { _, new in new }
        let status = KeychainUpsert.perform(
            update: { SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary) },
            add: { SecItemAdd(addQuery as CFDictionary, nil) }
        )
        guard status == errSecSuccess else {
            // Never log `data` — it may contain credentials.
            Logger.keychain.error("Keychain write failed for key '\(key, privacy: .public)' — OSStatus \(status)")
            throw CassetteError.keychainWriteFailed(status)
        }
    }

    func retrieve<T: Codable & Sendable>(_ type: T.Type, forKey key: String) async throws -> T? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            Logger.keychain.error("Keychain read failed for key '\(key, privacy: .public)' — OSStatus \(status)")
            throw CassetteError.keychainReadFailed(status)
        }

        guard let data = result as? Data else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(forKey key: String) async throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Logger.keychain.error("Keychain delete failed for key '\(key, privacy: .public)' — OSStatus \(status)")
            throw CassetteError.keychainDeleteFailed(status)
        }
    }
}
