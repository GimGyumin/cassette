import Foundation
import SwiftData

/// Uses a separate context so search reads never observe every main-context save.
actor SearchDownloadStore {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func matching(_ query: String, serverId: UUID) -> [DisplayableSong] {
        guard !Task.isCancelled else { return [] }
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<DownloadedTrack>(
            predicate: #Predicate { $0.serverId == serverId },
            sortBy: [SortDescriptor(\.title)]
        )
        let tracks = (try? context.fetch(descriptor)) ?? []
        return tracks.filter {
            !Task.isCancelled && ($0.title.localizedStandardContains(query)
                || ($0.artist?.localizedStandardContains(query) ?? false)
                || ($0.album?.localizedStandardContains(query) ?? false))
        }.map { DisplayableSong(from: $0) }
    }
}
