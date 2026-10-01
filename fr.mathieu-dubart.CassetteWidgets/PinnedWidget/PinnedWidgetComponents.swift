// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Apple Music Pins–style tile: square art for albums/songs/playlists, circle for artists.
struct PinnedTileView: View {
    let item: SharedPinnedItem
    let image: PlatformImage?
    var coverSize: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
                .frame(width: coverSize, height: coverSize)

            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: coverSize, alignment: .leading)

            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: coverSize, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let content = Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.primary.opacity(0.08)
                    Image(systemName: placeholderIcon)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if item.kind == .artist {
            content.clipShape(Circle())
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var placeholderIcon: String {
        switch item.kind {
        case .playlist: "music.note.list"
        case .artist: "person.fill"
        case .song: "music.note"
        case .album: "square.stack"
        }
    }
}
