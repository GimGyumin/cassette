import Foundation
import OSLog
import NaturalLanguage
@preconcurrency import Translation

nonisolated enum LyricsTranslationStrategy: String, Sendable {
    case highFidelity
    case lowLatency
    case standard

    var debugName: String {
        switch self {
        case .highFidelity: "appleIntelligence(highFidelity)"
        case .lowLatency: "translationFramework(lowLatency)"
        case .standard: "translationFramework(default)"
        }
    }
}

@MainActor
final class LyricsTranslationService {
    static let shared = LyricsTranslationService(cache: .shared)

    nonisolated struct Batch: Sendable {
        let requests: [TranslationSession.Request]
        let uniqueSources: [String]
        let sourceIndexByLine: [Int?]
    }

    private let cache: TranslationCache

    init(cache: TranslationCache) {
        self.cache = cache
    }

    nonisolated func detectedSourceLanguage(
        lines: [String],
        metadataLanguageCode: String?,
        targetLanguageCode: String
    ) -> String? {
        let sample = lines
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
            .joined(separator: "\n")

        if !sample.isEmpty,
           let detected = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue {
            let normalized = LyricsLanguage.normalizedLanguageCode(detected)
            if normalized != targetLanguageCode {
                return normalized
            }
        }

        let metadata = LyricsLanguage.normalizedLanguageCode(metadataLanguageCode)
        return metadata.isEmpty || metadata == targetLanguageCode ? nil : metadata
    }

    nonisolated func preferredStrategy(
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        sampleText: String
    ) async -> LyricsTranslationStrategy {
        guard #available(iOS 26.4, macOS 26.4, *) else {
            return .standard
        }

        let target = Locale.Language(identifier: targetLanguageCode)
        let availability = LanguageAvailability(preferredStrategy: .highFidelity)

