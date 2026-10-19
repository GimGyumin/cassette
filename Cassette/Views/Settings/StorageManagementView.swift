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
    @AppStorage(BulkArtworkPreference.key) private var autoDownloadFullCovers = false

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
        .navigationBarTitleDisplayMode(.inline)
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
        .onChange(of: autoDownloadFullCovers) { _, enabled in
            guard let preload = container?.albumCoverPreloadService else { return }
            if enabled {
                Task {
                    await preload.downloadAllCovers()
                    await viewModel?.refresh()
                }
            } else {
                preload.pauseAutomaticDownloads()
            }
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
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Cassette").font(.title3)
                        Spacer()
                        if viewModel.isLoading { ProgressView() }
                        else { Text(viewModel.totalFormatted).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    GeometryReader { geometry in
                        HStack(spacing: 1) {
                            ForEach(viewModel.categories.filter { $0.byteCount > 0 }) { category in
                                Rectangle().fill(category.storageColor)
                                    .frame(width: max(0, (geometry.size.width - CGFloat(max(0, viewModel.categories.filter { $0.byteCount > 0 }.count - 1))) * CGFloat(category.byteCount) / CGFloat(max(1, viewModel.totalBytes))))
                            }
                        }
                    }
                    .frame(height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Cassette"))
                    .accessibilityValue(Text(viewModel.totalFormatted))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(viewModel.categories.filter { $0.byteCount > 0 }) { category in
                            Label {
                                Text(category.title).font(.caption).foregroundStyle(.secondary)
                            } icon: {
                                Circle().fill(category.storageColor).frame(width: 9, height: 9)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            } footer: {
                Text(String(localized: "Manage cached data used by Cassette on this device.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }

            if viewModel.reclaimableAudioBytes > 0 {
                Section(String(localized: "Recommendations", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    Button {
                        categoryToClear = viewModel.categories.first { $0.kind == .audioCache }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "Clear automatic music storage", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                Text(ByteCountFormatter.string(fromByteCount: viewModel.reclaimableAudioBytes, countStyle: .file))
                                    .foregroundStyle(.secondary).monospacedDigit()
                                Text(String(localized: "Saved music is kept. Other tracks can be streamed again.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: {
                            SettingsIcon(systemImage: "music.note", color: .red)
                        }
                    }
                    .disabled(viewModel.clearingKind != nil)
                }
            }

            Section {
                ForEach(viewModel.sortedCategories) { category in
                    categoryRow(category, viewModel: viewModel)
                }
            } header: {
                HStack {
                    Text(String(localized: "Categories", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    Spacer()
                    Menu {
                        Button(String(localized: "Largest first", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { viewModel.largestFirst = true }
                        Button(String(localized: "Smallest first", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { viewModel.largestFirst = false }
                    } label: {
                        Label(String(localized: "Size", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "arrow.up.arrow.down")
                    }
                    .textCase(nil)
                }
            }

            if let preload = container?.albumCoverPreloadService {
                Section {
                    Toggle(isOn: $autoDownloadFullCovers) {
                        Text(String(localized: "Automatically download all covers", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                    if !preload.state.isComplete {
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
                            if preload.state.isAnalyzingColors {
                                ProgressView()
                            } else if preload.state.isDownloading {
                                if preload.state.isResolvingInventory || preload.state.libraryTotal == 0 {
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
                    }
                    if preload.state.isAnalyzingColors {
                        Text(String(localized: "Analyzing cover colors…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = preload.state.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !preload.state.isResolvingInventory && preload.state.libraryTotal > 0 {
                        Text("\(preload.state.availableCompleted) / \(preload.state.libraryTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if preload.state.failed > 0 {
                        Text(String(localized: "\(preload.state.failed) covers failed", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "Album Covers", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } footer: {
                    Text(String(localized: "Covers you view load as needed. Downloading the whole library uses additional storage and network data.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
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
        NavigationLink {
            Form {
                Section {
                    LabeledContent(String(localized: "Size", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), value: category.formattedSize)
                    if let count = category.itemCount {
                        LabeledContent(String(localized: "Items", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), value: count.formatted())
                    }
                }
                if category.kind == .audioCache {
                    Section {
                        NavigationLink(String(localized: "Saved Music", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                            DownloadedMusicManagementView()
                        }
                    }
                    CacheSectionView()
                }
                if category.kind != .audioCache {
                    Section {
                        Button(String(localized: "Clear", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) {
                            categoryToClear = category
                        }
                        .disabled(viewModel.clearingKind != nil || (category.kind == .audioCache ? viewModel.reclaimableAudioBytes == 0 : category.byteCount == 0))
                    }
                }
            }
            .formStyle(.grouped)
            .modifier(SettingsSubpageStyle())
            .navigationTitle(category.title)
        } label: {
            StorageCategoryRow(category: category)
        }
    }

}

private struct StorageCategoryRow: View {
    let category: StorageCategorySnapshot

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

private extension StorageCategorySnapshot {
    var storageColor: Color {
        switch kind {
        case .audioCache: .red
        case .artwork: .orange
        case .lyrics: .yellow
        case .translations: .green
        case .descriptions: .cyan
        case .discover: .purple
        case .downloads: .red
        }
    }
}
