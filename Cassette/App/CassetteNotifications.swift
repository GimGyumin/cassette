// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

extension Notification.Name {
    static let cassetteFullPlayerPresentationChanged = Notification.Name("cassetteFullPlayerPresentationChanged")
}

// MARK: - Player navigation helpers

func postNavigateToAlbum(track: DisplayableSong) {
    guard let albumId = track.albumId else { return }
    NotificationCenter.default.post(
        name: .cassetteNavigateToAlbum,
        object: nil,
        userInfo: [
            "albumId":   albumId,
            "albumName": track.albumName ?? "",
            "coverArtId": track.coverArtId as Any
        ]
    )
}

func postNavigateToArtist(track: DisplayableSong) {
    guard let artistId = track.artistId else { return }
    postNavigateToArtist(artistId: artistId, artistName: track.artist ?? "", coverArtId: track.coverArtId)
}

func postNavigateToArtist(artistId: String, artistName: String, coverArtId: String?) {
    NotificationCenter.default.post(
        name: .cassetteNavigateToArtist,
        object: nil,
        userInfo: [
            "artistId":   artistId,
            "artistName": artistName,
            "coverArtId": coverArtId as Any
        ]
    )
}

func postNavigateToPlaylist(playlistId: String, name: String, coverArtId: String?) {
    NotificationCenter.default.post(
        name: .cassetteNavigateToPlaylist,
        object: nil,
        userInfo: [
            "playlistId": playlistId,
            "name":       name,
            "coverArtId": coverArtId as Any
        ]
    )
}

/// A playlist was deleted (server-confirmed) from a detail surface. The playlist list observes this to reload,
/// so the deleted playlist disappears on return without a manual refresh — and without an `.onAppear` reload.
func postPlaylistDeleted() {
    NotificationCenter.default.post(name: .cassettePlaylistDeleted, object: nil)
}

extension Notification.Name {
    nonisolated static let cassetteDownloadCompleted = Notification.Name("cassette.downloadCompleted")
    nonisolated static let cassetteTogglePlayPause = Notification.Name("cassette.togglePlayPause")
    nonisolated static let cassetteSkipNext = Notification.Name("cassette.skipNext")
    nonisolated static let cassetteSkipPrevious = Notification.Name("cassette.skipPrevious")
    nonisolated static let cassetteFocusSearch = Notification.Name("cassette.focusSearch")
    nonisolated static let cassetteSearchInApp = Notification.Name("cassette.searchInApp")
    nonisolated static let cassetteToggleShuffle = Notification.Name("cassette.toggleShuffle")
    nonisolated static let cassetteToggleRepeat = Notification.Name("cassette.toggleRepeat")
    nonisolated static let cassetteToggleQueue = Notification.Name("cassette.toggleQueue")
    nonisolated static let cassetteOpenFullPlayer = Notification.Name("cassette.openFullPlayer")
    nonisolated static let cassetteOpenFullPlayerLyrics = Notification.Name("cassette.openFullPlayerLyrics")
    nonisolated static let cassetteSelectAlbums = Notification.Name("cassette.selectAlbums")
    nonisolated static let cassetteNavigateToAlbum    = Notification.Name("cassetteNavigateToAlbum")
    nonisolated static let cassetteNavigateToArtist   = Notification.Name("cassetteNavigateToArtist")
    nonisolated static let cassetteNavigateToPlaylist = Notification.Name("cassetteNavigateToPlaylist")
    nonisolated static let cassettePlaylistDeleted    = Notification.Name("cassette.playlistDeleted")
    /// Posted after server credentials are saved or the active server changes — clients should drop cached API sessions and Home should reload.
    nonisolated static let cassetteServerCredentialsChanged = Notification.Name("cassette.serverCredentialsChanged")
    /// Posted after a star/unstar or favorites sync so Library can refresh the top Favorites shelf.
    nonisolated static let cassetteFavoritesChanged = Notification.Name("cassette.favoritesChanged")
    /// AirPlay / route picker sheet is about to appear — pause Apple Translation so it can’t fight the picker or underrun audio.
    nonisolated static let cassetteRoutePickerWillPresent = Notification.Name("cassette.routePickerWillPresent")
    /// Route picker sheet dismissed — safe to resume a deferred translation.
    nonisolated static let cassetteRoutePickerDidDismiss = Notification.Name("cassette.routePickerDidDismiss")
}
