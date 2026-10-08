import Foundation
import SwiftData
import WidgetKit
import CoreSpotlight
import AppIntents

extension AppContainer {
    /// Removes this installation's server accounts and local media, never remote
    /// library contents or the CloudKit-backed listening/session stores.
    func logOutAndClearLocalData() async throws {
        guard !serverState.isSigningOut else { return }
        serverState.isSigningOut = true
        defer {
            albumCoverPreloadService.finishAccountReset()
            serverState.isSigningOut = false
        }

        await playerService.stop()
        libraryIndexService.clear()
        // Remove all saved server credentials so another account cannot expose
        // the previous account's local content after logout.
        let context = ModelContext(modelContainer)
        let serverIDs = try context.fetch(FetchDescriptor<ServerConfig>()).map(\.id)
        for id in serverIDs { try await serverService.removeServer(id: id) }
        await libraryService.invalidateClientCache()
        await playlistService.invalidateClientCache()
        await radioService.invalidateClientCache()
        if let downloads = downloadService as? DownloadService {
            await downloads.cancelAllDownloads()
        }
        try await albumCoverPreloadService.suspendForAccountReset()

        for category in StorageCategorySnapshot.Kind.allCases {
            await storageManagementService.clear(category)
        }
        _ = await downloadService.garbageCollectOrphanedCovers(referencedIds: [])
        await personalMixService.clearCache()
        ColorCache.clear()
        URLCache.shared.removeAllCachedResponses()

        try LocalAccountDataCleanup.clearRecords(in: modelContainer)
        try LocalAccountDataCleanup.clearMediaFiles()
        try await widgetSyncService.clearForLogout()

        if #available(iOS 27.0, macOS 27.0, *) {
            try? await RelevantEntities.shared.removeAllEntities()
            await withCheckedContinuation { continuation in
                CSSearchableIndex(name: CassetteSpotlight.indexName)
                    .deleteAllSearchableItems { _ in continuation.resume() }
            }
            for serverId in serverIDs {
                CassetteSpotlight.resetWarmState(for: serverId)
            }
        }

        // Do not remove the defaults domain: audio, appearance, translation,
        // download preferences and integration settings belong to the user.
        UserDefaults.standard.set(false, forKey: "onboardingComplete")
        serverState.needsCredentialReentry = false
        serverState.needsSubsonicVerification = false
    }
}

@MainActor
enum LocalAccountDataCleanup {
    static func clearRecords(in container: ModelContainer) throws {
        // Only pass the local-only main store, NOT listeningModelContainer.
        let context = ModelContext(container)
        try context.delete(model: FavoriteRecord.self)
        try context.delete(model: PinnedItem.self)
        try context.delete(model: SearchHistoryEntry.self)
        try context.delete(model: QueueSnapshot.self)
        try context.delete(model: PlaylistCoverChoice.self)
        try context.delete(model: CachedLyrics.self)
        try context.delete(model: CachedTrack.self)
        try context.delete(model: DownloadedTrack.self)
        try context.delete(model: DownloadedAlbum.self)
        try context.delete(model: DownloadedPlaylist.self)
        try context.delete(model: LibraryMetadataSong.self)
        // Legacy copies in the local store, not their CloudKit counterparts.
        try context.delete(model: PlaybackEvent.self)
        try context.delete(model: PlaybackSession.self)
        try context.save()
    }

    static func clearMediaFiles() throws {
        let manager = FileManager.default
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: false)
        // Explicit app-owned media folders; never delete Documents or a store root.
        for name in ["downloads", "coverarts"] {
            let directory = documents.appendingPathComponent("app.cassette/\(name)", isDirectory: true)
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
        }
    }
}
