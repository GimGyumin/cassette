import Foundation
import SwiftSonic

nonisolated enum AudioQualityKind: Equatable, Sendable {
    case dolbyAtmos
    /// Dolby Digital / Plus / TrueHD (non-Atmos). `channels` is 0 when the server omits it.
    case dolby(codec: String, channels: Int)
    /// Discrete surround: more than two channels, or a non-Dolby surround codec (DTS).
    case multichannel(channels: Int, codec: String?)
    case hiResLossless(bitDepth: Int, sampleRate: Int, formatLabel: String)
    case lossless(bitDepth: Int, sampleRate: Int, formatLabel: String)

    var title: String {
        switch self {
        case .dolbyAtmos: return String(localized: "Dolby Atmos", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .dolby: return "Dolby"
        case .multichannel: return String(localized: "Multichannel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .hiResLossless: return String(localized: "Hi-Res Lossless", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .lossless: return String(localized: "Lossless", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    var detailLine: String {
        switch self {
        case .dolbyAtmos:
            return "Spatial Audio"
        case .dolby(let codec, let channels):
            return Self.surroundDetail(codec: codec, channels: channels)
        case .multichannel(let channels, let codec):
            return Self.surroundDetail(codec: codec, channels: channels)
        case .hiResLossless(let bitDepth, let sampleRate, let formatLabel),
             .lossless(let bitDepth, let sampleRate, let formatLabel):
            let rateKHz = sampleRate >= 1000
                ? String(format: "%.1f kHz", Double(sampleRate) / 1000.0)
                : "\(sampleRate) Hz"
            return "\(bitDepth)-bit/\(rateKHz) \(formatLabel)"
        }
    }

    /// "5.1 · Dolby Digital Plus", "6 channels", or just the codec when the
    /// server does not report a channel count.
    private static func surroundDetail(codec: String?, channels: Int) -> String {
        var parts: [String] = []
        if let layout = channelLayout(channels) { parts.append(layout) }
        if let codec, !codec.isEmpty { parts.append(codec) }
        if parts.isEmpty {
            return String(localized: "Multichannel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
        return parts.joined(separator: " · ")
    }

    /// 6 → "5.1", 8 → "7.1" (Apple Music style), otherwise "N channels".
    static func channelLayout(_ channels: Int) -> String? {
        switch channels {
        case 0: return nil
        case 6: return "5.1"
        case 8: return "7.1"
        default: return String(localized: "\(channels) channels", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }
}

nonisolated enum AudioQualityClassifier {
    static func classify(_ song: DisplayableSong) -> AudioQualityKind? {
        if isDolbyAtmos(song) { return .dolbyAtmos }

        let channels = song.channelCount ?? 0

        // Dolby Digital / Plus / TrueHD carry no Atmos metadata but are still
        // bitstreamed raw, so they deserve a label of their own.
        if let codec = dolbyCodecName(song) {
            return .dolby(codec: codec, channels: channels)
        }
        if channels > 2 {
            return .multichannel(channels: channels, codec: surroundCodecName(song))
        }
        if let codec = surroundCodecName(song) {
            return .multichannel(channels: 0, codec: codec)
        }

        let suffix = normalizedSuffix(song)
        let contentType = song.contentType?.lowercased() ?? ""
        guard isLosslessFormat(
            suffix: suffix,
            contentType: contentType,
            bitDepth: song.bitDepth,
            bitRate: song.bitRate
        ) else { return nil }

        let bitDepth = song.bitDepth ?? inferredBitDepth(suffix: suffix)
        let sampleRate = song.samplingRate ?? inferredSampleRate(suffix: suffix, bitRate: song.bitRate)
        let formatLabel = displayFormatLabel(
            suffix: suffix,
            contentType: contentType,
            bitDepth: song.bitDepth,
            bitRate: song.bitRate
        )

        if bitDepth >= 24 && sampleRate >= 48_000 {
            return .hiResLossless(bitDepth: bitDepth, sampleRate: sampleRate, formatLabel: formatLabel)
        }
        return .lossless(bitDepth: bitDepth, sampleRate: sampleRate, formatLabel: formatLabel)
    }

    /// Now-playing badge: hide Lossless / Hi-Res when the stream is lossy-transcoded.
    /// Dolby and multichannel are always shown — those streams are
    /// bitstreamed raw, and the request is often still labelled as transcoded while the
    /// player is handing the track to AVPlayer.
    static func displayablePlaybackQuality(
        for song: DisplayableSong,
        isExpensive: Bool,
        isTranscoding: Bool
    ) -> AudioQualityKind? {
        guard let kind = classify(song) else { return nil }
        switch kind {
        case .dolbyAtmos, .dolby, .multichannel:
            return kind
        case .lossless, .hiResLossless:
            // Network cost says nothing about the codec actually being delivered.
            if isTranscoding { return nil }
            return kind
        }
    }

    /// True when the resolved route asks for a lossy Jellyfin or Subsonic stream.
    static func isLossyTranscodeStream(_ source: MediaSource) -> Bool {
        guard case .stream(let url, _, _, _, _) = source else { return false }
        if source.jellyfinPlaybackContext?.playMethod == .transcode { return true }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name.lowercased() == "static" && $0.value?.lowercased() == "true" }) { return false }
        let lowerPath = url.path.lowercased()
        // This server's Jellyfin Universal and HLS routes are lossy even if a legacy
        // request happens to carry AudioCodec=flac. A parameter is not delivered audio.
        if lowerPath.contains("/audio/") && (lowerPath.hasSuffix("/universal") || lowerPath.hasSuffix("/main.m3u8")) {
            return true
        }
        if let codec = query.first(where: { $0.name.lowercased() == "audiocodec" })?.value?.lowercased() {
            if ["flac", "alac", "pcm", "pcm_s16le", "pcm_s24le"].contains(codec) { return false }
            if ["aac", "mp3", "opus", "vorbis", "ac3", "eac3"].contains(codec) { return true }
        }
        let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.lowercased() == "format" })?
            .value?
            .lowercased()
        guard let format, format != "raw" else { return false }
        return ["mp3", "opus", "aac", "m4a"].contains(format)
    }

    static func isDolbyAudio(_ song: DisplayableSong) -> Bool {
        isDolbyAtmos(song) || dolbyCodecName(song) != nil
    }

    /// Preserve spatial/multichannel bitstreams and ambiguous MP4 audio. Missing FLAC channel
    /// metadata is common in Navidrome's Jellyfin items and must not force a requested AAC raw.
    static func shouldSkipTranscoding(_ song: DisplayableSong) -> Bool {
        isDolbyAtmos(song) || hasSurroundCodec(song) || (song.channelCount ?? 0) > 2
            || (hasUnspecifiedChannelLayout(song) && ["m4a", "mp4"].contains(normalizedSuffix(song)))
    }

    /// AudioStreaming's output graph is fixed to stereo 44.1 kHz. Preserve surround
    /// and avoid its intermediate resampling for non-44.1-kHz lossless sources.
    static func requiresSystemPlayer(_ song: DisplayableSong) -> Bool {
        isDolbyAtmos(song) || hasSurroundCodec(song) || (song.channelCount ?? 0) > 2
            || hasUnspecifiedChannelLayout(song) || requiresNativeSampleRate(song)
    }

    static func requiresNativeSampleRate(_ song: DisplayableSong) -> Bool {
        guard let sampleRate = song.samplingRate, sampleRate > 0, sampleRate != 44_100 else { return false }
        switch classify(song) {
        case .lossless, .hiResLossless: return true
        default: return false
        }
    }

    /// Atmos / JOC should use mono+stereo+multichannel spatialization; discrete surround beds should not.
    static func usesAtmosSpatialization(_ song: DisplayableSong) -> Bool {
        isDolbyAtmos(song)
    }

    /// True when the track is Dolby Atmos, Dolby surround, or multichannel
    /// (Discover Spatial Audio shelf). A surround codec whose channel count is a
    /// known stereo pair is excluded, so plain 2.0 AC-3 does not qualify.
    static func isSpatialOrMultichannel(_ song: DisplayableSong) -> Bool {
        if isDolbyAtmos(song) { return true }
        let channels = song.channelCount ?? 0
        if channels > 2 { return true }
        return hasSurroundCodec(song) && channels != 2
    }

    /// MP4 can contain E-AC-3/JOC even when the server reports its stereo core.
    /// Preserve ambiguous native containers; let AVFoundation inspect their actual layout.
    private static func hasUnspecifiedChannelLayout(_ song: DisplayableSong) -> Bool {
        let suffix = normalizedSuffix(song)
        let mime = song.contentType?.lowercased() ?? ""
        if ["m4a", "mp4"].contains(suffix), !mime.contains("aac"), !mime.contains("mp4a"),
           (song.bitDepth ?? 0) == 0 { return true }
        return (song.channelCount ?? 0) == 0 && ["flac", "alac", "wav", "aif", "aiff"].contains(suffix)
    }

    /// True when a previously cached/transcoded file must not be reused for playback.
    static func shouldBypassEphemeralCache(_ song: DisplayableSong) -> Bool {
        // Native sample-rate playback does not make a stereo file unsafe to cache.
        shouldSkipTranscoding(song)
    }

    static func bestQuality(in songs: [DisplayableSong]) -> AudioQualityKind? {
        songs.compactMap(classify).max(by: qualityRank)
    }

    /// Album headers can advertise a spatial mix and a lossless master together, as
    /// Music does. Keep the strongest spatial badge and strongest lossless badge.
    static func albumQualities(in songs: [DisplayableSong]) -> [AudioQualityKind] {
        let qualities = songs.compactMap(classify)
        let spatial = qualities
            .filter {
                switch $0 {
                case .dolbyAtmos, .dolby, .multichannel: return true
                case .hiResLossless, .lossless: return false
                }
            }
            .max(by: qualityRank)
        let lossless = qualities
            .filter {
                switch $0 {
                case .dolbyAtmos, .dolby, .multichannel: return false
                case .hiResLossless, .lossless: return true
                }
            }
            .max(by: qualityRank)
        return [spatial, lossless].compactMap { $0 }
    }

    private static func qualityRank(_ lhs: AudioQualityKind, _ rhs: AudioQualityKind) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ kind: AudioQualityKind) -> Int {
        switch kind {
        case .dolbyAtmos: return 5
        case .dolby: return 4
        case .multichannel: return 3
        case .hiResLossless: return 2
        case .lossless: return 1
        }
    }

    private static func isDolbyAtmos(_ song: DisplayableSong) -> Bool {
        song.isOriginalAudio != false && (AtmosAlbumPolicy.isAtmos(song.albumName) || metadataSuggestsAtmos(song))
    }

    /// Dolby Digital (AC-3), Dolby Digital Plus (E-AC-3) and Dolby TrueHD (MLP)
    /// all arrive as surround bitstreams, so they get a Dolby label.
    private static func dolbyCodecName(_ song: DisplayableSong) -> String? {
        let suffix = normalizedSuffix(song)
        let contentType = song.contentType?.lowercased() ?? ""

        if suffix == "ec3" || suffix == "eac3"
            || contentType.contains("ec-3") || contentType.contains("ec3") || contentType.contains("eac3") {
            return "Dolby Digital Plus"
        }
        if suffix == "ac3" || contentType.contains("ac3") {
            return "Dolby Digital"
        }
        if suffix == "mlp" || suffix == "thd"
            || contentType.contains("true-hd") || contentType.contains("mlp") {
            return "Dolby TrueHD"
        }
        return nil
    }

    /// Non-Dolby surround codecs. DTS beds are multichannel but carry no channel
    /// count on most Subsonic servers, so the label falls back to the codec name.
    private static func surroundCodecName(_ song: DisplayableSong) -> String? {
        let suffix = normalizedSuffix(song)
        let contentType = song.contentType?.lowercased() ?? ""
        if suffix == "dts" || suffix == "dtshd" || contentType.contains("dts") { return "DTS" }
        return nil
    }

    private static func hasSurroundCodec(_ song: DisplayableSong) -> Bool {
        let suffix = normalizedSuffix(song)
        let contentType = song.contentType?.lowercased() ?? ""

        // Explicit Dolby / DTS container extensions
        if ["ec3", "eac3", "ac3", "mlp", "thd", "dtshd", "dts"].contains(suffix) { return true }

        if contentType.contains("ec-3")
            || contentType.contains("ec3")
            || contentType.contains("eac3")
            || contentType.contains("ac3")
            || contentType.contains("true-hd")
            || contentType.contains("mlp")
            || contentType.contains("dts") {
            return true
        }

        return false
    }

    private static func metadataSuggestsAtmos(_ song: DisplayableSong) -> Bool {
        let haystack = [song.title, song.albumName, song.genre, song.comment]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if haystack.contains("dolby atmos") {
            return true
        }
        // Avoid matching unrelated words like "atmosphere".
        if haystack.range(of: #"\batmos\b"#, options: .regularExpression) != nil {
            return true
        }
        // JOC (Joint Object Coding) is the object layer inside E-AC-3 Atmos.
        return haystack.range(of: #"\bjoc\b"#, options: .regularExpression) != nil
    }

    private static func isLosslessFormat(suffix: String, contentType: String, bitDepth: Int?, bitRate: Int?) -> Bool {
        // Servers (and taggers) often attach a meaningless PCM bitDepth to lossy files.
        // Never promote known lossy codecs / containers to Lossless.
        if isKnownLossyFormat(suffix: suffix, contentType: contentType) {
            return false
        }

        let losslessSuffixes: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape", "dsf", "dff"]
        if losslessSuffixes.contains(suffix) { return true }
        if contentType.contains("flac") || contentType.contains("alac") || contentType.contains("wav") {
            return true
        }

        // ALAC is usually exposed as m4a/mp4. `bitDepth` alone is NOT enough — AAC in the
        // same container is frequently tagged 16-bit by scanners.
        let isMP4Container = suffix == "m4a" || suffix == "mp4"
            || contentType.contains("mp4") || contentType.contains("m4a")
        guard isMP4Container, let bitDepth, bitDepth > 0 else { return false }

        if contentType.contains("alac") { return true }

        // AAC tops out around 256–512 kbps; ALAC CD-quality is typically ~700 kbps+.
        // When bitrate is present in the lossy band, ignore the spurious bitDepth.
        if let bitRate, bitRate > 0 {
            return bitRate > 512
        }
        // No bitrate + bitDepth on an MP4 container → treat as ALAC (common OpenSubsonic shape).
        return true
    }

    /// Explicit lossy codecs that must never show a Lossless / Hi-Res badge.
    private static func isKnownLossyFormat(suffix: String, contentType: String) -> Bool {
        let lossySuffixes: Set<String> = [
            "mp3", "mpeg", "mpga", "mp2",
            "aac", "opus", "ogg", "oga", "vorbis",
            "wma", "mpc", "ac3"
        ]
        if lossySuffixes.contains(suffix) { return true }

        if contentType.contains("mpeg") && !contentType.contains("mp4") { return true } // audio/mpeg
        if contentType.contains("aac") && !contentType.contains("alac") { return true }
        if contentType.contains("opus")
            || contentType.contains("vorbis")
            || contentType.contains("ogg")
            || contentType.contains("wma") {
            return true
        }
        return false
    }

    private static func normalizedSuffix(_ song: DisplayableSong) -> String {
        let fromFormat = song.audioFormat?.lowercased() ?? ""
        if !fromFormat.isEmpty { return fromFormat }
        let fromType = song.contentType?.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        return fromType
    }

    private static func inferredBitDepth(suffix: String) -> Int {
        switch suffix {
        case "dsf", "dff": return 1
        default: return 16
        }
    }

    private static func inferredSampleRate(suffix: String, bitRate: Int?) -> Int {
        if suffix == "dsf" || suffix == "dff" { return 2_822_400 }
        if let bitRate, bitRate >= 900 { return 48_000 }
        return 44_100
    }

    private static func displayFormatLabel(suffix: String, contentType: String, bitDepth: Int?, bitRate: Int?) -> String {
        switch suffix {
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "m4a", "mp4":
            if contentType.contains("alac") { return "ALAC" }
            if let bitRate, bitRate > 0, bitRate <= 512 { return "AAC" }
            if let bitDepth, bitDepth > 0 { return "ALAC" }
            return "AAC"
        case "wav", "aiff", "aif": return "WAV"
        case "ape": return "APE"
        case "dsf", "dff": return "DSD"
        default:
            if contentType.contains("flac") { return "FLAC" }
            if contentType.contains("alac") { return "ALAC" }
            return suffix.uppercased()
        }
    }
}

nonisolated enum ReleaseDateFormatting {
    static func fullDate(from itemDate: ItemDate?) -> String? {
        guard let itemDate, let year = itemDate.year else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = itemDate.month ?? 1
        components.day = itemDate.day ?? 1
        guard let date = Calendar.current.date(from: components) else {
            return String(year)
        }
        return date.formatted(date: .long, time: .omitted)
    }

    static func yearOnly(from itemDate: ItemDate?) -> Int? {
        itemDate?.year
    }

    /// Year-only label for the album header. Korean shows "2026년"; otherwise "2026".
    static func yearLabel(_ year: Int) -> String {
        if AppLanguage.current == .korean {
            return "\(year)년"
        }
        return "\(year)"
    }

    /// Full display date for the album metadata footer.
    /// Korean uses "2026년 12월 31일" (year-only when month/day are missing);
    /// other languages fall back to the locale-long date, then a bare year.
    static func displayDate(from itemDate: ItemDate?, fallbackYear: Int?) -> String? {
        if AppLanguage.current == .korean {
            return koreanDisplayDate(from: itemDate, fallbackYear: fallbackYear)
        }
        return fullDate(from: itemDate) ?? fallbackYear.map(String.init)
    }

    private static func koreanDisplayDate(from itemDate: ItemDate?, fallbackYear: Int?) -> String? {
        guard let itemDate, let year = itemDate.year else {
            return fallbackYear.map { "\($0)년" }
        }
        if let month = itemDate.month, let day = itemDate.day {
            return "\(year)년 \(month)월 \(day)일"
        }
        if let month = itemDate.month {
            return "\(year)년 \(month)월"
        }
        return "\(year)년"
    }
}

nonisolated enum ArtistAlbumCategorizer {
    enum Section: String, CaseIterable, Identifiable {
        case albums = "Albums"
        case singles = "Singles & EPs"
        case compilations = "Compilations"
        case live = "Live Album"

        var id: String { rawValue }
    }

    static func sections(from albums: [AlbumID3]) -> [(Section, [AlbumID3])] {
        var buckets: [Section: [AlbumID3]] = [:]

        for album in albums {
            let section = classify(album)
            buckets[section, default: []].append(album)
        }

        return Section.allCases.compactMap { section in
            let items = buckets[section] ?? []
            // Keep the compilation shelf discoverable even when a server omits its release tags.
            guard !items.isEmpty || section == .compilations else { return nil }
            // Deduplicate: hide edition/remaster duplicates from the main list.
            // Only the original release per canonical title is shown; alternate
            // versions belong in the album detail "Other Versions" tab.
            let deduped = originalsOnly(items)
            return (section, sortedByNewest(deduped))
        }
    }

    /// Keeps one release per `AlbumVersionMatcher.canonicalTitle`, preferring the ORIGINAL
    /// (a title with no edition / remaster / anniversary / deluxe marker). Reissue / special
    /// edition versions are skipped here — they surface in the album detail "Other Versions"
    /// tab instead. When a group has no original, the newest release is kept.
    static func originalsOnly(_ albums: [AlbumID3]) -> [AlbumID3] {
        // Group by canonical title, then pick the original (or newest fallback) per group,
        // preserving a stable, newest-first ordering across groups.
        var byKey: [String: [AlbumID3]] = [:]
        var order: [String] = []
        for album in sortedByNewest(albums) {
            let key = AlbumVersionMatcher.canonicalTitle(album.name)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(album)
        }

        return order.compactMap { key in
            guard let group = byKey[key] else { return nil }
            // Original first; groups are already newest-first, so `first(where:)` for
            // original preserves the newest original, and `group.first` is newest overall.
            return group.first(where: { AlbumVersionMatcher.isOriginalName($0.name) }) ?? group.first
        }
    }

    /// Newest first. Uses `releaseDate` → `originalReleaseDate` → `year`, then name.
    /// Sorting only by `year` left same-year / date-only albums in server order.
    static func sortedByNewest(_ albums: [AlbumID3]) -> [AlbumID3] {
        albums.sorted { lhs, rhs in
            let left = releaseSortKey(lhs)
            let right = releaseSortKey(rhs)
            if left != right { return left > right }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// YYYYMMDD integer for chronology. `0` = unknown (sorts oldest).
    /// Missing month/day defaults to Jan 1 so year-only entries sit after dated releases in that year.
    static func releaseSortKey(_ album: AlbumID3) -> Int {
        if let item = album.releaseDate ?? album.originalReleaseDate, let year = item.year {
            return year * 10_000 + (item.month ?? 1) * 100 + (item.day ?? 1)
        }
        if let year = album.year {
            return year * 10_000 + 101
        }
        return 0
    }

    static func classify(_ album: AlbumID3) -> Section {
        let name = album.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let genre = (album.genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let releaseTypes = (album.releaseTypes ?? []).map { $0.lowercased() }
        let genres = [genre] + (album.genres ?? []).map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let artistNames = [album.artist, album.displayArtist].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        // Live is often a secondary genre/release type, and may coexist with compilation.
        // Match bounded title markers so "Live Through This" / "Alive" stay studio albums.
        if genres.contains(where: isLiveGenre)
            || releaseTypes.contains(where: { $0.range(of: #"\blive\b"#, options: .regularExpression) != nil })
            || name.range(of: #"\blive\s+(at|in|from|on)\b|[\[(]\s*live\b|(?:^|\s-\s)live$|^live\s+\d{4}\b"#, options: .regularExpression) != nil {
            return .live
        }

        // Jellyfin and some OpenSubsonic servers omit isCompilation/releaseTypes but retain
        // the album artist. Do not rely on song count or multiple credited artists: those
        // would incorrectly turn ordinary collaborations into compilations.
        if album.isCompilation == true
            || releaseTypes.contains(where: { $0.contains("compilation") })
            || genres.contains(where: { ["compilation", "compilations", "compilation album", "compilation albums", "컴필레이션"].contains($0) })
            || artistNames.contains(where: { ["various artists", "various artist", "various", "v.a.", "v.a", "va", "여러 아티스트", "다양한 아티스트"].contains($0) })
            || name.contains("compilation") || name.contains("컴필레이션") {
            return .compilations
        }

        if releaseTypes.contains(where: { $0.contains("single") || $0.contains("ep") }) {
            return .singles
        }
        if name.hasSuffix(" single") || name.hasSuffix(" - single") || name.contains("single)") {
            return .singles
        }
        if album.songCount <= 3,
           name.contains("single") {
            return .singles
        }
        // Always classify EP-titled items (e.g. "The EP", " - EP", title containing " EP").
        if name.hasSuffix(" ep") || name.contains(" - ep") || name.hasPrefix("ep ") || name.contains(" ep ") {
            return .singles
        }
        return .albums
    }

    /// Matches tagged genres like "Live Album", "Live", "Live Albums".
    private static func isLiveGenre(_ genre: String) -> Bool {
        guard !genre.isEmpty else { return false }
        return genre.components(separatedBy: CharacterSet(charactersIn: ";,/|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { ["live", "live album", "live albums", "라이브", "라이브 앨범"].contains($0) }
    }
}
