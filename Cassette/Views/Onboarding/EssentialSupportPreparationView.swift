// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import SwiftUI

/// Deferrable one-time preparation shown immediately after the first server sign-in.
/// It warms the authenticated client and indexes the library before Home is presented.
/// Full artwork preparation runs here only when the user has enabled it.
struct EssentialSupportPreparationView: View {
    let onComplete: () -> Void
    let onReconnect: () -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preparationAttempt = 0
    @State private var hasContinued = false

    private var preload: AlbumCoverPreloadService? {
        container?.albumCoverPreloadService
    }

    private var hasActiveServer: Bool { container?.serverState.activeServer != nil }

    private var libraryIndex: LibraryIndexService? { container?.libraryIndexService }

    private var preparationError: String? {
        guard hasActiveServer else { return CassetteError.serverNotConfigured.localizedDescription }
        if let error = libraryIndex?.lastError { return error.displayMessage }
        return BulkArtworkPreference.isEnabled ? preload?.state.errorMessage : nil
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
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(Color.cassetteAccent)
                }

                VStack(spacing: 10) {
                    Text(String(localized: "Preparing Cassette", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(BulkArtworkPreference.isEnabled
                        ? String(localized: "Downloading album artwork and preparing page colors for your first listening session.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                        : String(localized: "Preparing your library for fast local search.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 18) {
                    preparationRow(
                        title: String(localized: "Server connection", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        complete: container?.serverState.activeServer != nil
                    )
                    preparationRow(
                        title: String(localized: "Library information", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        complete: libraryIndex?.hasUsableIndex == true
                    )
                    if BulkArtworkPreference.isEnabled {
                        preparationRow(
                            title: String(localized: "Album covers and background colors", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            complete: preload?.state.isComplete == true
                        )
                    }
                    preparationRow(
                        title: String(localized: "Library indexing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                        complete: libraryIndex?.hasUsableIndex == true
                    )

                    if BulkArtworkPreference.isEnabled {
                        ProgressView(value: preload?.state.fraction ?? 0)
                            .progressViewStyle(.linear)
                            .tint(Color.cassetteAccent)
                    }

                    if libraryIndex?.isIndexing == true {
                        ProgressView(value: libraryIndex?.progress ?? 0)
                            .progressViewStyle(.linear)
                            .tint(Color.cassetteAccent)
                    }

                    HStack {
                        Text(progressText)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if preload?.state.isDownloading == true {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(22)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(maxWidth: 520)

                if let error = preparationError, !error.isEmpty,
                   preload?.state.isDownloading != true {
                    VStack(spacing: 12) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        if hasActiveServer {
                            Button(String(localized: "Try Again", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                                preparationAttempt += 1
                            }
                            .buttonStyle(SetupPrimaryButtonStyle())

                        } else {
                            Button(String(localized: "Sign In", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), action: onReconnect)
                                .buttonStyle(SetupPrimaryButtonStyle())
                        }
                    }
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if hasActiveServer {
                VStack(spacing: 8) {
                    Button(String(localized: "Download Later", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), action: deferPreparation)
                        .buttonStyle(SetupPrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.preparation.downloadLater")
                        .disabled(hasContinued)
                    Text(String(localized: "Preparation continues in the background. Check progress in Account.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .background { SetupBackground() }
            }
        }
        .task(id: preparationAttempt) { await prepare() }
    }

    private var progressText: String {
        if !BulkArtworkPreference.isEnabled {
            return libraryIndex?.isPreparing == true
                ? String(localized: "Library indexing", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Preparing Cassette", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        guard let state = preload?.state else {
            return String(localized: "Connecting…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        if state.total == 0 {
            return state.isComplete
                ? String(localized: "Preparation complete", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                : String(localized: "Loading library…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return "\(state.completed) / \(state.total)"
    }

    private func preparationRow(title: String, complete: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(complete ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func prepare() async {
        guard let container, hasActiveServer, !Task.isCancelled, !hasContinued else { return }
        if BulkArtworkPreference.isEnabled && container.albumCoverPreloadService.isDeferred {
            deferPreparation()
            return
        }
        await container.serverService.preWarmClient()
        guard !hasContinued, !Task.isCancelled, hasActiveServer else { return }
        if BulkArtworkPreference.isEnabled {
            await container.albumCoverPreloadService.downloadAllCovers()
        }
        guard !hasContinued, !Task.isCancelled, hasActiveServer else { return }
        let indexReady = await container.indexLibraryForOnboarding()

        guard !hasContinued, !Task.isCancelled, hasActiveServer,
              indexReady,
              !BulkArtworkPreference.isEnabled || container.albumCoverPreloadService.state.isComplete else { return }
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(350))
        }
        guard !Task.isCancelled, !hasContinued else { return }
        hasContinued = true
        onComplete()
    }

    @MainActor
    private func deferPreparation() {
        guard let container, hasActiveServer, !hasContinued else { return }
        hasContinued = true
        container.libraryPreparationService.deferPresentation()
        if BulkArtworkPreference.isEnabled {
            container.albumCoverPreloadService.deferRemainingDownloads()
        }
        // The index owns its task and can finish after this view disappears.
        container.libraryIndexService.ensureIndexed(using: container.libraryService)
        onComplete()
    }
}
