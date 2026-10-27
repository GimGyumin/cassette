// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// Single entry point for obtaining a playable URL for a given song.
/// Resolution order: downloaded → cached → stream.
/// PlayerService always calls this — never SwiftSonic directly.
protocol MediaResolverProtocol: AnyObject, Sendable {
    func resolve(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource
    func resolveOriginal(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource
    func resolveLosslessUpgrade(song: DisplayableSong, serverId: UUID) async throws -> MediaSource?
    func preferredAtmosDownloadSong(for song: DisplayableSong, serverId: UUID) async -> DisplayableSong?
    func resolveRadio(_ station: InternetRadioStation) async throws -> MediaSource
}

extension MediaResolverProtocol {
    func preferredAtmosDownloadSong(for song: DisplayableSong, serverId: UUID) async -> DisplayableSong? { nil }
    func resolveLosslessUpgrade(song: DisplayableSong, serverId: UUID) async throws -> MediaSource? { nil }
    func resolveOriginal(songId: String, serverId: UUID, song: DisplayableSong?) async throws -> MediaSource {
        try await resolve(songId: songId, serverId: serverId, song: song)
    }
}
