import SwiftUI

/// Stable value identities keep rows and navigation intact as another page arrives.
nonisolated enum SearchResultItem: Identifiable, Sendable {
    case song(DisplayableSong)
    case artist(LibraryIndexService.IndexedArtist)
    case album(LibraryIndexService.IndexedAlbum)
    case playlist(LibraryIndexService.IndexedPlaylist)

    var id: String {
        switch self {
        case .song(let value): "song:\(value.id)"
        case .artist(let value): "artist:\(value.id)"
        case .album(let value): "album:\(value.id)"
        case .playlist(let value): "playlist:\(value.id)"
        }
    }
    var title: String {
        switch self {
        case .song(let value): value.title
        case .artist(let value): value.name
        case .album(let value): value.name
        case .playlist(let value): value.name
        }
    }
    var coverArtId: String {
        switch self {
        case .song(let value): value.effectiveCoverArtId
        case .artist(let value): value.coverArtId ?? value.id
        case .album(let value): value.coverArtId ?? value.id
        case .playlist(let value): value.coverArtId ?? value.id
        }
    }
    @MainActor var subtitle: String {
        let kind: String
        let artist: String?
        switch self {
        case .song(let value):
            kind = String(localized: "Song", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            artist = value.artist
        case .artist:
            kind = String(localized: "Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            artist = nil
        case .album(let value):
            kind = String(localized: "Album", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            artist = value.artist
        case .playlist:
            kind = String(localized: "Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            artist = nil
        }
        return [kind, artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Filters server results as well as ranking them. Some Subsonic-compatible servers
    /// return recommendations or broad fuzzy matches that do not contain the query at all.
    static func ranked(_ items: [Self], query: String, locale: Locale) -> [Self] {
        let term = normalized(query, locale: locale)
        let tokens = term.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var scored: [(index: Int, score: Int, item: Self)] = []
        for (index, item) in items.enumerated() {
            guard !Task.isCancelled else { return [] }
            let title = normalized(item.title, locale: locale)
            let searchable = item.searchableValues
                .map { normalized($0, locale: locale) }
                .joined(separator: " ")
            guard tokens.allSatisfy(searchable.contains) else { continue }

            let score = title == term ? 4
                : title.hasPrefix(term) ? 3
                : title.contains(term) ? 2
                : 1
            scored.append((index, score, item))
        }
        return scored.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }.map(\.item)
    }

    private var searchableValues: [String] {
        switch self {
        case .song(let value): [value.title, value.artist ?? ""]
        case .artist(let value): [value.name]
        case .album(let value): [value.name, value.artist ?? ""]
        case .playlist(let value): [value.name]
        }
    }

    private static func normalized(_ value: String, locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SearchResultLabel: View {
    let item: SearchResultItem

    var body: some View {
        HStack(spacing: 14) {
            CoverArtCard(id: item.coverArtId, size: 60, cornerRadius: isArtist ? 30 : 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title3).lineLimit(1)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var isArtist: Bool {
        if case .artist = item { return true }
        return false
    }
}
