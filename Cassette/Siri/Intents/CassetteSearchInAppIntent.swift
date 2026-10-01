// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import AppIntents
import Foundation

/// Opens Cassette's existing search surface with the system-provided query.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct CassetteSearchInAppIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search in Cassette"

    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriSearchRequestStore.publish(criteria.term)
        return .result()
    }
}

/// Persists a cold-launch search until MainTabView/SearchView are mounted.
enum SiriSearchRequestStore {
    private static let pendingQueryKey = "cassette.siri.pendingSearchQuery"

    @MainActor
    static func publish(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: pendingQueryKey)
        NotificationCenter.default.post(
            name: .cassetteSearchInApp,
            object: nil,
            userInfo: ["query": trimmed]
        )
    }

    @MainActor
    static func consume() -> String? {
        guard let query = UserDefaults.standard.string(forKey: pendingQueryKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingQueryKey)
        return query
    }
}
