// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog

// MARK: - WARNING — DO NOT add @Observable / @Query / @Bindable observations to SearchView's body
//
// SearchView owns the .navigationDestination modifiers for the entire search tab.
// Any @Observable, @Query, or @Bindable observation read in this view's body
// (including inside destination closures) will cause SearchView to re-render
// whenever that observed value mutates — for example when destinations load
// artwork or when SearchHistoryService writes to the SwiftData container.
//
// Each re-render re-evaluates all .navigationDestination closures. If SwiftUI
// treats the resulting struct change as a view identity change it discards the
// existing pushed view and inserts a new one, producing a visual layering bug
// where the wrong view appears on top during the push animation.
//
// This bug has regressed FIVE times. Do not introduce a sixth.
//
// AUDIT (2026-05-27) — SearchHistoryListView @Query cascade: confirmed root cause.
//
// SearchHistoryListView owns @Query<SearchHistoryEntry>. SwiftData's @Query
// re-evaluates whenever mainContext (modelContainer.mainContext) saves, regardless
// of which entity type changed. Two confirmed background drivers:
//
//   Driver 1 — PinService.modelContext IS mainContext. Every pin/unpin anywhere
//   in the app saves mainContext → @Query re-evaluates → SwiftData re-applies
//   all SearchHistoryEntry property values from store through @Model's @Observable
//   setters → coverArtId/serverId fire as "changed" for EVERY in-memory entry.
//
//   Driver 2 — PlaybackSessionService.savePosition() fires every 5 s during
//   playback on an actor-isolated background context. SwiftData auto-merges that
//   save into mainContext → same cascade as Driver 1.
//
// Additionally, SearchHistoryService.record() for a NEW entry merges the insert
// into mainContext, setting all @Model properties via their setters for the first
// time → observation fires once per new history entry (user-triggered).
//
// Fix direction (not applied here): isolate SearchHistoryListView from mainContext
// saves by moving it to a dedicated background context (see planned fix).
//
// Regression 1 — historyEntries @Query in SearchView body
//   Fix: extract into SearchHistoryListView child view (Option C).
// Regression 2 — artworkImageCache @Observable read in destination closures
//   Fix: AlbumDetailView reads its own @Environment(ArtworkImageCache.self).
// Regression 3 — allFavorites @Query in SearchView body
//   Fix: extract into SearchSongResultsSection child view.
// Regression 4 — @Model SearchHistoryEntry held as .navigationDestination(item:) binding
//   SwiftData @Model uses ObjectIdentifier-based Hashable; a concurrent
//   SearchHistoryService write refreshes the managed object and can invalidate the
//   reference, causing SwiftUI to treat the item as new and re-instantiate the
//   destination. Fix: SearchHistoryNavTarget (plain value struct).
// Regression 5 — .navigationDestination(item:) used for a destination that itself
//   pushes further views. The binding-based modifier is re-evaluated by iOS during
//   nested pushes, destroying and re-instantiating the source destination view even
//   when the binding item is a stable value type. Fix: always use
//   .navigationDestination(for: Type.self) backed by NavigationPath for any
//   destination that is part of a multi-level flow.
//
// The safe pattern:
// - Observations needed only for search results UI → put them in a child view.
// - Values needed by destination views → have the destination read them from
//   its own @Environment, not from a parameter passed through this body.
// - Navigation binding items → use plain value types (struct / enum), never @Model.
// - Any destination that can push further → use .navigationDestination(for:) +
//   NavigationPath, never .navigationDestination(item:).
// - Search field focus / query / ViewModel → SearchTabContent only. Never put
//   isSearchActive or search text state on the view that owns .navigationDestination
//   (focusing the field used to rebuild destinations and caused severe jank).
//
// PERFORMANCE / REGRESSION GUARD (2026-07):
// Do not add @Query, @Observable reads, or artwork-cache observation to SearchView.body
// or to any .navigationDestination closure defined here. Destination ownership must stay
// a thin shell. Violations have caused layered push bugs five times — treat as a hard rule.

/// Value-type snapshot of a SearchHistoryEntry used as the navigation binding item.
/// Using a plain struct (stable Hashable) avoids the ObjectIdentifier instability of
/// holding a @Model reference in .navigationDestination(item:) — see guard comment above.
struct SearchHistoryNavTarget: Hashable {
    let itemId: String
    let itemType: String
    let displayName: String
    let coverArtId: String?
}

struct SearchView: View {
    @Binding var path: NavigationPath
    /// Optional external query (macOS/iPad `.searchable`). When nil, query lives only in
    /// `SearchTabContent` so typing/focus never rebuilds this view’s destinations.
    private var externalSearchQuery: Binding<String>?

    @Namespace private var albumZoomNamespace
    @Environment(\.registersHomeDestinations) private var registersHomeDestinations

