// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Full-bleed artist “About” page (info button on `ArtistDetailView`): photo hero, name,
/// origin / birthday / genre facts, then biography when available.
struct ArtistInfoView: View {
    let artistName: String
    let coverArtId: String
    let biography: String?
    let genres: [String]
    let musicBrainzId: String?

    @Environment(ArtworkImageCache.self) private var artworkImageCache
    @Environment(DominantColorExtractor.self) private var colorExtractor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var dominantColor: Color = .clear
    @State private var facts = ArtistProfileFacts()
    @State private var isLoadingFacts = true

    private var atmosphere: AlbumAtmosphere {
        AlbumAtmosphere.from(
            dominantColor: dominantColor,
            appearance: AlbumAtmosphere.appearance(
                colorScheme: colorScheme,
                increaseContrast: colorSchemeContrast == .increased
            )
        )
    }
    private var pageColor: Color { atmosphere.isThemed ? atmosphere.pageColor : Color.black }
    private var contentColor: Color { atmosphere.contentColor }
    private var secondaryColor: Color { atmosphere.secondaryContentColor }
    private var theme: PlaylistTheme { atmosphere.heroTheme }

    private var trimmedBio: String? {
        let text = biography?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private var hasFactRow: Bool {
        facts.origin != nil || facts.formattedBirthDate != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ImmersiveCoverHero(
                    coverArtId: coverArtId,
                    coverImage: nil,
                    theme: theme,
                    heroHeight: 360,
                    contentBelow: true,
                    fillCover: true,
                    meltTargetColor: pageColor,
                    softMelt: true
                ) {
                    Text(artistName)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(contentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, CassetteSpacing.l)
                }

                VStack(alignment: .leading, spacing: CassetteSpacing.l) {
                    if isLoadingFacts && !hasFactRow && genres.isEmpty {
                        ProgressView()
                            .tint(secondaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        factsGrid
                    }

                    if let trimmedBio {
                        Text(trimmedBio)
                            .font(.body)
                            .foregroundStyle(contentColor.opacity(0.92))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.top, CassetteSpacing.s)
                    }
                }
                .padding(.horizontal, CassetteSpacing.l)
                .padding(.bottom, CassetteSpacing.xxxl)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .cassetteSoftTopScrollEdge()
        .background(pageColor.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .cassetteImmersiveStatusBar(colorScheme: atmosphere.preferredColorScheme)
        .cassetteStatusBarScrim(isLightPage: atmosphere.isLight)
        #endif
        .environment(\.colorScheme, atmosphere.preferredColorScheme ?? colorScheme)
        .chromeAppearance(atmosphere.preferredColorScheme)
        .miniPlayerBottomMargin()
        .task(id: coverArtId) {
            let cached = colorExtractor.dominantColor(for: coverArtId, image: nil)
            if cached != .clear {
                dominantColor = cached
            } else if let image = await artworkImageCache.load(coverArtId: coverArtId, tier: .hero) {
                let color = colorExtractor.dominantColor(for: coverArtId, image: image)
                withAnimation(CassetteAnimation.theme) { dominantColor = color }
            }
        }
        .task(id: "\(musicBrainzId ?? "")|\(artistName)") {
            await loadFacts()
        }
    }

    @ViewBuilder
    private var factsGrid: some View {
        let origin = facts.origin
        let birthday = facts.formattedBirthDate
        let showOrigin = origin != nil
        let showBirthday = birthday != nil
        let showGenre = !genres.isEmpty

        if showOrigin || showBirthday || showGenre {
            VStack(alignment: .leading, spacing: CassetteSpacing.l) {
                if showOrigin || showBirthday {
                    HStack(alignment: .top, spacing: CassetteSpacing.l) {
                        if let origin {
                            factColumn(
                                label: String(localized: "Origin", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                value: {
                                    Text(origin)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(contentColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            )
                        }
                        if let birthday {
                            factColumn(
                                label: String(localized: "Birthday", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                                value: {
                                    Text(birthday)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(contentColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            )
                        }
                    }
                }

                if showGenre {
                    VStack(alignment: .leading, spacing: CassetteSpacing.s) {
                        Text(String(localized: "Genre", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.subheadline)
                            .foregroundStyle(secondaryColor)
                        FlowGenrePills(genres: genres, contentColor: contentColor)
                    }
                }
            }
        }
    }

    private func factColumn<Value: View>(
        label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(secondaryColor)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadFacts() async {
        isLoadingFacts = true
        defer { isLoadingFacts = false }
        let enrich = UserDefaults.standard.object(forKey: AppleMusicSettings.enrichKey) as? Bool ?? true
        guard enrich else { return }
        facts = await ExternalDescriptionService.shared.artistProfileFacts(
            artistName: artistName,
            musicBrainzId: musicBrainzId
        )
    }
}

// MARK: - Genre pills

private struct FlowGenrePills: View {
    let genres: [String]
    let contentColor: Color

    var body: some View {
        HStack(spacing: CassetteSpacing.s) {
            ForEach(genres, id: \.self) { genre in
                Text(genre)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(contentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(contentColor.opacity(0.12), in: Capsule())
            }
        }
    }
}
