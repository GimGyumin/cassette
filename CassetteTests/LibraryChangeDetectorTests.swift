// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

@Suite("LibraryChangeDetector")
struct LibraryChangeDetectorTests {

    @Test func unknownServerCountNeverPrepares() {
        // A server that has never scanned reports no count — nothing to compare, so block nothing.
        #expect(!LibraryChangeDetector.needsPreparation(storedCount: 100, serverCount: nil))
    }

    @Test func firstObservationDoesNotPrepare() {
        // Onboarding already indexed and downloaded artwork for this server. The count is only
        // recorded so the *next* launch can detect a real change, which is what stops the
        // preparation screen appearing immediately after sign-in.
        #expect(!LibraryChangeDetector.needsPreparation(storedCount: nil, serverCount: 100))
    }

    @Test func unchangedLibraryDoesNotPrepare() {
        #expect(!LibraryChangeDetector.needsPreparation(storedCount: 100, serverCount: 100))
    }

    @Test func addedOrRemovedTracksPrepare() {
        #expect(LibraryChangeDetector.needsPreparation(storedCount: 100, serverCount: 101))
        #expect(LibraryChangeDetector.needsPreparation(storedCount: 100, serverCount: 99))
    }

    @Test func signatureRoundTripsAndIsPerServer() {
        let suiteName = "cassette.tests.libraryChangeDetector.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let server = UUID()
        #expect(LibraryChangeDetector.storedCount(for: server, defaults: suite) == nil)

        LibraryChangeDetector.store(count: 42, for: server, defaults: suite)
        #expect(LibraryChangeDetector.storedCount(for: server, defaults: suite) == 42)

        // A different server must not inherit the signature.
        #expect(LibraryChangeDetector.storedCount(for: UUID(), defaults: suite) == nil)

        LibraryChangeDetector.clear(for: server, defaults: suite)
        #expect(LibraryChangeDetector.storedCount(for: server, defaults: suite) == nil)
    }
}
