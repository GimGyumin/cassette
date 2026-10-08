// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Security
import Testing
@testable import Cassette

@Suite("Keychain credential replacement")
struct KeychainUpsertTests {
    @Test func failedUpdatePreservesExistingItem() {
        var addCalls = 0
        let result = KeychainUpsert.perform(
            update: { errSecAuthFailed },
            add: { addCalls += 1; return errSecSuccess }
        )
        #expect(result == errSecAuthFailed)
        #expect(addCalls == 0)
    }

    @Test func missingItemIsAddedAndConcurrentInsertIsRetried() {
        var updateCalls = 0
        let result = KeychainUpsert.perform(
            update: {
                updateCalls += 1
                return updateCalls == 1 ? errSecItemNotFound : errSecSuccess
            },
            add: { errSecDuplicateItem }
        )
        #expect(result == errSecSuccess)
        #expect(updateCalls == 2)
    }
}
