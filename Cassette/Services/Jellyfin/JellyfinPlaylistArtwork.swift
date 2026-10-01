import Foundation

nonisolated enum JellyfinPlaylistArtwork {
    /// Password accounts retain their existing native upload route.
    static func uploadIfPasswordless(
        credentials: ServerCredentials, baseURL: URL, playlistID: String, data: Data
    ) async throws -> Bool {
        guard credentials.password.isEmpty else { return false }
        guard let token = credentials.jellyfinAccessToken, !token.isEmpty else {
            throw CassetteError.credentialsMissing
        }
        let identity = await MainActor.run { JellyfinDeviceIdentity.current() }
        let client = try JellyfinClient(serverBaseURL: baseURL, accessToken: token,
            customHeaders: credentials.customHeaders, deviceID: identity.id, deviceName: identity.name,
            clientName: identity.clientName, clientVersion: identity.clientVersion)
        try await client.uploadPlaylistArtwork(
            playlistID: JellyfinMusicTransport.remoteID(playlistID), data: data, mimeType: "image/jpeg")
        return true
    }
}
