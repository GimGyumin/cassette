// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

// History views consume immutable snapshots and history-specific notifications.
// Unrelated playback/favorite saves no longer re-fetch the list through mainContext's @Query.

actor SearchHistoryService {
    nonisolated static let didChange = Notification.Name("cassetteSearchHistoryChanged")
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    /// Fetch and snapshot on this actor, away from keyboard/layout work and mainContext merges.
    func recent(serverId: String) -> [SearchHistoryRowData] {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        var descriptor = FetchDescriptor<SearchHistoryEntry>(
            predicate: #Predicate { $0.serverId == serverId },
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return ((try? ctx.fetch(descriptor)) ?? []).map(SearchHistoryRowData.init(entry:))
    }

    private func notifyChange(serverId: String) async {
        await MainActor.run {
            NotificationCenter.default.post(name: Self.didChange, object: serverId)
        }
    }

    func record(itemId: String, itemType: String, displayName: String,
                coverArtId: String?, serverId: String) async {
        let ctx = ModelContext(container)
        let compositeId = "\(serverId)_\(itemId)"

        let descriptor = FetchDescriptor<SearchHistoryEntry>(
            predicate: #Predicate { $0.entryId == compositeId }
        )
        if let existing = try? ctx.fetch(descriptor).first {
            existing.visitedAt = Date()
        } else {
            ctx.insert(SearchHistoryEntry(
                itemId: itemId, itemType: itemType,
                displayName: displayName, coverArtId: coverArtId,
                serverId: serverId
            ))
            // Enforce 50-entry cap: delete oldest entries if over limit
            let all = FetchDescriptor<SearchHistoryEntry>(
                predicate: #Predicate { $0.serverId == serverId },
                sortBy: [SortDescriptor(\.visitedAt, order: .forward)]
            )
            if let entries = try? ctx.fetch(all), entries.count > 50 {
                entries.prefix(entries.count - 50).forEach { ctx.delete($0) }
            }
        }
        do {
            try ctx.save()
            await notifyChange(serverId: serverId)
        } catch { return }
    }

    func clear(serverId: String) async {
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<SearchHistoryEntry>(
            predicate: #Predicate { $0.serverId == serverId }
        )
        if let entries = try? ctx.fetch(descriptor) {
            entries.forEach { ctx.delete($0) }
            do {
                try ctx.save()
                await notifyChange(serverId: serverId)
            } catch { return }
        }
    }
}
