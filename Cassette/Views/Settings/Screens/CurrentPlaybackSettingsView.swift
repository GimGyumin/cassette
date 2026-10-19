import SwiftUI
import SwiftSonic

struct CurrentPlaybackSettingsView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.scenePhase) private var scenePhase
    @State private var details: PlaybackDetails?

    private struct RefreshKey: Equatable {
        let isActive: Bool
        let trackID: String?
        let radioID: String?
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }

    var body: some View {
        Form {
            if let settings = container?.streamingSettings {
                Section {
                    SettingsNavigationRow("Server Playback Method", value: settings.jellyfinRoute.choiceTitle) {
                        ServerPlaybackMethodSelectionView(selection: Binding(
                            get: { settings.jellyfinRoute },
                            set: { settings.jellyfinRoute = $0 }
                        ))
                    }
                }
            }
            if let state = container?.playerState, state.currentTrack != nil || state.currentRadio != nil {
                Section {
                    if let song = state.currentTrack {
                        Text(song.title).font(.headline)
                        if let artist = song.artist { Text(artist).foregroundStyle(.secondary) }
                    } else if let radio = state.currentRadio {
                        Text(radio.name).font(.headline)
                    }
                }
                if let details {
                    Section {
                        LabeledContent("Playback source", value: localized(details.location.rawValue))
                        LabeledContent("Playback method", value: details.method.usesOriginalName
                            ? details.method.rawValue : localized(details.method.rawValue))
                        LabeledContent("Playback engine", value: details.engine)
                        if let sampleRate = details.audioSessionSampleRate {
                            LabeledContent("Audio session sample rate", value: "\(Int(sampleRate)) Hz")
                        }
                        LabeledContent("ReplayGain", value: localized(details.replayGainStatus.rawValue))
                        if details.replayGainStatus == .applied {
                            LabeledContent("Applied gain", value: String(format: "%+.1f dB", details.appliedGainDB))
                        }
                        if let codec = details.actualCodec {
                            LabeledContent("Actual codec", value: codec)
                        }
                        if let codec = details.requestedCodec {
                            LabeledContent("Requested codec", value: codec)
                        }
                        if let bitrate = details.bitRateLimitKbps {
                            LabeledContent("Requested bitrate limit", value: "\(bitrate) kbps")
                        }
                        if let format = details.localFileFormat {
                            LabeledContent("Local file format", value: format)
                        }
                    } footer: {
                        SettingsSectionFooter("These details describe the current playback request. The source format and requested codec may differ from the audio returned by your server.")
                    }
                } else {
                    Section { ProgressView(String(localized: "Preparing playback…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) }
                }
                if let song = state.currentTrack {
                    Section {
                        if let format = song.audioFormat, !format.isEmpty {
                            LabeledContent("Source format", value: format.uppercased())
                        }
                        if let bitRate = song.bitRate, bitRate > 0 {
                            LabeledContent("Source bitrate", value: "\(bitRate) kbps")
                        }
                        if let sampleRate = song.samplingRate, sampleRate > 0 {
                            LabeledContent("Source sample rate", value: "\(sampleRate) Hz")
                        }
                        if let bitDepth = song.bitDepth, bitDepth > 0 {
                            LabeledContent("Source bit depth", value: "\(bitDepth) bit")
                        }
                    } header: { SettingsSectionHeader("Source audio") }
                }
            } else {
                ContentUnavailableView("Not Playing", systemImage: "waveform",
                    description: Text("Play a song to see its playback method here."))
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Current Playback"))
        .navigationBarTitleDisplayModeInline()
        .task(id: RefreshKey(isActive: scenePhase == .active,
                            trackID: container?.playerState.currentTrack?.id,
                            radioID: container?.playerState.currentRadio?.id)) {
            details = nil
            guard scenePhase == .active, let player = container?.playerService else { return }
            // Read only while this page is visible. Also catches adaptive retries and gapless
            // transitions without adding observation or polling to the rest of the app.
            while !Task.isCancelled {
                let snapshot = await player.playbackDetails()
                guard !Task.isCancelled else { return }
                details = snapshot
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
