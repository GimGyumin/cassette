import SwiftUI

/// Stable value identities keep rows and navigation intact as another page arrives.
enum SearchResultItem: Identifiable {
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
    var subtitle: String {
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
