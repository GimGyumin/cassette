// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Combine
import SwiftUI

/// iPhone Settings → General → iPhone Storage–style cache management.
struct StorageManagementView: View {
    @Environment(\.appContainer) private var container
    @State private var viewModel: StorageManagementViewModel?
    @State private var categoryToClear: StorageCategorySnapshot?
    @State private var showResetConfirmation = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(String(localized: "Storage", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            guard viewModel == nil, let container else { return }
            let vm = StorageManagementViewModel(
                storageService: container.storageManagementService,
                onResetAll: { await container.resetCachesAndAppSettings() }
            )
            viewModel = vm
            await vm.refresh()
        }
        .onAppear {
            guard viewModel != nil else { return }
            Task { await viewModel?.refresh() }
        }
        .refreshable {
            await viewModel?.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cassetteDownloadCompleted)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
            Task { await viewModel?.refresh() }
        }
        .confirmationDialog(
            String(localized: "Clear this data?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            isPresented: Binding(
                get: { categoryToClear != nil },
                set: { if !$0 { categoryToClear = nil } }
            ),
            titleVisibility: .visible,
            presenting: categoryToClear
        ) { category in
            Button(String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                let kind = category.kind
                categoryToClear = nil
                Task { await viewModel?.clear(kind) }
            }
            Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .cancel) {
                categoryToClear = nil
            }
        } message: { category in
            Text(category.title)
        }
        .confirmationDialog(
            String(localized: "Reset all cache and settings?", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Reset", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                Task { await viewModel?.resetCachesAndSettings() }
            }
            Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .cancel) {}
        } message: {
            Text(String(localized: "Clears temporary caches and restores streaming, playback, cache, and lyrics preferences to defaults. Offline downloads and your server sign-in are not removed.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        }
    }

    @ViewBuilder
    private func content(_ viewModel: StorageManagementViewModel) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Cassette Data", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Text(viewModel.totalFormatted)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Text(String(localized: "Manage cached data used by Cassette on this device.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, CassetteSpacing.xs)
            }

            if let preload = container?.albumCoverPreloadService, !preload.state.isComplete {
                Section(String(localized: "Album Covers", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    HStack(alignment: .center, spacing: CassetteSpacing.m) {
                        SettingsIcon(systemImage: "photo.on.rectangle.angled", color: .indigo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Download all album covers", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                .font(.body)
                            Text(String(localized: "Store high-resolution artwork for your whole library.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: CassetteSpacing.s)
                        if preload.state.isDownloading {
                            if preload.state.total == 0 {
                                ProgressView()
                            } else {
                                ProgressView(value: preload.state.fraction)
                                    .frame(width: 48)
                            }
                        } else {
                            Button(String(localized: "Download", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                                Task {
                                    await preload.downloadAllCovers()
                                    await viewModel.refresh()
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 2)
                    if let error = preload.state.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if preload.state.total > 0 {
                        Text("\(preload.state.completed) / \(preload.state.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if preload.state.failed > 0 {
                        Text(String(localized: "\(preload.state.failed) covers failed", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(String(localized: "Categories", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                ForEach(viewModel.categories) { category in
                    categoryRow(category, viewModel: viewModel)
                }
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label {
                        HStack(spacing: CassetteSpacing.s) {
                            Text(String(localized: "Clear All Cache & Reset Settings", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            if viewModel.isResettingAll {
                                ProgressView()
                                    .scaleEffect(0.85)
                            }
                        }
                    } icon: {
                        SettingsIcon(systemImage: "trash.fill", color: .red)
                    }
                }
                .disabled(viewModel.isResettingAll)
            } footer: {
                Text(String(localized: "Removes temporary caches and resets app preferences. Does not delete offline downloads or remove your server account.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }
        .modifier(SettingsSubpageStyle())
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    @ViewBuilder
    private func categoryRow(
        _ category: StorageCategorySnapshot,
        viewModel: StorageManagementViewModel
    ) -> some View {
        let row = StorageCategoryRow(
            category: category,
            isClearing: viewModel.clearingKind == category.kind,
            onClear: { categoryToClear = category }
        )

        switch category.kind {
        case .audioCache:
            NavigationLink {
                Form { CacheSectionView() }
                    .formStyle(.grouped)
                    .modifier(SettingsSubpageStyle())
                    .navigationTitle(String(localized: "Cache", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            } label: {
                row
            }
        case .downloads:
            NavigationLink {
                DownloadedMusicManagementView()
            } label: {
                row
            }
        default:
            row
        }
    }
}

private struct StorageCategoryRow: View {
    let category: StorageCategorySnapshot
    let isClearing: Bool
    let onClear: () -> Void

    private var icon: (String, Color) {
        switch category.kind {
        case .audioCache: return ("waveform", .green)
        case .lyrics: return ("music.note.list", .teal)
        case .artwork: return ("photo.on.rectangle.angled", .purple)
        case .descriptions: return ("text.book.closed", .orange)
        case .translations: return ("character.book.closed", .blue)
        case .discover: return ("sparkles", .pink)
        case .downloads: return ("arrow.down.circle.fill", Color.cassetteAccent)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: CassetteSpacing.m) {
            SettingsIcon(systemImage: icon.0, color: icon.1)

            VStack(alignment: .leading, spacing: 3) {
                Text(category.title)
                    .font(.body)
                if let subtitle = category.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let count = category.itemCount {
                    Text(itemCountLabel(count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: CassetteSpacing.s)

            Text(category.formattedSize)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if isClearing {
                ProgressView()
                    .scaleEffect(0.8)
            } else if category.byteCount > 0 {
                Button(String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    onClear()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func itemCountLabel(_ count: Int) -> String {
        switch category.kind {
        case .audioCache, .downloads:
            return String(localized: "\(count) items", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .lyrics:
            return String(localized: "\(count) songs", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        default:
            return ""
        }
    }
}
