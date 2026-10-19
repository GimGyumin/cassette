import SwiftUI

extension JellyfinPlaybackRoute: SettingsChoiceItem {
    var choiceTitle: String {
        switch self {
        case .automatic: String(localized: "Automatic", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .directPlay: "Direct Play"
        case .universal: "Universal Transcoding"
        case .hls: "HLS"
        case .originalFile: "Original File"
        case .openSubsonic: "OpenSubsonic"
        }
    }

    var choiceSubtitle: String? {
        let key: String.LocalizationValue = switch self {
        case .automatic: "Chooses a server playback method for each track."
        case .directPlay: "Plays the original audio through Jellyfin without conversion."
        case .universal: "Uses Jellyfin Universal Audio with the selected streaming quality."
        case .hls: "Uses Jellyfin HLS audio with segmented seeking."
        case .originalFile: "Streams the original Jellyfin file without conversion."
        case .openSubsonic: "Uses the server's OpenSubsonic stream endpoint."
        }
        return String(localized: key, bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
    }
}

struct ServerPlaybackMethodSelectionView: View {
    @Binding var selection: JellyfinPlaybackRoute

    var body: some View {
        SettingsChoiceList(
            navigationTitle: "Server Playback Method",
            footer: "Applies to the next server streaming request. Downloaded and cached tracks play locally. Manual Jellyfin methods require server support.",
            items: JellyfinPlaybackRoute.allCases,
            selection: $selection
        )
    }
}
