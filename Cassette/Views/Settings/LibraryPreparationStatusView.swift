import SwiftUI

/// One account entry, backed by the same services that feed the Live Activity.
struct LibraryPreparationAccountSection: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        if let container, container.serverState.activeServer != nil,
           (container.albumCoverPreloadService.state.isDownloading && !container.albumCoverPreloadService.state.isComplete)
            || container.albumCoverPreloadService.state.isAnalyzingColors
            || container.libraryIndexService.isPreparing
            || container.libraryIndexService.lastError != nil
            || container.libraryPreparationService.phase.isPreparing
            || container.libraryPreparationService.phase == .failed {
            Section {
                NavigationLink {
                    LibraryPreparationStatusView()
                } label: {
                    HStack(spacing: 14) {
                        PreparationStatusIcon()
                        Text(String(localized: "Optimizing Your Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                            .font(.body)
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("account.libraryPreparation")
            }
        }
    }
}

struct LibraryPreparationStatusView: View {
    @Environment(\.appContainer) private var container
    @State private var showsDetails = false

    private func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    PreparationStatusIcon()
                    VStack(alignment: .leading, spacing: 16) {
                        Text(text("Optimizing Your Library"))
                            .font(.title3.weight(.semibold))
                        Text(BulkArtworkPreference.isEnabled && container?.albumCoverPreloadService.state.isDownloading == true && container?.albumCoverPreloadService.state.isComplete != true
                            ? text("Keep using Cassette while your album covers download and your library is prepared for search. Progress is saved automatically, so completed downloads are not repeated.")
                            : text("Keep using Cassette while your library is prepared for search."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let container {
                            let covers = container.albumCoverPreloadService.state
                            if covers.isAnalyzingColors {
                                Text(text("Analyzing cover colors…"))
                                    .font(.subheadline.weight(.medium))
                                ProgressView(value: Double(covers.colorsCompleted), total: Double(max(1, covers.colorsTotal)))
                            } else if covers.isDownloading && !covers.isComplete {
                                Text(text("Downloading album covers…"))
                                    .font(.subheadline.weight(.medium))
                                if !covers.isResolvingInventory && covers.libraryTotal > 0 {
                                    ProgressView(value: covers.fraction)
                                    Text("\(covers.availableCompleted) / \(covers.libraryTotal)")
                                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                }
                            } else if (covers.isComplete || !BulkArtworkPreference.isEnabled),
                                      container.libraryIndexService.hasUsableIndex,
                                      !container.libraryIndexService.isPreparing,
                                      container.libraryIndexService.lastError == nil {
                                Label(text("Preparation complete"), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if covers.errorMessage == nil,
                                      container.libraryIndexService.lastError == nil {
                                Text(text("Preparation will continue automatically when a connection is available."))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            if container.libraryIndexService.isIndexing {
                                Text(text("Library indexing"))
                                    .font(.subheadline.weight(.medium))
                                ProgressView(value: container.libraryIndexService.progress)
                            }
                            if let error = container.libraryIndexService.lastError {
                                Text(error.displayMessage)
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button(text("Retry")) {
                                    Task { await retryPreparation(in: container) }
                                }
                            }
                            if BulkArtworkPreference.isEnabled, let error = covers.errorMessage {
                                Text(error).font(.footnote).foregroundStyle(.secondary)
                                Button(text("Retry")) {
                                    Task { await retryPreparation(in: container) }
                                }
                            }
                        }

                        Divider()
                        DisclosureGroup(text("Learn More"), isExpanded: $showsDetails) {
                            Text(BulkArtworkPreference.isEnabled
                                ? text("Downloads continue when you leave this screen. iOS controls background execution and may pause work to save power. Cassette automatically resumes unfinished work when allowed or when you reopen the app. Playback and device temperature take priority.")
                                : text("Local search preparation can continue while you use Cassette. Full-library artwork downloads can be enabled in Settings → Storage."))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        .tint(.blue)
                    }
                }
                .padding(22)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 26))
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(text("Optimizing Your Library"))
        .navigationBarTitleDisplayModeInline()
        .modifier(SettingsSubpageStyle())
    }

    @MainActor
    private func retryPreparation(in container: AppContainer) async {
        if container.libraryPreparationService.phase == .failed {
            container.libraryPreparationService.reset()
            await container.libraryPreparationService.prepareIfLibraryChanged(
                serverService: container.serverService,
                libraryService: container.libraryService,
                indexService: container.libraryIndexService,
                coverPreload: container.albumCoverPreloadService
            )
        } else if container.libraryIndexService.lastError != nil {
            _ = await container.libraryIndexService.rebuildAndWait(using: container.libraryService)
        } else if BulkArtworkPreference.isEnabled {
            await container.albumCoverPreloadService.downloadAllCovers()
        }
    }
}

private struct PreparationStatusIcon: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityHidden(true)
    }
}
