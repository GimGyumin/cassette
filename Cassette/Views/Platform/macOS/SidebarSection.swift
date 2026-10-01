// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(macOS)
import Foundation

/// Sidebar IA mirrors Apple Music: Search → Home → Discover → Library, plus desktop library shortcuts.
nonisolated enum SidebarSection: String, Hashable, Identifiable, CaseIterable {
    case search
    case home
    case discover
    case library
    case recentlyAdded
    case albums
    case artists
    case playlists
    case favorites
    case downloads

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .search:    return "Search"
        case .home:      return "Home"
        case .discover:  return "Discover"
        case .library:   return "Library"
        case .recentlyAdded: return "Recently Added"
        case .albums:    return "Albums"
        case .artists:   return "Artists"
        case .playlists: return "Playlists"
        case .favorites: return "Favorites"
        case .downloads: return "Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .search:    return "magnifyingglass"
        case .home:      return "house"
        case .discover:  return "safari"
        case .library:   return "square.stack"
        case .recentlyAdded: return "clock"
        case .albums:    return "square.stack"
        case .artists:   return "music.mic"
        case .playlists: return "music.note.list"
        case .favorites: return "star"
        case .downloads: return "arrow.down.circle"
        }
    }
}

nonisolated enum SidebarDestination: Hashable {
    case section(SidebarSection)
    case pinned(String) // PinnedItem.id — "{type}:{itemId}"
}
#endif
