import Testing
import Foundation
import SwiftSonic
@testable import Cassette

struct ArtistAlbumCategorizerTests {
    @Test func liveSecondaryGenresAndEditionTitlesAreRecognized() throws {
        let tagged = try JSONDecoder().decode(AlbumID3.self, from: Data(#"{"id":"live","name":"Concert","songCount":12,"duration":3000,"genre":"Rock","genres":[{"name":"Rock"},{"name":"Live Album"}]}"#.utf8))
        #expect(ArtistAlbumCategorizer.classify(tagged) == .live)
        for name in ["Concert [Live]", "Concert (Live) [Remastered]", "Live from Wembley", "Live 1992", "Live"] {
            #expect(ArtistAlbumCategorizer.classify(AlbumID3(id: name, name: name, songCount: 12, duration: 3000)) == .live)
        }
        for name in ["Alive", "Live Through This", "Lives"] {
            #expect(ArtistAlbumCategorizer.classify(AlbumID3(id: name, name: name, songCount: 12, duration: 3000)) == .albums)
        }
    }

    @Test func compilationGenreAndOpenSubsonicFlagsAppearInCompilationShelf() {
        let albums = [
            AlbumID3(id: "genre", name: "Anthology", songCount: 10, duration: 100, genre: "Compilation"),
            AlbumID3(id: "flag", name: "Live Collection", songCount: 10, duration: 100, isCompilation: true),
            AlbumID3(id: "type", name: "Collection", songCount: 10, duration: 100, releaseTypes: ["album", "compilation"]),
            AlbumID3(id: "studio", name: "Studio", songCount: 10, duration: 100)
        ]
        let sections = ArtistAlbumCategorizer.sections(from: albums)
        #expect(Set(sections.first { $0.0 == .compilations }?.1.map(\.id) ?? []) == ["genre", "flag", "type"])
        #expect(sections.first { $0.0 == .albums }?.1.map(\.id) == ["studio"])
    }

    @Test func compilationShelfRemainsWhenServerOmitsClassification() {
        let sections = ArtistAlbumCategorizer.sections(from: [AlbumID3(id: "1", name: "Album", songCount: 10, duration: 100)])
        #expect(sections.contains { $0.0 == .compilations && $0.1.isEmpty })
    }

    @Test func untaggedVariousArtistsCompilationIsSeparatedFromAlbumsTab() {
        let compilation = AlbumID3(id: "various", name: "Collection", songCount: 20,
            duration: 2000, artist: "Various Artists")
        let ordinary = AlbumID3(id: "duet", name: "Duet", songCount: 8,
            duration: 1800, artist: "A & B")
        let sections = ArtistAlbumCategorizer.sections(from: [compilation, ordinary])
        #expect(sections.first { $0.0 == .compilations }?.1.map(\.id) == ["various"])
        #expect(AlbumLibraryFilter.albums.includes(ordinary))
        #expect(!AlbumLibraryFilter.albums.includes(compilation))
        #expect(AlbumLibraryFilter.compilations.includes(compilation))
        #expect(!AlbumLibraryFilter.compilations.includes(ordinary))
        #expect(AlbumLibraryFilter.all.includes(compilation))
    }

    @Test func jellyfinCompilationFlagIsPreservedByAlbumMapping() throws {
        let item = try JSONDecoder().decode(JellyfinItem.self,
            from: Data(#"{"Id":"abc","Name":"Collection","Type":"MusicAlbum","IsCompilation":true,"ChildCount":4}"#.utf8))
        let payload = JellyfinMusicTransport.album(item)
        let album = try JSONDecoder().decode(AlbumID3.self,
            from: JSONSerialization.data(withJSONObject: payload))
        #expect(album.isCompilation == true)
        #expect(ArtistAlbumCategorizer.classify(album) == .compilations)
    }
}
