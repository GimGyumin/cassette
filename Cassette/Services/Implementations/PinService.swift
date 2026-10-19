// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData
import OSLog

@MainActor
final class PinService: PinServiceProtocol {
    private let modelContext: ModelContext
    private let modelContainer: ModelContainer
    private let serverState: ServerState
    private static let maxPinnedItems = 6
    private var widgetSyncService: WidgetSyncService?

    init(modelContainer: ModelContainer, serverState: ServerState) {
        self.serverState = serverState
        self.modelContainer = modelContainer
        // Isolated background context — NOT mainContext. Using mainContext here
        // caused every pin/unpin to call mainContext.save(), which triggered
        // @Query<SearchHistoryEntry> to re-evaluate and re-apply all @Model
        // property setters, producing a cascade of 40+ observation fires per
        // pin action. Background context saves notify the store coordinator
        // but do not directly flush the main context, decoupling pin writes
        // from the search history @Query.
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        self.modelContext = ctx
    }

    func setWidgetSyncService(_ service: WidgetSyncService) {
        widgetSyncService = service
    }

    // MARK: - Query

    func isPinned(itemType: PinnedItemType, itemId: String) -> Bool {
        guard let sid = serverState.activeServer?.id, !serverState.isSigningOut else { return false }
        let type = itemType.rawValue
        var descriptor = FetchDescriptor<PinnedItem>(predicate: #Predicate {
            $0.serverId == sid && $0.itemType == type && $0.itemId == itemId
        })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetchCount(descriptor)) ?? 0 > 0
    }

    func currentPinnedCount() -> Int {
        guard let sid = serverState.activeServer?.id, !serverState.isSigningOut else { return 0 }
        return (try? modelContext.fetchCount(FetchDescriptor<PinnedItem>(predicate: #Predicate { $0.serverId == sid }))) ?? 0
    }

    func isPinnedInBackground(itemType: PinnedItemType, itemId: String) async -> Bool {
        guard let sid = serverState.activeServer?.id,
              let identity = try? serverState.requestIdentity(for: sid) else { return false }
        let type = itemType.rawValue
        let found = await Task.detached(priority: .utility) { [modelContainer] in
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<PinnedItem>(predicate: #Predicate {
                $0.serverId == sid && $0.itemType == type && $0.itemId == itemId
            })
            descriptor.fetchLimit = 1
            return (try? context.fetch(descriptor).isEmpty) == false
        }.value
        return serverState.requestIsCurrent(identity) && found
    }

    // MARK: - Pin

    func pin(
        itemType: PinnedItemType,
        itemId: String,
        displayName: String,
        displaySubtitle: String,
        coverArtId: String?,
        serverId: UUID
    ) throws {
        _ = try serverState.requestIdentity(for: serverId)
        let type = itemType.rawValue
        var existingDescriptor = FetchDescriptor<PinnedItem>(predicate: #Predicate {
            $0.serverId == serverId && $0.itemType == type && $0.itemId == itemId
        })
        existingDescriptor.fetchLimit = 1
        if (try? modelContext.fetchCount(existingDescriptor)) ?? 0 > 0 { return }

        let count = currentPinnedCount()
        guard count < PinService.maxPinnedItems else { throw PinError.limitReached }

        let item = PinnedItem(
            itemType: itemType,
            itemId: itemId,
            displayName: displayName,
            displaySubtitle: displaySubtitle,
            coverArtId: coverArtId,
            serverId: serverId,
            sortOrder: count
        )
        modelContext.insert(item)
        try modelContext.save()
        Logger.pin.info("Pinned \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public) at position \(count, privacy: .public)")
        let ws = widgetSyncService
        Task { await ws?.syncPinned() }
    }

    // MARK: - Unpin

    func unpin(itemType: PinnedItemType, itemId: String) {
        guard let sid = serverState.activeServer?.id, !serverState.isSigningOut else { return }
        let type = itemType.rawValue
        var descriptor = FetchDescriptor<PinnedItem>(predicate: #Predicate {
            $0.serverId == sid && $0.itemType == type && $0.itemId == itemId
        })
        descriptor.fetchLimit = 1
        guard let item = try? modelContext.fetch(descriptor).first else { return }

        modelContext.delete(item)

        let allDescriptor = FetchDescriptor<PinnedItem>(
            predicate: #Predicate { $0.serverId == sid },
            sortBy: [SortDescriptor(\PinnedItem.sortOrder)]
        )
        let remaining = (try? modelContext.fetch(allDescriptor)) ?? []
        for (index, pinned) in remaining.enumerated() {
            pinned.sortOrder = index
        }

        try? modelContext.save()
        Logger.pin.info("Unpinned \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
        let ws = widgetSyncService
        Task { await ws?.syncPinned() }
    }

    // MARK: - Update

    func updateCoverArtId(itemType: PinnedItemType, itemId: String, newCoverArtId: String?) {
        guard let sid = serverState.activeServer?.id, !serverState.isSigningOut else { return }
        let type = itemType.rawValue
        var descriptor = FetchDescriptor<PinnedItem>(predicate: #Predicate {
            $0.serverId == sid && $0.itemType == type && $0.itemId == itemId
        })
        descriptor.fetchLimit = 1
        guard let item = try? modelContext.fetch(descriptor).first else { return }
        item.coverArtId = newCoverArtId
        try? modelContext.save()
        Logger.pin.debug("Updated coverArtId for \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public) → \(newCoverArtId ?? "<nil>", privacy: .public)")
    }

    // MARK: - Reorder

    func reorder(items: [PinnedItem]) {
        guard let sid = serverState.activeServer?.id, !serverState.isSigningOut else { return }
        let rows = (try? modelContext.fetch(FetchDescriptor<PinnedItem>(predicate: #Predicate { $0.serverId == sid }))) ?? []
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, item) in items.filter({ $0.serverId == sid }).enumerated() {
            byID[item.id]?.sortOrder = index
        }
        try? modelContext.save()
        Logger.pin.info("Reordered \(items.count, privacy: .public) pinned items")
    }
}
