// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

@Observable
@MainActor
final class StorageManagementViewModel {
    var categories: [StorageCategorySnapshot] = []
    var totalFormatted: String = "—"
    var reclaimableAudioBytes: Int64 = 0
    var largestFirst = true
    var sortedCategories: [StorageCategorySnapshot] {
        categories.sorted { largestFirst ? $0.byteCount > $1.byteCount : $0.byteCount < $1.byteCount }
    }
    var totalBytes: Int64 { categories.reduce(0) { $0 + $1.byteCount } }
    var isLoading = false
    var clearingKind: StorageCategorySnapshot.Kind?
    var isResettingAll = false

    private let storageService: StorageManagementService
    private let onResetAll: () async -> Void

    init(storageService: StorageManagementService, onResetAll: @escaping () async -> Void) {
        self.storageService = storageService
        self.onResetAll = onResetAll
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let loaded = await storageService.categories()
        categories = loaded
        reclaimableAudioBytes = await storageService.reclaimableAudioBytes
        totalFormatted = ByteCountFormatter.string(
            fromByteCount: loaded.reduce(0) { $0 + $1.byteCount },
            countStyle: .file
        )
    }

    func clear(_ kind: StorageCategorySnapshot.Kind) async {
        clearingKind = kind
        defer { clearingKind = nil }
        await storageService.clear(kind)
        await refresh()
    }

    func resetCachesAndSettings() async {
        isResettingAll = true
        defer { isResettingAll = false }
        await onResetAll()
        await refresh()
    }
}