    init(path: Binding<NavigationPath>) {
        self._path = path
        self.externalSearchQuery = nil
    }

    init(searchQuery: Binding<String>, path: Binding<NavigationPath>) {
        self._path = path
        self.externalSearchQuery = searchQuery
    }

    var body: some View {
        // Destinations stay here. Focus / query / ViewModel live in SearchTabContent so
        // activating the field or typing does not re-evaluate .navigationDestination.
        //
        // No `container` / server-state read may happen in this body or in a destination closure: an
        // observed read re-evaluates every destination whenever the server state changes, which re-creates
        // the pushed entry (blank page, back button pointing at a removed entry). The history wrapper
        // reads the environment itself — see the guard comment at the top of this file.
        SearchTabContent(path: $path, externalSearchQuery: externalSearchQuery)
            .navigationDestination(for: ArtistID3.self) { artist in
                HistoryRecordingView(
                    itemId: artist.id, itemType: "artist",
                    displayName: artist.name, coverArtId: artist.coverArt
                ) {
                    #if os(macOS)
                    ArtistDetailMacOS(artistId: artist.id, artistName: artist.name, coverArtId: artist.coverArt)
                    #else
                    ArtistDetailView(artist: artist)
                    #endif
                }
            }
            .navigationDestination(for: AlbumID3.self) { album in
                HistoryRecordingView(
                    itemId: album.id, itemType: "album",
                    displayName: album.name, coverArtId: album.coverArt
                ) {
                    #if os(macOS)
                    AlbumDetailMacOS(albumId: album.id, albumName: album.name, coverArtId: album.coverArt)
                    #else
                    AlbumDetailView(album: album)
                    #endif
                }
            }
            .modifier(SearchHomeDestinationRegistrar(
                enabled: registersHomeDestinations,
                albumZoomNamespace: albumZoomNamespace
            ))
            .navigationDestination(for: SearchHistoryNavTarget.self) { entry in
                HistoryRecordingView(
                    itemId: entry.itemId, itemType: entry.itemType,
                    displayName: entry.displayName, coverArtId: entry.coverArtId
                ) {
                switch entry.itemType {
                case "artist":
                    #if os(macOS)
                    ArtistDetailMacOS(artistId: entry.itemId, artistName: entry.displayName, coverArtId: entry.coverArtId)
                    #else
                    ArtistDetailView(artistId: entry.itemId, artistName: entry.displayName, coverArtId: entry.coverArtId)
                    #endif
                default:
                    #if os(macOS)
                    AlbumDetailMacOS(albumId: entry.itemId, albumName: entry.displayName, coverArtId: entry.coverArtId)
                    #else
                    AlbumDetailView(albumId: entry.itemId, albumName: entry.displayName, coverArtId: entry.coverArtId)
                    #endif
                }
                }
            }
    }
}

// MARK: - History recording wrapper

/// Records the visit in `searchHistoryService` without touching a container observation inside
/// `SearchView`'s destination closures. The wrapper reads `appContainer` itself, so a server-state change
/// can never re-evaluate (and therefore re-create) the pushed destination from the stack owner's body.
private struct HistoryRecordingView<Content: View>: View {
    let itemId: String
    let itemType: String
    let displayName: String
    let coverArtId: String?

    @Environment(\.appContainer) private var container
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().task {
            guard let container,
                  let serverId = container.serverState.activeServer?.id.uuidString else { return }
            await container.searchHistoryService.record(
                itemId: itemId, itemType: itemType,
                displayName: displayName, coverArtId: coverArtId,
                serverId: serverId
            )
        }
    }
}

/// Registers `HomeDestination` for Search only when the parent stack does not already own it.
private struct SearchHomeDestinationRegistrar: ViewModifier {
    let enabled: Bool
    let albumZoomNamespace: Namespace.ID

    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: HomeDestination.self) { destination in
                switch destination {
                case .albumPush(let id, let name, let coverArtId, _):
                    AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId)
                case .album(let album):
                    AlbumDetailView(
                        album: album,
                        zoomSourceId: album.id,
                        zoomNamespace: albumZoomNamespace,
                        coverArtId: album.coverArt
                    )
                case .albumById(let id, let name, _, let coverArtId):
                    AlbumDetailView(
                        albumId: id,
                        albumName: name,
                        zoomSourceId: id,
                        zoomNamespace: albumZoomNamespace,
                        coverArtId: coverArtId
                    )
                case .artist(let artist):
                    ArtistDetailView(artist: artist)
                case .artistById(let id, let name, let coverArtId):
                    ArtistDetailView(artistId: id, artistName: name, coverArtId: coverArtId)
                case .artistPush(let id, let name, let coverArtId, _):
                    ArtistDetailView(artistId: id, artistName: name, coverArtId: coverArtId)
                default:
                    EmptyView()
                }
            }
        } else {
            content
        }
    }
}
