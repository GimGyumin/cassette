// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Tall portrait card for Home “Made for You” personal mixes.
struct PersonalMixCard: View {
    let mix: PersonalMix

    static let cardWidth: CGFloat = 168
    static let cardHeight: CGFloat = 230

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(hex: mix.kind.gradientHexes.top),
                    Color(hex: mix.kind.gradientHexes.bottom)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: String.LocalizationValue(mix.kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

                Spacer(minLength: CassetteSpacing.m)

                if !mix.artistNames.isEmpty {
                    Text(mix.artistNames.joined(separator: ", "))
                        .font(.cassetteCaption)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(CassetteSpacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.large, style: .continuous))
        .accessibilityLabel(Text(String(localized: String.LocalizationValue(mix.kind.localizationKey), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)))
        .accessibilityHint(Text(String(localized: "Open playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)))
    }
}

/// Horizontal shelf of personal mix portrait cards.
struct PersonalMixShelf: View {
    let mixes: [PersonalMix]

    var body: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text(String(localized: "Made for You", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteSectionTitle)

            ScrollView(.horizontal, showsIndicators: false) {
                // Eager HStack (≤5 cards) — LazyHStack in a horizontal ScrollView often reports
                // height 0 during rotation / background, which triggers UIKit “Conversion error!”
                // with frames like {{0,1024},{1366,0}}.
                HStack(spacing: CassetteSpacing.m) {
                    ForEach(mixes) { mix in
                        NavigationLink(value: HomeDestination.personalMix(mix.kind)) {
                            PersonalMixCard(mix: mix)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: PersonalMixCard.cardHeight)
                .padding(.vertical, 1)
            }
            .frame(height: PersonalMixCard.cardHeight + 2)
            .clipped()
        }
    }
}
