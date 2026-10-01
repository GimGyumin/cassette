// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import AppIntents
import Foundation

/// User-facing errors for the audio intents, localized for Siri.
@available(iOS 27.0, macOS 27.0, *)
enum CassetteAudioIntentError: Error {
    case noAudioEntity
    case unsupportedTarget
    case playerUnavailable
    case serviceUnavailable
    case playbackFailed(underlying: Error)
}

@available(iOS 27.0, macOS 27.0, *)
extension CassetteAudioIntentError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAudioEntity:
            return LocalizedStringResource(
                "No matching audio was found in Cassette.",
                comment: "Spoken when Siri can't resolve any matching audio for a request."
            )
        case .unsupportedTarget:
            return LocalizedStringResource(
                "Cassette can't do that with this item.",
                comment: "Spoken when an audio action is applied to an unsupported item type."
            )
        case .playerUnavailable:
            return LocalizedStringResource(
                "Cassette isn't ready to play yet. Please try again.",
                comment: "Spoken when playback is requested before the player has finished booting."
            )
        case .serviceUnavailable:
            return LocalizedStringResource(
                "Cassette isn't ready yet. Please try again.",
                comment: "Spoken when a service is requested before the app has finished booting."
            )
        case .playbackFailed:
            return LocalizedStringResource(
                "Cassette couldn't start playback.",
                comment: "Spoken when playback fails for an underlying engine reason."
            )
        }
    }
}
