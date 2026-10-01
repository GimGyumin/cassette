// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Sort control for the Library → Songs list, bound to the caller's persisted
/// `@AppStorage("cassette.songSort")` preference (mirrors `AlbumSortMenu` / `ArtistSortMenu`).
///
/// Explicit `Button` rows — rather than a `Picker` — so the active option can show a checkmark *and*
/// its own icon, and so the "Artist" row can carry Apple Music's "A–Z" subtitle underneath its label.
struct SongSortMenu: View {
    @Binding var sort: SongSort
    /// The Songs screen places this next to the filter control, so the label is icon-only by default.
    var iconOnly: Bool = true

    var body: some View {
        Menu {
            ForEach(SongSort.allCases, id: \.self) { option in
                Button {
                    sort = option
                } label: {
                    SongMenuRowLabel(
                        title: option.label,
                        subtitle: option.subtitle,
                        systemImage: option.systemImage,
                        isSelected: sort == option
                    )
                }
            }
        } label: {
            if iconOnly {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityLabel(accessibilityLabel)
            } else {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
            }
        }
    }

    private var accessibilityLabel: String {
        String(localized: "Sort songs: \(sort.label)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}

/// One menu row: optional checkmark, option icon, label and (for "Artist") a secondary "A–Z" line.
/// Shared by `SongSortMenu` and `SongFilterMenu` so both menus render identically.
struct SongMenuRowLabel: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: CassetteSpacing.s) {
            if isSelected {
                Image(systemName: "checkmark")
            }
            Image(systemName: systemImage)
            if let subtitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle)
                        .font(.cassetteCaption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(title)
            }
        }
    }
}
