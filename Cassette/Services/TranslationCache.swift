import Foundation
import CryptoKit
import OSLog

final class TranslationCache {
    static let shared = TranslationCache()

    private let memoryCache = NSCache<NSString, CachedTranslationBox>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    init(directory: URL? = nil) {
        // Application Support survives system cache purges (unlike Caches/).
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = directory ?? appSupport.appendingPathComponent("LyricsTranslations", isDirectory: true)
        memoryCache.countLimit = 64

        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        // One-time migrate from the old Caches location if present.
        let legacy = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsTranslations", isDirectory: true)
        if directory == nil { migrateLegacyCacheIfNeeded(from: legacy) }
    }

    private func migrateLegacyCacheIfNeeded(from legacy: URL) {
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: legacy,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in contents {
            let dest = cacheDirectory.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: dest.path) {
                try? fileManager.copyItem(at: file, to: dest)
            }
        }
        try? fileManager.removeItem(at: legacy)
    }

    private func makeKey(
        songID: String,
        sourceLang: String,
        targetLang: String,
        provider: String,
        contentFingerprint: String
    ) -> String {
        let components = [songID, sourceLang, targetLang, provider, contentFingerprint]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Stable fingerprint of source lines so lyric edits invalidate the cache.
    static func fingerprint(originalLines: [String]) -> String {
        let joined = originalLines.joined(separator: "\u{1e}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func set(
        _ lyrics: [TranslatedLyric],
        songID: String,
        sourceLang: String,
        targetLang: String,
        provider: TranslationProvider
    ) {
        let hasUseful = lyrics.contains {
            !$0.translatedText.isEmpty && $0.translatedText != $0.originalText
        }
        guard hasUseful else { return }

        let fingerprint = Self.fingerprint(originalLines: lyrics.map(\.originalText))
        let key = makeKey(
            songID: songID,
            sourceLang: sourceLang,
            targetLang: targetLang,
            provider: provider.rawValue,
            contentFingerprint: fingerprint
        )

        memoryCache.setObject(CachedTranslationBox(lyrics), forKey: key as NSString)

        let fileURL = cacheDirectory.appendingPathComponent(key)
        do {
            let data = try JSONEncoder().encode(lyrics)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Logger.lyrics.error("Failed to write translation cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    func get(
        songID: String,
        sourceLang: String,
        targetLang: String,
        provider: TranslationProvider,
        originalLines: [String]
    ) -> [TranslatedLyric]? {
        let fingerprint = Self.fingerprint(originalLines: originalLines)
        let key = makeKey(
            songID: songID,
            sourceLang: sourceLang,
            targetLang: targetLang,
            provider: provider.rawValue,
            contentFingerprint: fingerprint
        )

        if let boxed = memoryCache.object(forKey: key as NSString) {
            return matching(boxed.lyrics, originalLines: originalLines)
        }

        var fileURL = cacheDirectory.appendingPathComponent(key)
        if !fileManager.fileExists(atPath: fileURL.path) {
            let old = "\(songID)_\(sourceLang)_\(targetLang)_\(provider.rawValue)_\(fingerprint)"
            if let oldKey = old.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                fileURL = cacheDirectory.appendingPathComponent(oldKey)
            }
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            // Fall back to legacy keys (no fingerprint) from earlier builds.
            return getLegacy(
                songID: songID,
                sourceLang: sourceLang,
                targetLang: targetLang,
                provider: provider,
                originalLines: originalLines
            )
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let lyrics = try JSONDecoder().decode([TranslatedLyric].self, from: data)
            if let matched = matching(lyrics, originalLines: originalLines) {
                memoryCache.setObject(CachedTranslationBox(matched), forKey: key as NSString)
                return matched
            }
            return nil
        } catch {
            Logger.lyrics.error("Failed to read translation cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Older cache files keyed without a content fingerprint.
    private func getLegacy(
        songID: String,
        sourceLang: String,
        targetLang: String,
        provider: TranslationProvider,
        originalLines: [String]
    ) -> [TranslatedLyric]? {
        let combined = "\(songID)_\(sourceLang)_\(targetLang)_\(provider.rawValue)"
        let key = combined.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? songID
        let fileURL = cacheDirectory.appendingPathComponent(key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            let lyrics = try JSONDecoder().decode([TranslatedLyric].self, from: data)
            guard let matched = matching(lyrics, originalLines: originalLines) else { return nil }
            // Rewrite under the new key so subsequent lookups skip legacy.
            set(matched, songID: songID, sourceLang: sourceLang, targetLang: targetLang, provider: provider)
            return matched
        } catch {
            return nil
        }
    }

    private func matching(
        _ lyrics: [TranslatedLyric],
        originalLines: [String]
    ) -> [TranslatedLyric]? {
        guard lyrics.count == originalLines.count else { return nil }
        for (lyric, original) in zip(lyrics, originalLines) where lyric.originalText != original {
            return nil
        }
        let hasUseful = lyrics.contains {
            !$0.translatedText.isEmpty && $0.translatedText != $0.originalText
        }
        return hasUseful ? lyrics : nil
    }

    func clear() {
        memoryCache.removeAllObjects()
        if let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in contents {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

private final class CachedTranslationBox: NSObject {
    let lyrics: [TranslatedLyric]
    init(_ lyrics: [TranslatedLyric]) {
        self.lyrics = lyrics
    }
}
