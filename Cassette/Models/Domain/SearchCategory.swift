import Foundation

nonisolated enum SearchCategory: String, CaseIterable, Identifiable {
    case all, artists, albums, songs, playlists
    var id: Self { self }

    @MainActor var title: String {
        switch self {
        case .all: String(localized: "Top Results", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .artists: String(localized: "Artists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .albums: String(localized: "Albums", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .songs: String(localized: "Songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .playlists: String(localized: "Playlists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }
}
