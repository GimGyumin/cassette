import Foundation
import SwiftUI
import SwiftSonic
import ImageIO
import Testing
@testable import Cassette

/// Captures the actual reusable components for visual inspection. This is separate from
/// iOS navigation/UI automation; its result is a component preview, not a device screenshot.
@Suite("Home and Discover component capture") @MainActor
struct HomeDiscoveryPresentationTests {
    @Test func captureDarkComponentLayouts() throws {
        let container = try AppContainer(inMemory: true)
        let discovery = VStack(alignment: .leading, spacing: 28) {
            Text("Discover").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                HomeShelfHeading(title: "Stations for You")
                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { index in
                        RecommendedStationCard(artist: ArtistID3(id: "preview-\(index)", name: "Artist \(index + 1)"), index: index)
                    }
                }.frame(width: 370, alignment: .leading).clipped()
            }
            SmartShuffleBanner(albums: (0..<3).map { AlbumID3(id: "preview-\($0)", name: "Preview", songCount: 1, duration: 180) }, action: {})
            VStack(alignment: .leading, spacing: 12) {
                HomeShelfHeading(title: "Moods")
                HStack(alignment: .top, spacing: 12) {
                    MoodPlaylistCard(kind: .focus)
                    MoodPlaylistCard(kind: .chill)
                    MoodPlaylistCard(kind: .getUp)
                }.frame(width: 370, alignment: .leading).clipped()
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(width: 402, height: 960, alignment: .topLeading)
        .background(.black).environment(\.colorScheme, .dark)
        .environment(container.artworkImageCache).environment(\.appContainer, container)
        let home = VStack(alignment: .leading, spacing: 28) {
            Text("Home").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                HomeShelfHeading(title: "Your Playlists", showsChevron: true)
                HStack(alignment: .top, spacing: 12) {
                    PersonalMixCard(mix: PersonalMix(kind: .getUp, tracks: [], artistNames: []))
                    PersonalMixCard(mix: PersonalMix(kind: .focus, tracks: [], artistNames: []))
                }.frame(width: 370, alignment: .leading).clipped()
            }
            HomeShelfHeading(title: "Your Favorite Songs", showsChevron: true)
            HomeShelfHeading(title: "Recently Played", showsChevron: true)
            Spacer(minLength: 0)
        }
        .padding(16).frame(width: 402, height: 700, alignment: .topLeading)
        .background(.black).environment(\.colorScheme, .dark)
        .environment(container.artworkImageCache).environment(\.appContainer, container)
        try export(discovery, to: "/tmp/cassette-discover-components.png")
        try export(home, to: "/tmp/cassette-home-components.png")
    }

    private func export<Content: View>(_ view: Content, to path: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let url = URL(fileURLWithPath: path)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
