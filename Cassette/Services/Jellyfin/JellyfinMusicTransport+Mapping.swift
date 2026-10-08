// Cassette — Licensed under the Mozilla Public License 2.0.
import Foundation

extension JellyfinMusicTransport {
    static func remoteID(_ id: String) -> String {
        NavidromeJellyfinIDCodec.jellyfinGUID(fromCanonicalID: id) ?? id
    }

    static func localID(_ id: String) -> String {
        NavidromeJellyfinIDCodec.canonicalID(fromJellyfinGUID: id) ?? id
    }

    static func seconds(_ item: JellyfinItem) -> Int {
        Int(max(0, item.runTimeTicks ?? 0) / 10_000_000)
    }

    private static func common(_ item: JellyfinItem) -> [String: Any] {
        var result: [String: Any] = ["id": localID(item.id)]
        // Jellyfin serves inherited artwork for audio items as well as album items.
        result["coverArt"] = localID(item.id)
        if item.userData?.isFavorite == true {
            // Jellyfin supplies a boolean, not a favorite timestamp. Use a stable sentinel.
            result["starred"] = "1970-01-01T00:00:00Z"
        }
        result["year"] = item.productionYear
        result["playCount"] = item.userData?.playCount
        result["genre"] = item.genres?.first
        result["genres"] = item.genres?.map { ["name": $0] }
        result["created"] = item.dateCreated
        return result
    }

    static func song(_ item: JellyfinItem) -> [String: Any] {
        song(item, mediaSource: nil)
    }

    static func song(_ item: JellyfinItem, mediaSource: JellyfinMediaSource?) -> [String: Any] {
        var result = common(item)
        result["title"] = item.name ?? ""
        result["isDir"] = false
        result["type"] = "music"
        result["duration"] = seconds(item)
        result["album"] = item.album
        result["albumId"] = item.albumId.map(localID)
        result["artist"] = item.artists?.joined(separator: ", ") ?? item.albumArtist
        result["artistId"] = item.artistItems?.first?.id.map(localID)
        result["displayArtist"] = item.artists?.joined(separator: ", ")
        result["artists"] = item.artistItems?.compactMap { pair -> [String: Any]? in
            guard let id = pair.id else { return nil }
            return ["id": localID(id), "name": pair.name ?? ""]
        }
        result["track"] = item.indexNumber
        result["discNumber"] = item.parentIndexNumber
        let source = mediaSource ?? item.mediaSources?.first
        let audio = source?.defaultAudioStream
        result["suffix"] = source?.container ?? audio?.codec
        result["size"] = source?.containerSize
        result["bitRate"] = (audio?.bitRate ?? source?.bitrate).map { $0 / 1000 }
        result["samplingRate"] = audio?.sampleRate
        result["bitDepth"] = audio?.bitDepth
        result["channelCount"] = audio?.channels
        return result
    }

    static func album(_ item: JellyfinItem) -> [String: Any] {
        var result = common(item)
        result["name"] = item.name ?? ""
        result["songCount"] = item.childCount ?? item.recursiveItemCount ?? 0
        result["duration"] = seconds(item)
        let albumArtist = item.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        result["artist"] = albumArtist?.isEmpty == false ? albumArtist
            : (item.albumArtists?.first?.name ?? item.artists?.joined(separator: ", "))
        result["isCompilation"] = item.isCompilation
        result["artistId"] = (item.albumArtists?.first?.id ?? item.artistItems?.first?.id).map(localID)
        return result
    }

    static func artist(_ item: JellyfinItem) -> [String: Any] {
        var result = common(item)
        result["name"] = item.name ?? ""
        result["albumCount"] = item.childCount
        return result
    }

    static func playlist(_ item: JellyfinItem) -> [String: Any] {
        var result = common(item)
        result["name"] = item.name ?? ""
        result["comment"] = item.overview
        result["songCount"] = item.childCount ?? item.recursiveItemCount ?? item.playlistInfo?.itemIDs?.count ?? 0
        result["duration"] = seconds(item)
        result["public"] = item.playlistInfo?.openAccess
        return result
    }

    func mediaURL(endpoint: String, parameters: [String: String]) -> URL? {
        guard let id = parameters["id"], !id.isEmpty else { return nil }
        let remote = Self.remoteID(id)
        switch endpoint {
        case "getCoverArt":
            return client.artworkURL(itemID: remote, maxWidth: parameters["size"].flatMap(Int.init))
        case "download":
            return client.downloadURL(itemID: remote)
        case "stream":
            let format = parameters["format"]
            let bitrate = parameters["maxBitRate"].flatMap(Int.init).flatMap { $0 > 0 ? $0 * 1000 : nil }
            if format == "raw" || (format == nil && bitrate == nil) {
                return client.originalFileURL(itemID: remote)
            }
            let codec = format ?? "aac"
            return client.progressiveAudioURL(itemID: remote, container: codec, audioCodec: codec,
                                              audioBitRate: bitrate,
                                              startTimeTicks: parameters["timeOffset"].flatMap(Int64.init).map { $0 * 10_000_000 })
        default:
            return nil
        }
    }
}