        do {
            let status: LanguageAvailability.Status
            if let sourceLanguageCode,
               !sourceLanguageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let source = Locale.Language(identifier: sourceLanguageCode)
                status = await availability.status(from: source, to: target)
            } else {
                status = try await availability.status(for: sampleText, to: target)
            }
            return status == .unsupported ? .lowLatency : .highFidelity
        } catch {
            debugLog("Apple Intelligence translation availability failed; using Translation framework lowLatency")
            return .lowLatency
        }
    }

    nonisolated func configuration(
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        strategy: LyricsTranslationStrategy
    ) -> TranslationSession.Configuration {
        let source = sourceLanguageCode.map(Locale.Language.init(identifier:))
        let target = Locale.Language(identifier: targetLanguageCode)

        if #available(iOS 26.4, macOS 26.4, *) {
            switch strategy {
            case .highFidelity:
                return TranslationSession.Configuration(
                    source: source,
                    target: target,
                    preferredStrategy: .highFidelity
                )
            case .lowLatency:
                return TranslationSession.Configuration(
                    source: source,
                    target: target,
                    preferredStrategy: .lowLatency
                )
            case .standard:
                return TranslationSession.Configuration(source: source, target: target)
            }
        }

        return TranslationSession.Configuration(source: source, target: target)
    }

    nonisolated func translate(
        lines: [String],
        using session: TranslationSession
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard !lines.isEmpty else { return [] }

        try await session.prepareTranslation()
        try Task.checkCancellation()

        let batch = Self.makeBatch(lines: lines)
        guard !batch.requests.isEmpty else { return Array(repeating: "", count: lines.count) }

        let startedAt = ContinuousClock.now
        let responses = try await session.translations(from: batch.requests)
        try Task.checkCancellation()
        var translatedByIdentifier: [String: String] = [:]
        translatedByIdentifier.reserveCapacity(responses.count)
        for response in responses {
            guard let identifier = response.clientIdentifier else { continue }
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !translated.isEmpty {
                translatedByIdentifier[identifier] = translated
            }
        }
        let result = Self.merge(batch: batch, translatedByIdentifier: translatedByIdentifier)

        #if DEBUG
        let duration = startedAt.duration(to: .now)
        Logger.lyrics.debug(
            "Apple lyrics translation completed: lines=\(lines.count, privacy: .public), unique=\(batch.uniqueSources.count, privacy: .public), duration=\(String(describing: duration), privacy: .public)"
        )
        #endif

        return result
    }

    nonisolated static func makeBatch(lines: [String]) -> Batch {
        var uniqueSources: [String] = []
        var uniqueIndexByText: [String: Int] = [:]
        var sourceIndexByLine = Array<Int?>(repeating: nil, count: lines.count)

        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let uniqueIndex: Int
            if let existing = uniqueIndexByText[trimmed] {
                uniqueIndex = existing
            } else {
                uniqueIndex = uniqueSources.count
                uniqueSources.append(trimmed)
                uniqueIndexByText[trimmed] = uniqueIndex
            }
            sourceIndexByLine[lineIndex] = uniqueIndex
        }

        let requests = uniqueSources.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        return Batch(
            requests: requests,
            uniqueSources: uniqueSources,
            sourceIndexByLine: sourceIndexByLine
        )
    }

    nonisolated static func merge(
        batch: Batch,
        translatedByIdentifier: [String: String]
    ) -> [String] {
        batch.sourceIndexByLine.map { uniqueIndex in
            guard let uniqueIndex else { return "" }
            return translatedByIdentifier[String(uniqueIndex)] ?? ""
        }
    }

    func cachedTranslation(
        songID: String,
        sourceLanguage: String,
        targetLanguage: String,
        originalLines: [String],
        strategyPreference: TranslationStrategyPreference
    ) -> [TranslatedLyric]? {
        cache.get(
            songID: cacheSongID(songID, strategyPreference: strategyPreference),
            sourceLang: sourceLanguage,
            targetLang: targetLanguage,
            provider: .apple,
            originalLines: originalLines
        )
    }

    func storeTranslation(
        _ lyrics: [TranslatedLyric],
        songID: String,
        sourceLanguage: String,
        targetLanguage: String,
        strategyPreference: TranslationStrategyPreference
    ) {
        cache.set(
            lyrics,
            songID: cacheSongID(songID, strategyPreference: strategyPreference),
            sourceLang: sourceLanguage,
            targetLang: targetLanguage,
            provider: .apple
        )
    }

    func clearCache() {
        cache.clear()
    }

    private func cacheSongID(
        _ songID: String,
        strategyPreference: TranslationStrategyPreference
    ) -> String {
        "\(songID)|apple-strategy:\(strategyPreference.rawValue)"
    }

    func debugStart(
        trackID: String,
        sourceLanguage: String,
        targetLanguage: String,
        strategy: LyricsTranslationStrategy,
        lineCount: Int,
        cacheHit: Bool
    ) {
        #if DEBUG
        Logger.lyrics.debug(
            "Apple lyrics translation: track=\(trackID, privacy: .public), \(sourceLanguage, privacy: .public)->\(targetLanguage, privacy: .public), engine=\(strategy.debugName, privacy: .public), lines=\(lineCount, privacy: .public), cache=\(cacheHit ? "hit" : "miss", privacy: .public)"
        )
        #endif
    }

    func debugFallback(trackID: String) {
        #if DEBUG
        Logger.lyrics.debug(
            "Apple lyrics translation fallback: track=\(trackID, privacy: .public), Apple Intelligence highFidelity -> Translation framework lowLatency"
        )
        #endif
    }

    func debugCancellation(trackID: String) {
        #if DEBUG
        Logger.lyrics.debug(
            "Apple lyrics translation cancelled: track=\(trackID, privacy: .public)"
        )
        #endif
    }

    nonisolated private func debugLog(_ message: String) {
        #if DEBUG
        Logger.lyrics.debug("\(message, privacy: .public)")
        #endif
    }
}
