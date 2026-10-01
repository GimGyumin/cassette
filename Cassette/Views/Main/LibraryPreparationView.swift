// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Shown over the app while the server-reported library change is applied: the local index is
/// rebuilt, album artwork is reconciled, and catalog-derived caches are dropped.
///
/// Indexing can continue after dismissal; bulk artwork is deferred at the next batch boundary.
struct LibraryPreparationView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preparation: LibraryPreparationService? {
        container?.libraryPreparationService
    }

    private var phase: LibraryPreparationPhase {
        preparation?.phase ?? .checking
    }

    var body: some View {
        ZStack {
            SetupBackground()

            ScrollView {
                VStack(spacing: 30) {
                    Spacer(minLength: 32)

                    ZStack {
                        Circle()
                            .fill(Color.cassetteAccent.opacity(0.14))
                            .frame(width: 112, height: 112)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Color.cassetteAccent)
                    }

                    VStack(spacing: 10) {
                        Text(String(localized: "Updating your library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text(bodyCopy)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        preparationRow(
                            title: String(localized: "Library indexing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            complete: phaseAtOrPast(.covers)
                        )
                        preparationRow(
                            title: String(localized: "Album covers and background colors", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            complete: phaseAtOrPast(.syncing),
                            detail: coverProgress
                        )
                        preparationRow(
                            title: String(localized: "Syncing your library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            complete: phase == .complete
                        )
                    }
                    .frame(maxWidth: 440, alignment: .leading)

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(String(localized: "Download Later", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                container?.libraryPreparationService.deferPresentation()
                container?.albumCoverPreloadService.deferRemainingDownloads()
            }
            .buttonStyle(SetupPrimaryButtonStyle())
            .padding(24)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .background { SetupBackground() }
        }
    }

    private var bodyCopy: String {
        guard let count = preparation?.detectedTrackCount, count > 0 else {
            return String(localized: "New or changed music was found on your server. Cassette is re-indexing your library and preparing album artwork.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return String(
            localized: "Your server now reports \(CassetteCountLabel.tracks(count)) — Cassette is re-indexing your library and preparing album artwork.",
            bundle: AppUILanguage.localizationBundle,
            locale: AppUILanguage.locale
        )
    }

    private var coverProgress: String? {
        guard phase == .covers, let state = container?.albumCoverPreloadService.state,
              state.total > 0 else { return nil }
        return "\(state.completed) / \(state.total)"
    }

    private func phaseAtOrPast(_ target: LibraryPreparationPhase) -> Bool {
        let order: [LibraryPreparationPhase] = [.checking, .indexing, .covers, .syncing, .complete]
        guard let current = order.firstIndex(of: phase),
              let targetIndex = order.firstIndex(of: target) else { return false }
        return current >= targetIndex
    }

    private func preparationRow(title: String, complete: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(complete ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
