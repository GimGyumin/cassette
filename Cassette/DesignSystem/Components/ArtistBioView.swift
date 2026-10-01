// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct ArtistBioView: View {
    let bio: String
    let lastFmURL: URL?
    /// Body text colour. Defaults to `.secondary` (over the solid body); the hero passes a
    /// themed colour so the bio reads over the cover.
    var textColor: Color = .secondary
    /// Colour of the "Show more" / Last.fm controls.
    var linkColor: Color = .secondary
    /// When true the bio centres itself (hero placement over the cover) instead of left-aligning.
    var centered: Bool = false
    /// Notifies the parent when the expand state flips (the hero uses it to grow downward, not upward).
    var onExpandedChange: (Bool) -> Void = { _ in }

    @State private var expanded = false
    @Environment(\.openURL) private var openURL

    /// Only offer the toggle when there is enough text to overflow three lines.
    private var isLong: Bool { bio.count > 140 }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: CassetteSpacing.s) {
            JustifiedText(text: bio, lineLimit: expanded ? 0 : 3, color: textColor)

            HStack(spacing: CassetteSpacing.m) {
                if isLong {
                    Button(expanded ? "Show less" : "Show more") {
                        let willExpand = !expanded
                        // Freeze the collapsed baseline BEFORE the layout grows, so the top inset stays put.
                        onExpandedChange(willExpand)
                        withAnimation(.easeInOut(duration: 0.3)) { expanded = willExpand }
                    }
                    .font(.cassetteCaption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(linkColor)
                }

                if !centered { Spacer() }

                if let lastFmURL {
                    Button { openURL(lastFmURL) } label: {
                        Label("Last.fm", systemImage: "arrow.up.right")
                            .font(.cassetteCaption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(linkColor)
                }
            }
        }
    }
}

/// A 4-line placeholder shown while the bio loads (≈ three clamped lines plus the Show-more row), so the
/// area reserves height and the bio fades in (resizing if shorter) instead of popping — mirroring the
/// similar-artists skeleton.
struct ArtistBioSkeleton: View {
    var centered: Bool = false
    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: CassetteSpacing.s) {
            SkeletonBlock(height: 13)
            SkeletonBlock(height: 13)
            SkeletonBlock(height: 13)
            SkeletonBlock(width: 200, height: 13)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

