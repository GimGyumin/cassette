import Foundation
import OSLog

final class OpenAITranslator: LyricsTranslator {
    private let bundleSize: Int
    /// Prefer 4.1-mini; fall back for accounts that only expose 4o-mini.
    private static let preferredModels = ["gpt-4.1-mini", "gpt-4o-mini"]

    init(bundleSize: Int = 8) {
        self.bundleSize = bundleSize
    }

    func translate(lyrics: [String], sourceLanguage: String, targetLanguage: String) async throws -> [String] {
        let apiKey = Self.resolvedAPIKey()
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey
        }

        let bundles = LyricTranslationBundler.makeBundles(from: lyrics, bundleSize: bundleSize)
        guard !bundles.isEmpty else { return lyrics }

        var translatedBlocks: [String] = []
        translatedBlocks.reserveCapacity(bundles.count)

        for bundle in bundles {
            let block = try await translateBundle(
                text: bundle.joinedText,
                lineCount: bundle.originalLines.count,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                apiKey: apiKey
            )
            translatedBlocks.append(block)
        }

        return LyricTranslationBundler.apply(
            bundles: bundles,
            translatedBlocks: translatedBlocks,
            into: lyrics
        )
    }

    /// Read from in-memory settings and the Keychain, then sanitize.
    private static func resolvedAPIKey() -> String {
        let fromMemory = LyricsTranslationSettings.shared.openAIAPIKey
        let fromKeychain = SensitiveSettingsStore.string(forKey: LyricsTranslationSettings.openAIAPIKeyKey) ?? ""
        var key = fromMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            key = fromKeychain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    private func translateBundle(
        text: String,
        lineCount: Int,
        sourceLanguage: String,
        targetLanguage: String,
        apiKey: String
    ) async throws -> String {
        var lastError: Error?
        for model in Self.preferredModels {
            do {
                return try await translateBundleOnce(
                    text: text,
                    lineCount: lineCount,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    apiKey: apiKey,
                    model: model
                )
            } catch {
                lastError = error
                if shouldTryNextModel(error) {
                    Logger.lyrics.warning(
                        "OpenAI model \(model, privacy: .public) failed — trying fallback: \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
                throw error
            }
        }
        throw lastError ?? TranslationError.networkError("OpenAI request failed")
    }

    private func shouldTryNextModel(_ error: Error) -> Bool {
        guard case TranslationError.networkError(let msg) = error else { return false }
        return msg.contains("404")
            || msg.localizedCaseInsensitiveContains("model")
            || msg.localizedCaseInsensitiveContains("does not exist")
    }

    private func translateBundleOnce(
        text: String,
        lineCount: Int,
        sourceLanguage: String,
        targetLanguage: String,
        apiKey: String,
        model: String
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let systemPrompt = """
        You are a professional song lyric translator.
        Translate from \(sourceLanguage) into \(targetLanguage).

        The input is \(lineCount) lyric lines joined by newlines. Translate them as one natural, coherent passage — use surrounding lines for context and fluent phrasing. Do not translate word-for-word in isolation.

        Then split your translation back into exactly \(lineCount) lines (separated by a single newline), one output line per input line. Redistribute wording across those lines so each line reads naturally; do not merge or omit lines.
        Preserve blank lines only if they appear in the input.
        Return ONLY the \(lineCount) translated lines. No explanations, titles, or markup.
        """

        let jsonBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.35
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.networkError(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyText = String(data: data, encoding: .utf8) ?? ""

        guard status == 200 else {
            let snippet = String(
                bodyText
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(220)
            )
            if status == 401 || status == 403 {
                throw TranslationError.invalidAPIKey
            }
            if bodyText.contains("billing_not_active")
                || bodyText.localizedCaseInsensitiveContains("billing details")
                || bodyText.localizedCaseInsensitiveContains("account is not active") {
                throw TranslationError.billingInactive
            }
            if status == 429 {
                throw TranslationError.rateLimited
            }
            throw TranslationError.networkError("OpenAI HTTP \(status): \(snippet)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parsingError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
