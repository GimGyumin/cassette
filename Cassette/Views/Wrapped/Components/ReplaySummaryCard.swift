// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Compact Discover Replay teaser — listening summary instead of yearly widget cards.
struct ReplaySummaryCard: View {
    let data: WrappedData?
    var isLoading: Bool = false

    private var year: Int {
        data?.period.calendarYear ?? Calendar.current.component(.year, from: Date())
    }

    private var periodLabel: String {
        guard let data else { return String(localized: "This month", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) }
        switch data.period {
        case .month(_, let month):
            var components = DateComponents()
            components.month = month
            let date = Calendar.current.date(from: components) ?? Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM"
            formatter.locale = .current
            return formatter.string(from: date)
        case .year(let y):
            return String(y)
        }
    }

    var body: some View {
        let palette = WrappedYearPalette.colors(for: year)
        ZStack(alignment: .leading) {
            MeshGradientBackground(palette: palette, animated: false)
            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            Group {
                if isLoading && data == nil {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let data, data.totalTracksPlayed > 0 {
                    summaryContent(data)
                } else {
                    emptyContent
                }
            }
            .padding(CassetteSpacing.l)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: CassetteCornerRadius.hero, style: .continuous))
    }

    private func summaryContent(_ data: WrappedData) -> some View {
        let (number, unit) = data.totalSecondsListened.wrappedHeroFormat()
        return VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
            Text(periodLabel)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }

            HStack(spacing: CassetteSpacing.xs) {
                Text(data.totalTracksPlayed.plural("play", "plays"))
                Text("·").foregroundStyle(.white.opacity(0.45))
                Text(data.totalUniqueArtists.plural("artist", "artists"))
                Text("·").foregroundStyle(.white.opacity(0.45))
                Text(data.totalUniqueAlbums.plural("album", "albums"))
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
            Text(String(localized: "Replay", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Text(String(localized: "Listen up — Replay will keep track of your activity.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
