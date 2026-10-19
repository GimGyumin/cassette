import SwiftUI

/// An explicit override is useful for untagged edits; automatic matching remains conservative.
struct AtmosVersionSelectionView: View {
    let song: DisplayableSong
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [DisplayableSong] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var identity: ServerRequestIdentity?
    @State private var selectedID: String?

    private var filteredCandidates: [DisplayableSong] {
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.title.localizedCaseInsensitiveContains(query)
            || ($0.albumName ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice("Automatic Matching", id: nil)
                    choice("Use Original Song", id: "")
                } footer: {
                    Text("Manual choices apply when Prefer Dolby Atmos is enabled. The current album artwork and track information stay the same.")
                }
                Section {
                    if isLoading { ProgressView() }
                    ForEach(filteredCandidates) { candidate in
                        Button {
                            select(candidate.id)
                        } label: {
                            HStack(spacing: CassetteSpacing.m) {
                                VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                                    Text(candidate.title).font(.cassetteCellTitle).foregroundStyle(.primary)
                                    Text(candidate.albumName ?? "").font(.cassetteCaption).foregroundStyle(.secondary)
                                    Text(durationLabel(candidate.duration)).font(.cassetteCaption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedID == candidate.id { Image(systemName: "checkmark").foregroundStyle(.cassetteAccent) }
                            }
                        }
                    }
                    if !isLoading, candidates.isEmpty {
                        EmptyStateView(systemImage: "waveform",
                            title: String(localized: "Dolby Atmos Versions", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                            subtitle: String(localized: "No Dolby Atmos versions found for this artist. Check the album names and refresh your library.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                    }
                } header: { Text("Dolby Atmos Versions") }
            }
            .searchable(text: $query)
            .navigationTitle(Text("Dolby Atmos Version"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: container?.serverState.accountRevision) { await load() }
        }
    }

    private func choice(_ title: LocalizedStringKey, id: String?) -> some View {
        Button { select(id) } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selectedID == id { Image(systemName: "checkmark").foregroundStyle(.cassetteAccent) }
            }
        }
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? Int(max(0, min(duration, 86400))) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func select(_ id: String?) {
        guard let container, let identity, container.serverState.requestIsCurrent(identity) else { return }
        container.libraryIndexService.setManualAtmosSelection(id, for: song, serverId: identity.serverID)
        Task { await container.playerService.playbackVariantSettingsDidChange() }
        dismiss()
    }

    private func load() async {
        if let identity, container?.serverState.requestIsCurrent(identity) != true { dismiss(); return }
        candidates = []; identity = nil; isLoading = true
        defer { isLoading = false }
        guard let container, let sid = container.serverState.activeServer?.id,
              let token = try? container.serverState.requestIdentity(for: sid) else { return }
        selectedID = container.libraryIndexService.manualAtmosSelection(songId: song.id, serverId: sid)
        if !container.libraryIndexService.hasUsableIndex {
            await container.libraryIndexService.ensureIndexedAndWait(using: container.libraryService)
        }
        let result = await container.libraryIndexService.atmosCandidates(for: song, serverId: sid)
        guard !Task.isCancelled, container.serverState.requestIsCurrent(token) else { return }
        candidates = result; identity = token
    }
}
