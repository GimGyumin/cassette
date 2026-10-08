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

        return VStack(alignment: .leading, spacing: 2) {
                if let mastering = albumMasteringPresentation(songs: songs) {
                    albumMasteringLine(mastering)
                        .padding(.bottom, 14)
                }

                if let date = ReleaseDateFormatting.displayDate(
                    from: vm.releaseDate,
                    fallbackYear: vm.year
                ) {
                    Text(verbatim: date)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(headerSecondaryColor)
                }

                if duration > 0 {
                    Text(CassetteCountLabel.songsWithDuration(
                        count: songCount,
                        durationLabel: duration.cassetteAlbumDurationLabel
                    ))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(headerSecondaryColor)
                }

                if let copyright = albumCopyrightLine(vm: vm) {
                    Text(verbatim: copyright)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(headerSecondaryColor)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 0)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CassetteSpacing.xl)
        .padding(.top, 20)
        .padding(.bottom, 36)
    }

    private struct AlbumMasteringPresentation {
        enum Mark {
            case spatial
            case lossless
        }

        let title: String
        let mark: Mark
    }

    /// Apple Music shows an Apple Digital Master credit when the source metadata carries
    /// that mastering flag; otherwise the footer presents the best available audio quality.
    private func albumMasteringPresentation(songs: [DisplayableSong]) -> AlbumMasteringPresentation? {
        let isAppleDigitalMaster = songs.contains { song in
            let metadata = [song.comment, song.genre]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return metadata.contains("apple digital master")
                || metadata.contains("apple digital masters")
                || metadata.contains("mastered for itunes")
        }

        if isAppleDigitalMaster {
            let label = AppLanguage.current == .korean
                ? "Apple 디지털 마스터"
                : "Apple Digital Master"
            return AlbumMasteringPresentation(title: label, mark: .lossless)
        }

        let qualities = AudioQualityClassifier.albumQualities(in: songs)
        // The footer describes the delivered master. Prefer the lossless master here;
        // the header already carries the separate Dolby/Spatial availability badge.
        guard let quality = qualities.first(where: {
            switch $0 {
            case .lossless, .hiResLossless: return true
            case .dolbyAtmos, .dolby, .multichannel: return false
            }
        }) ?? qualities.first else { return nil }
        let mark: AlbumMasteringPresentation.Mark
        switch quality {
        case .dolbyAtmos, .dolby, .multichannel:
            mark = .spatial
        case .hiResLossless, .lossless:
            mark = .lossless
        }
        return AlbumMasteringPresentation(title: quality.title, mark: mark)
    }

    @ViewBuilder
    private func albumMasteringLine(_ presentation: AlbumMasteringPresentation) -> some View {
        HStack(spacing: 6) {
            switch presentation.mark {
            case .spatial:
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 25)
            case .lossless:
                Image("AppleLosslessMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 25, height: 14)
            }

            Text(presentation.title)
                .font(.system(size: 17, weight: .regular))
        }
        .foregroundStyle(headerSecondaryColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.title)
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
            return appleStyleCopyright(track)
        }

        // 2. A record label is the closest server-provided phonogram owner. Prefix it with
        // the standard ℗ mark so the fallback follows the compact album-credit treatment.
        let owner = vm.recordLabels.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let owner, !owner.isEmpty else { return nil }

        let symbols = ["℗", "©", "®"]
        if symbols.contains(where: { owner.contains($0) }) {
            return appleStyleCopyright(owner)
        }

        let year = ReleaseDateFormatting.yearOnly(from: vm.releaseDate) ?? vm.year
        if let year {
            return "℗ \(year) \(owner)"
        }
        return "℗ \(owner)"
    }

    /// Normalize common ID3 spellings to the glyph treatment used by Music while retaining
    /// the label's original dates, owner names and intentional line breaks.
    private func appleStyleCopyright(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = trimmed.lowercased()
                if lowered.hasPrefix("(p)") {
                    let suffix = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    return suffix.isEmpty ? "℗" : "℗ \(suffix)"
                }
                if lowered.hasPrefix("p ") {
                    return "℗ " + trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                }
                if lowered.hasPrefix("(c)") {
                    let suffix = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    return suffix.isEmpty ? "©" : "© \(suffix)"
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
        VStack(alignment: .leading, spacing: CassetteSpacing.m) {
            Text(String(localized: "Other Versions", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(headerTextColor)
                .padding(.horizontal, CassetteSpacing.l)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CassetteSpacing.m) {
                    ForEach(vm.otherAlbumVersions) { album in
                        DetailNavigationLink(destination: HomeDestination.albumPush(id: album.id, name: album.name,
                                                                         coverArtId: album.coverArt, token: albumRouteToken)) {
                            VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                                CoverArtView(id: album.coverArt ?? album.id, size: 320)
                                    .frame(width: 148, height: 148)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: CassetteCornerRadius.standard,
                                            style: .continuous
                                        )
                                    )
                                Text(album.name)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(headerTextColor)
                                    .lineLimit(2)
                                if let subtitle = AlbumVersionMatcher.editionSubtitle(for: album) {
                                    Text(subtitle)
                                        .font(.system(size: 15, weight: .regular))
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
        .padding(.top, CassetteSpacing.xxxl)
        .padding(.bottom, ownsBottomInset ? CassetteSpacing.l : CassetteSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func moreByArtistSection(vm: AlbumDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.m) {
            HStack(spacing: 4) {
                Text(moreByTitle(vm: vm))
                    .font(.system(size: 20, weight: .bold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(headerSecondaryColor.opacity(0.72))
            }
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
                            DetailNavigationLink(destination: HomeDestination.albumPush(id: album.id, name: album.name,
                                                                             coverArtId: album.coverArt, token: albumRouteToken)) {
                                VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                                    CoverArtView(id: album.coverArt ?? album.id, size: 320)
                                        .frame(width: 148, height: 148)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: CassetteCornerRadius.standard,
                                                style: .continuous
                                            )
                                        )
                                    Text(album.name)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(headerTextColor)
                                        .lineLimit(2)
                                    if let year = album.year {
                                        Text(verbatim: "\(year)")
                                            .font(.system(size: 15, weight: .regular))
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
        .padding(.top, CassetteSpacing.xxxl)
        .padding(.bottom, CassetteSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moreByTitle(vm: AlbumDetailViewModel) -> String {
        if let name = vm.artistName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return String(localized: "More by \(name)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return String(localized: "More by Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}
