// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import SwiftData
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension AlbumDetailContentView {
    func albumMetadataFooter(vm: AlbumDetailViewModel, songs: [DisplayableSong]) -> some View {
        let songCount = mode == .downloadedOnly ? songs.count : max(vm.songCount, songs.count)
        let duration = mode == .downloadedOnly
            ? Int(songs.reduce(0) { $0 + $1.duration })
            : max(vm.totalDurationSeconds, Int(songs.reduce(0) { $0 + $1.duration }))

        return VStack(alignment: .leading, spacing: 0) {
            AlbumTrackDivider(color: headerTextColor.opacity(0.24))

            VStack(alignment: .leading, spacing: 5) {
                if let quality = AudioQualityClassifier.bestQuality(in: songs) {
                    albumMasteringLine(quality)
                        .padding(.bottom, CassetteSpacing.s)
                }

                if let date = ReleaseDateFormatting.displayDate(
                    from: vm.releaseDate,
                    fallbackYear: vm.year
                ) {
                    Text(verbatim: date)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(headerSecondaryColor.opacity(0.92))
                }

                if duration > 0 {
                    Text(CassetteCountLabel.songsWithDuration(
                        count: songCount,
                        durationLabel: duration.cassetteAlbumDurationLabel
                    ))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(headerSecondaryColor.opacity(0.92))
                }

                if let copyright = albumCopyrightLine(vm: vm) {
                    Text(verbatim: copyright)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(headerSecondaryColor.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.top, CassetteSpacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CassetteSpacing.l)
        .padding(.top, CassetteSpacing.xl)
        .padding(.bottom, CassetteSpacing.xl)
    }

    @ViewBuilder
    private func albumMasteringLine(_ quality: AudioQualityKind) -> some View {
        HStack(spacing: 8) {
            switch quality {
            case .dolbyAtmos, .dolby, .multichannel:
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24)
            case .hiResLossless, .lossless:
                Image("AppleLosslessMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 14)
            }

            Text(quality.title)
                .font(.system(size: 17, weight: .regular))
        }
        .foregroundStyle(headerSecondaryColor.opacity(0.88))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quality.title)
    }

    /// Copyright line for the album footer.
    ///
    /// Priority:
    /// 1. Track ID3 `copyright`/`℗` text (folds into `comment` on most servers).
    /// 2. OpenSubsonic `recordLabels` + release year.
    private func albumCopyrightLine(vm: AlbumDetailViewModel) -> String? {
        // 1. Explicit copyright text from a track comment — use verbatim.
        if let track = vm.trackCopyright?.trimmingCharacters(in: .whitespacesAndNewlines),
           !track.isEmpty {
            return track
        }

        // 2. A record label is the closest server-provided phonogram owner. Prefix it with
        // the standard ℗ mark so the fallback follows the compact album-credit treatment.
        let owner = vm.recordLabels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let owner, !owner.isEmpty else { return nil }

        let symbols = ["℗", "©", "®"]
        if symbols.contains(where: { owner.contains($0) }) {
            return owner
        }

        let year = ReleaseDateFormatting.yearOnly(from: vm.releaseDate) ?? vm.year
        if let year {
            return "℗ \(year) \(owner)"
        }
        return "℗ \(owner)"
    }

    /// Compact About blurb under the play controls (1–2 lines); full text opens in a sheet.
    func albumAboutPreview(_ description: String) -> some View {
        Button {
            showDescriptionSheet = true
        } label: {
            Text(description)
                .font(.subheadline)
                .foregroundStyle(headerTextColor.opacity(0.90))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CassetteSpacing.l)
            .padding(.top, CassetteSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(String(localized: "Show More", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
    }

    func otherVersionsSection(vm: AlbumDetailViewModel, ownsBottomInset: Bool) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text(String(localized: "Other Versions", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.cassetteSectionTitle)
                .foregroundStyle(headerTextColor)
                .padding(.horizontal, CassetteSpacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CassetteSpacing.m) {
                    ForEach(vm.otherAlbumVersions) { album in
                        NavigationLink(value: HomeDestination.album(album)) {
                            VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                                CoverArtView(id: album.coverArt ?? album.id, size: 320)
                                    .frame(width: 148, height: 148)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: CassetteCornerRadius.large,
                                            style: .continuous
                                        )
                                    )
                                Text(album.name)
                                    .font(.cassetteCellTitle)
                                    .foregroundStyle(headerTextColor)
                                    .lineLimit(2)
                                if let subtitle = AlbumVersionMatcher.editionSubtitle(for: album) {
                                    Text(subtitle)
                                        .font(.cassetteCaption)
                                        .foregroundStyle(headerSecondaryColor)
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: 148, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .albumLongPressMenu(album)
                    }
                }
                .padding(.horizontal, CassetteSpacing.l)
            }

            if ownsBottomInset {
                Color.clear
                    .frame(height: CassetteSpacing.miniPlayerBottomMargin)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, CassetteSpacing.l)
        .padding(.bottom, ownsBottomInset ? CassetteSpacing.l : CassetteSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(atmosphere.recessedSectionColor)
        .anchorPreference(key: AlbumShelfBackgroundKey.self, value: .bounds) { [$0] }
    }

    func moreByArtistSection(vm: AlbumDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
            Text(moreByTitle(vm: vm))
                .font(.cassetteSectionTitle)
                .foregroundStyle(headerTextColor)
                .padding(.horizontal, CassetteSpacing.l)

            if vm.isLoadingMoreAlbums && vm.moreAlbumsByArtist.isEmpty {
                ProgressView()
                    .tint(headerSecondaryColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CassetteSpacing.l)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: CassetteSpacing.m) {
                        ForEach(vm.moreAlbumsByArtist) { album in
                            NavigationLink(value: HomeDestination.album(album)) {
                                VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                                    CoverArtView(id: album.coverArt ?? album.id, size: 320)
                                        .frame(width: 148, height: 148)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: CassetteCornerRadius.large,
                                                style: .continuous
                                            )
                                        )
                                    Text(album.name)
                                        .font(.cassetteCellTitle)
                                        .foregroundStyle(headerTextColor)
                                        .lineLimit(2)
                                    if let year = album.year {
                                        Text(verbatim: "\(year)")
                                            .font(.cassetteCaption)
                                            .foregroundStyle(headerSecondaryColor)
                                    }
                                }
                                .frame(width: 148, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .albumLongPressMenu(album)
                        }
                    }
                    .padding(.horizontal, CassetteSpacing.l)
                }
            }

            // Reserve scroll room while the page backdrop extends this shelf's tone below it.
            Color.clear
                .frame(height: CassetteSpacing.miniPlayerBottomMargin)
                .accessibilityHidden(true)
        }
        .padding(.top, CassetteSpacing.l)
        .padding(.bottom, CassetteSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(atmosphere.recessedSectionColor)
        .anchorPreference(key: AlbumShelfBackgroundKey.self, value: .bounds) { [$0] }
    }

    private func moreByTitle(vm: AlbumDetailViewModel) -> String {
        if let name = vm.artistName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return String(localized: "More by \(name)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return String(localized: "More by Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}
