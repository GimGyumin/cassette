import Foundation
import SwiftSonic

/// Local, automatically refreshed collections use the same playlist screen as server playlists.
/// Their IDs belong to the local download store, never to the server's playlist mutation API.
nonisolated enum GeneratedPlaylistSource: Hashable, Sendable {
    case personalMix(PersonalMixKind)
    case artistStation(ArtistID3)

    var id: String {
        switch self {
        case .personalMix(let kind): "cassette.mix.\(kind.rawValue)"
        case .artistStation(let artist): "cassette.station.\(artist.id)"
        }
    }

    var mixKind: PersonalMixKind? {
        if case .personalMix(let kind) = self { return kind }
        return nil
    }

    static func fromLocalPlaylistID(_ id: String) -> Self? {
        let prefix = "cassette.mix."
        guard id.hasPrefix(prefix), let kind = PersonalMixKind(rawValue: String(id.dropFirst(prefix.count))) else { return nil }
        return .personalMix(kind)
    }

    @MainActor var title: String {
        switch self {
        case .personalMix(let kind):
            return String(localized: String.LocalizationValue(kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .artistStation(let artist):
            return String(format: String(localized: "%@ & Similar Artists", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), artist.name)
        }
    }
}

nonisolated struct GeneratedPlaylistSnapshot: Sendable {
    let name: String
    let owner: String?
    let tracks: [DisplayableSong]
    let updatedAt: Date
}

extension GeneratedPlaylistSource {
    @MainActor
    func snapshot(in container: AppContainer, forceRefresh: Bool) async -> GeneratedPlaylistSnapshot? {
        guard let sid = container.serverState.activeServer?.id,
              let identity = try? container.serverState.requestIdentity(for: sid) else { return nil }
        let owner = container.serverState.activeServer?.username
        switch self {
        case .personalMix(let kind):
            let mix = await container.personalMixService.mix(kind: kind, serverId: sid.uuidString, forceRefresh: forceRefresh)
            guard container.serverState.requestIsCurrent(identity), !Task.isCancelled, let mix else { return nil }
            return GeneratedPlaylistSnapshot(name: title, owner: owner, tracks: mix.tracks, updatedAt: mix.updatedAt)
        case .artistStation(let artist):
            var tracks = (try? await container.libraryService.topSongs(artist: artist.name, count: 20)) ?? []
            guard container.serverState.requestIsCurrent(identity), !Task.isCancelled else { return nil }
            if tracks.isEmpty {
                tracks = Array(((try? await container.libraryService.fetchAllTracks(forArtistID: artist.id)) ?? []).prefix(20))
            }
            guard container.serverState.requestIsCurrent(identity), !Task.isCancelled else { return nil }
            let info = try? await container.libraryService.getArtistInfo(forArtistID: artist.id, count: 3)
            guard container.serverState.requestIsCurrent(identity), !Task.isCancelled else { return nil }
            for similar in (info?.similarArtist ?? []).prefix(3) {
                tracks += (try? await container.libraryService.topSongs(artist: similar.name, count: 10)) ?? []
                guard container.serverState.requestIsCurrent(identity), !Task.isCancelled else { return nil }
            }
            var seen = Set<String>()
            tracks = tracks.filter { seen.insert($0.id).inserted }
            return GeneratedPlaylistSnapshot(name: title, owner: owner, tracks: tracks, updatedAt: Date())
        }
    }
}
