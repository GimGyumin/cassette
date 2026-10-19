// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A square, locally rendered cover; every surface uses the same mix identity and palette.
struct PersonalMixArtwork: View {
    let kind: PersonalMixKind
    var showsTitle = true
    var showsSymbol = false

    private var symbol: String {
        switch kind {
        case .getUp: "figure.run"
        case .chill: "moon.stars.fill"
        case .focus: "sparkles"
        case .newMusic: "music.note"
        case .heavyRotation: "repeat"
        case .essentials: "star.fill"
        }
    }

    private var colors: [Color] {
        if kind == .getUp {
            return ["#FF9164", "#F9AD51", "#DF5379", "#EF6A55", "#82BBD4", "#F4915A", "#AF242A", "#5964AB", "#F57B39"].map { Color(hex: $0) }
        }
        let top = Color(hex: kind.gradientHexes.top), bottom = Color(hex: kind.gradientHexes.bottom)
        return [top.adjusted(hue: -0.10, brightness: 0.12), top, top.adjusted(hue: 0.16),
                top.adjusted(hue: 0.20), bottom.adjusted(brightness: 0.18), top,
                bottom, bottom.adjusted(hue: 0.15), bottom]
    }

    var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.5, 0.5], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                colors: colors)
            if showsSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(.white)
            } else if showsTitle {
                VStack(alignment: .leading) {
                    Text("Cassette")
                        .font(.headline.bold())
                    Spacer(minLength: 16)
                    Text(String(localized: String.LocalizationValue(kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.system(.largeTitle, weight: .bold))
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

struct PersonalMixCard: View {
    let mix: PersonalMix
    static let cardWidth: CGFloat = 250
    static let cardHeight: CGFloat = 324

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PersonalMixArtwork(kind: mix.kind)
                .frame(width: Self.cardWidth, height: Self.cardWidth)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(String(localized: String.LocalizationValue(mix.kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Updated \(mix.updatedAt.formatted(.relative(presentation: .named)))", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                Text(CassetteCountLabel.tracks(mix.tracks.count))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(width: Self.cardWidth, alignment: .leading)
        .accessibilityHint(Text("Open playlist"))
    }
}

/// Compatibility shelf; generated mixes navigate to PlaylistDetailView via HomeDestination.
struct PersonalMixShelf: View {
    let mixes: [PersonalMix]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Playlists").font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(mixes) { mix in
                        NavigationLink(value: HomeDestination.personalMix(mix.kind)) { PersonalMixCard(mix: mix) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
