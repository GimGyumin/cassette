// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Source control for the Library → Songs list: All Songs / Favorites / Downloads.
///
/// Rows are explicit `Button`s so the active filter keeps both its checkmark and its icon, matching
/// the Apple Music filter menu (and `SongSortMenu`, which shares `SongMenuRowLabel`).
struct SongFilterMenu: View {
    @Binding var filter: SongListFilter

    var body: some View {
        Menu {
            ForEach(SongListFilter.allCases, id: \.self) { option in
                Button {
                    filter = option
                } label: {
                    SongMenuRowLabel(
                        title: option.label,
                        systemImage: option.systemImage,
                        isSelected: filter == option
                    )
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: String {
        String(localized: "Filter songs: \(filter.label)", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}
