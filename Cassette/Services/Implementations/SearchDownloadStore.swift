import Foundation
import SwiftData

/// Uses a separate context so search reads never observe every main-context save.
@MainActor
final class SearchDownloadStore {
    private let context: ModelContext

    init(modelContainer: ModelContainer) {
        context = ModelContext(modelContainer)
    }

    func matching(_ query: String, serverId: UUID) -> [DisplayableSong] {
        let descriptor = FetchDescriptor<DownloadedTrack>(
            predicate: #Predicate { $0.serverId == serverId },
            sortBy: [SortDescriptor(\.title)]
        )
        let tracks = (try? context.fetch(descriptor)) ?? []
        return tracks.filter {
            $0.title.localizedStandardContains(query)
                || ($0.artist?.localizedStandardContains(query) ?? false)
                || ($0.album?.localizedStandardContains(query) ?? false)
        }.map { DisplayableSong(from: $0) }
    }
}
