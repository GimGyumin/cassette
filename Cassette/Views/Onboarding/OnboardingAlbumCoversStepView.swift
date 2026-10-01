// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Onboarding step that downloads full-resolution cover art for the entire library.
/// The download starts automatically so the user can simply continue once it finishes
/// (or skip and let covers lazy-load on demand later).
struct OnboardingAlbumCoversStepView: View {
    let onSkip: () -> Void
    let onContinue: () -> Void
    let onReconnect: () -> Void

    @Environment(\.appContainer) private var container
    @State private var downloadAttempt = 0

    private var hasActiveServer: Bool { container?.serverState.activeServer != nil }

    var body: some View {
        OnboardingStepView(
            icon: "square.stack.3d.up.fill",
            title: String(localized: "Album Covers", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            subtitle: String(localized: "Download high-resolution cover art for your whole library so every page looks its best.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            stepIndex: 1,
            totalSteps: 4,
            onSkip: {
                guard hasActiveServer else { onReconnect(); return }
                container?.albumCoverPreloadService.deferRemainingDownloads()
                container?.libraryPreparationService.deferPresentation()
                onSkip()
            },
            onContinue: { if hasActiveServer { onContinue() } else { onReconnect() } },
            skipTitle: String(localized: "Download Later", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        ) {
            if let service = container?.albumCoverPreloadService {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        if service.state.isDownloading {
                            ProgressView(value: service.state.fraction)
                                .progressViewStyle(.linear)
                                .tint(.purple)
                            Text(String(localized: "Downloading covers…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if service.state.isComplete && hasActiveServer {
                            Label {
                                Text(String(localized: "All album covers downloaded", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .font(.body)
                        } else {
                            Label {
                                Text(String(localized: "Album covers and background colors", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            } icon: {
                                SettingsIcon(systemImage: "square.stack.3d.up.fill", color: .purple)
                            }
                        }

                        if !service.state.isDownloading && (!service.state.isComplete || !hasActiveServer) {
                            Button {
                                if container?.serverState.activeServer == nil { onReconnect() }
                                else { downloadAttempt += 1 }
                            } label: {
                                Text(String(localized: "Download Now", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SetupPrimaryButtonStyle())
                        }

                        if !hasActiveServer {
                            Text(CassetteError.serverNotConfigured.localizedDescription)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let error = service.state.errorMessage, !service.state.isDownloading {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if service.state.total > 0 {
                            Text("\(service.state.completed) / \(service.state.total)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text(String(localized: "Covers are stored in the Artwork Cache. You can clear them anytime from Settings → Storage. Album art changes are detected automatically.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task(id: downloadAttempt) {
            // The preparation step may already have completed this pass.
            guard let container, container.serverState.activeServer != nil,
                  !container.albumCoverPreloadService.state.isComplete else { return }
            await container.albumCoverPreloadService.downloadAllCovers()
        }
    }
}
