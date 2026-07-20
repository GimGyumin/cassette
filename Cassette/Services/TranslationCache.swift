import Foundation

final class TranslationCache {
    static let shared = TranslationCache()
    
    private let memoryCache = NSCache<NSString, AnyObject>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        self.cacheDirectory = paths[0].appendingPathComponent("LyricsTranslations")
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func makeKey(songID: String, sourceLang: String, targetLang: String, provider: String) -> String {
        let combined = "\(songID)_\(sourceLang)_\(targetLang)_\(provider)"
        return combined.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? songID
    }
    
    func set(_ lyrics: [TranslatedLyric], songID: String, sourceLang: String, targetLang: String, provider: TranslationProvider) {
        let key = makeKey(songID: songID, sourceLang: sourceLang, targetLang: targetLang, provider: provider.rawValue)
        
        // Memory Cache
        memoryCache.setObject(lyrics as NSArray, forKey: key as NSString)
        
        // Disk Cache
        let fileURL = cacheDirectory.appendingPathComponent(key)
        do {
            let data = try JSONEncoder().encode(lyrics)
            try data.write(to: fileURL)
        } catch {
            print("Failed to write translation cache to disk: \(error)")
        }
    }
    
    func get(songID: String, sourceLang: String, targetLang: String, provider: TranslationProvider) -> [TranslatedLyric]? {
        let key = makeKey(songID: songID, sourceLang: sourceLang, targetLang: targetLang, provider: provider.rawValue)
        
        // Check Memory Cache
        if let memoryLines = memoryCache.object(forKey: key as NSString) as? [TranslatedLyric] {
            return memoryLines
        }
        
        // Check Disk Cache
        let fileURL = cacheDirectory.appendingPathComponent(key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let lyrics = try JSONDecoder().decode([TranslatedLyric].self, from: data)
            // Restore Memory Cache
            memoryCache.setObject(lyrics as NSArray, forKey: key as NSString)
            return lyrics
        } catch {
            print("Failed to read translation cache from disk: \(error)")
            return nil
        }
    }
    
    func clear() {
        memoryCache.removeAllObjects()
        if let contents = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in contents {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
