// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Full-screen "cannot reach the server" state for the tabs that need the server to show anything.
///
/// Library, Downloads and Search deliberately never show this: they read the local index and the
/// download store, so they stay useful — Search falls back to those same sources — while the server
/// is away. Recovery is automatic (`ServerReachabilityMonitor` re-pings every few seconds while it is
/// down), so the button only short-circuits that wait.
struct ServerUnreachableView: View {
    @Environment(\.appContainer) private var container
    @State private var isRetrying = false

    private var serverName: String? {
        guard let name = container?.serverState.activeServer?.displayName, !name.isEmpty else { return nil }
        return name
    }

    /// The device lost its route entirely — a different sentence from "the server is not answering".
    private var isDeviceOffline: Bool {
        container?.serverState.isOnline == false
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        VStack(spacing: CassetteSpacing.l) {
            Image(systemName: isDeviceOffline ? "wifi.slash" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(.largeTitle, design: .default).weight(.light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: CassetteSpacing.s) {
                Text(localized(isDeviceOffline ? "No Internet Connection" : "Cannot Reach Server"))
                    .font(.cassetteSectionTitle)
                    .multilineTextAlignment(.center)

                Text(localized(isDeviceOffline
                               ? "This device is not connected to a network. Connect to Wi-Fi or cellular data to load your library."
                               : "Cassette can't reach your music server. Check your network connection and that the server is running."))
                    .font(.cassetteBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                if let serverName {
                    Text(serverName)
                        .font(.cassetteCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Button {
                retry()
            } label: {
                HStack(spacing: CassetteSpacing.s) {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(localized("Try Again"))
                        .font(.cassetteCellTitle)
                }
                .padding(.horizontal, CassetteSpacing.xl)
                .padding(.vertical, CassetteSpacing.m)
            }
            .cassetteAccentGlassButton(disabled: isRetrying)
            .disabled(isRetrying)

            Text(localized("Your downloads are still available in Library › Downloads."))
                .font(.cassetteCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(CassetteSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            // A successful ping clears `ServerState.isServerReachable`, which swaps this view out —
            // the short sleep only keeps the spinner from flashing for a single frame.
            await container?.serverReachabilityMonitor.checkNow()
            try? await Task.sleep(for: .milliseconds(350))
            isRetrying = false
        }
    }
}
