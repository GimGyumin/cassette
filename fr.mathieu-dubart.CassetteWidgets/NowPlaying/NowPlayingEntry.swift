// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import WidgetKit

nonisolated struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let track: SharedTrackInfo?
    let isPlaying: Bool
    let coverImage: PlatformImage?
    let dominantColor: Color

    static var placeholder: NowPlayingEntry {
        NowPlayingEntry(
            date: Date(),
            track: SharedTrackInfo(id: "preview", title: "Track Title", artist: "Artist Name", albumID: nil, coverArtFilename: nil),
            isPlaying: true,
            coverImage: nil,
            dominantColor: Color("CassetteAccent")
        )
    }

    static var empty: NowPlayingEntry {
        NowPlayingEntry(date: Date(), track: nil, isPlaying: false, coverImage: nil, dominantColor: Color("CassetteAccent"))
    }
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = makeEntry()
        // Short fallback refresh; track changes also call reloadTimelines from the app.
        let nextUpdate = Date().addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func makeEntry() -> NowPlayingEntry {
        guard let data = SharedStorage.read({ $0.data(forKey: SharedStorageKey.nowPlayingState.rawValue) }),
              let state = try? JSONDecoder().decode(SharedNowPlayingState.self, from: data) else {
            return .empty
        }

        let coverArtId = state.track?.coverArtFilename?.replacingOccurrences(of: ".jpg", with: "")
        let dominantColor = SharedWidgetData.dominantColor(forCoverArtId: coverArtId)
        let coverImage = coverArtId.flatMap { SharedWidgetData.image(forCoverArtId: $0) }

        return NowPlayingEntry(
            date: Date(),
            track: state.track,
            isPlaying: state.isPlaying,
            coverImage: coverImage,
            dominantColor: dominantColor
        )
    }
}
