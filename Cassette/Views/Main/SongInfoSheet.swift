// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic

#if canImport(FoundationModels)
import FoundationModels
#endif

struct SongInfoSheet: View {
    let song: DisplayableSong
    var lyricsLines: [String] = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container

    @State private var credits: [CreditRow] = []
    @State private var aiInsight: String?
    @State private var resolvedLyrics: [String] = []
    @State private var isLoadingCredits = true
    @State private var isGeneratingAI = false
    @State private var aiProgress: Double = 0
    @State private var aiStatus: String = ""
    @State private var aiError: String?

    private var displayedLyrics: [String] {
        resolvedLyrics.isEmpty ? lyricsLines : resolvedLyrics
    }

    private struct CreditRow: Identifiable, Equatable {
        let id: String
        let role: String
        let name: String
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title)
                            .font(.title3.weight(.semibold))
                        if let artist = song.artist {
                            Text(artist)
                                .foregroundStyle(.secondary)
                        }
                        if let album = song.albumName {
                            Text(album)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if isGeneratingAI {
                        VStack(alignment: .leading, spacing: CassetteSpacing.s) {
                            ProgressView(value: aiProgress, total: 1.0)
                                .tint(Color.cassetteAccent)
                            Text(aiStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else if let aiInsight {
                        Text(aiInsight)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    } else if let aiError {
                        Text(aiError)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Try Again", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                            Task { await generateAIInsight() }
                        }
                    } else {
                        Button(String(localized: "Generate with Apple Intelligence", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                            Task { await generateAIInsight() }
                        }
                    }
                } header: {
                    Text(String(localized: "About & Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                } footer: {
                    Text(String(localized: "Searches Wikipedia and MusicBrainz about this track, then summarizes that research and explains the lyrics.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                }

                if !displayedLyrics.isEmpty {
                    Section(String(localized: "Lyrics", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                        Text(displayedLyrics.joined(separator: "\n"))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }

                if !credits.isEmpty || isLoadingCredits {
                    Section(String(localized: "Credits", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                        if isLoadingCredits && credits.isEmpty {
                            ProgressView()
                                .accessibilityLabel(String(localized: "Loading credits", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        } else {
                            ForEach(credits) { row in
                                LabeledContent(row.role) {
                                    Text(row.name)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }

                Section(String(localized: "Audio", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    ForEach(audioSpecRows, id: \.label) { row in
                        LabeledContent(row.label) {
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Song Info", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { dismiss() }
                }
            }
            .task {
                await loadCredits()
                if aiInsight == nil {
                    await generateAIInsight()
                }
            }
        }
        .tint(Color.cassetteAccent)
    }

    private var audioSpecRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let quality = AudioQualityClassifier.classify(song) {
            rows.append((String(localized: "Quality", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), quality.title))
            rows.append((String(localized: "Detail", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), quality.detailLine))
        }
        if let format = song.audioFormat, !format.isEmpty {
            rows.append((String(localized: "Format", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), format.uppercased()))
        } else if let contentType = song.contentType, !contentType.isEmpty {
            rows.append((String(localized: "Format", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), contentType))
        }
        if let bitRate = song.bitRate, bitRate > 0 {
            rows.append((String(localized: "Bit rate", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), "\(bitRate) kbps"))
        }
        if let bitDepth = song.bitDepth, bitDepth > 0 {
            rows.append((String(localized: "Bit depth", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), "\(bitDepth)-bit"))
        }
        if let sampleRate = song.samplingRate, sampleRate > 0 {
            let khz = Double(sampleRate) / 1000.0
            rows.append((String(localized: "Sample rate", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), String(format: "%.1f kHz", khz)))
        }
        if let channels = song.channelCount, channels > 0 {
            rows.append((String(localized: "Channels", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), "\(channels)"))
        }
        if song.duration > 0 {
            rows.append((String(localized: "Duration", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), Self.formatDuration(song.duration)))
        }
        if let isrc = song.isrc, !isrc.isEmpty {
            rows.append((String(localized: "ISRC", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isrc))
        }
        if rows.isEmpty {
            rows.append((String(localized: "Audio", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), String(localized: "Unavailable", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)))
        }
        return rows
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func loadCredits() async {
        isLoadingCredits = true
        defer { isLoadingCredits = false }

        var rows: [CreditRow] = []
        if let work = song.workName, !work.isEmpty {
            rows.append(CreditRow(id: "work-display", role: String(localized: "Work", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: work))
        }
        if let movement = song.movementLabel, !movement.isEmpty {
            rows.append(CreditRow(id: "movement-display", role: String(localized: "Movement", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: movement))
        }
        if let composer = song.displayComposer, !composer.isEmpty {
            rows.append(CreditRow(id: "composer-display", role: String(localized: "Composer", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: composer))
        }

        if let albumId = song.albumId,
           let album = try? await container?.libraryService.album(id: albumId),
           let full = album.song?.first(where: { $0.id == song.id }) {
            if let work = full.works?.first?.name, !work.isEmpty,
               !rows.contains(where: { $0.role == String(localized: "Work", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) }) {
                rows.append(CreditRow(id: "work", role: String(localized: "Work", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: work))
            }
            if let movement = full.movements?.first?.displayLabel, !movement.isEmpty,
               !rows.contains(where: { $0.role == String(localized: "Movement", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) }) {
                rows.append(CreditRow(id: "movement", role: String(localized: "Movement", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: movement))
            }
            if let composer = full.displayComposer, !composer.isEmpty,
               !rows.contains(where: { $0.role == String(localized: "Composer", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale) && $0.name == composer }) {
                rows.append(CreditRow(id: "composer", role: String(localized: "Composer", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: composer))
            }
            for contributor in full.contributors ?? [] {
                let role = Self.prettyRole(contributor.role, subRole: contributor.subRole)
                rows.append(CreditRow(
                    id: "\(contributor.role)-\(contributor.artist.id)-\(contributor.artist.name)",
                    role: role,
                    name: contributor.artist.name
                ))
            }
            if let artists = full.artists {
                for artist in artists where !rows.contains(where: { $0.name == artist.name }) {
                    rows.append(CreditRow(id: "artist-\(artist.id)", role: String(localized: "Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: artist.name))
                }
            }
        }

        if rows.isEmpty, let artist = song.artist {
            rows.append(CreditRow(id: "artist-fallback", role: String(localized: "Artist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), name: artist))
        }

        var seen = Set<String>()
        credits = rows.filter { row in
            let key = "\(row.role)|\(row.name)".lowercased()
            return seen.insert(key).inserted
        }
    }

    private static func prettyRole(_ role: String, subRole: String?) -> String {
        let base: String
        switch role.lowercased() {
        case "composer": base = String(localized: "Composer", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case "producer": base = String(localized: "Producer", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case "lyricist": base = String(localized: "Lyricist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case "mixer", "mix engineer": base = String(localized: "Mixer", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case "engineer": base = String(localized: "Engineer", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case "arranger": base = String(localized: "Arranger", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case "featuring", "featured artist": base = String(localized: "Featured", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        default:
            base = role.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let subRole, !subRole.isEmpty {
            return "\(base) (\(subRole))"
        }
        return base
    }

    private func setAIProgress(_ value: Double, status: String) {
        withAnimation(.easeInOut(duration: 0.22)) {
            aiProgress = value
            aiStatus = status
        }
    }

    private func generateAIInsight() async {
        isGeneratingAI = true
        aiError = nil
        setAIProgress(0.05, status: String(localized: "Preparing…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
        defer { isGeneratingAI = false }

        let result = await SongInsightService.generate(
            song: song,
            seedLyrics: displayedLyrics,
            lyricsService: container?.lyricsService,
            serverId: container?.serverState.activeServer?.id
        ) { progress in
            switch progress {
            case .preparing:
                setAIProgress(0.08, status: String(localized: "Preparing…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            case .searching:
                setAIProgress(0.28, status: String(localized: "Searching about this song…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            case .loadingLyrics:
                setAIProgress(0.55, status: String(localized: "Loading lyrics…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            case .summarizing:
                setAIProgress(0.78, status: String(localized: "Summarizing research…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            case .finished:
                setAIProgress(1.0, status: String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            }
        }

        guard let result else {
            aiError = String(localized: "Couldn’t generate song insight right now.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            return
        }

        if !result.lyricsLines.isEmpty {
            resolvedLyrics = result.lyricsLines
        }

        let text = formatInsight(result.text)
        if text.isEmpty {
            aiError = String(localized: "Couldn’t generate song insight right now.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        } else {
            aiInsight = text
        }
    }

    private func formatInsight(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("\n---\n") {
            text = text
                .components(separatedBy: "\n---\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        return text
    }
}
