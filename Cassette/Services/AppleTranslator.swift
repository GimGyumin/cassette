import Foundation
@preconcurrency import Translation

final class AppleTranslator {

    /// Lines per translation request — enough context for natural phrasing.
    private let bundleSize: Int

    init(bundleSize: Int = LyricTranslationBundler.defaultBundleSize) {
        self.bundleSize = bundleSize
    }

    func translate(
        lyrics: [String],
        using session: TranslationSession
    ) async throws -> [String] {

        print("🎬 [AppleTranslator] translate() 함수 진입 완료. 총 \(lyrics.count)줄 처리 시작.")

        guard !lyrics.isEmpty else {
            print("⚠️ [AppleTranslator] 빈 가사 배열이 들어와 즉시 종료합니다.")
            return []
        }

        let bundles = LyricTranslationBundler.makeBundles(from: lyrics, bundleSize: bundleSize)
        guard !bundles.isEmpty else {
            print("⚠️ [AppleTranslator] 실제 번역할 텍스트가 없어 원본 가사를 그대로 반환합니다.")
            return lyrics
        }

        var requests: [TranslationSession.Request] = []
        for (bundleIndex, bundle) in bundles.enumerated() {
            requests.append(
                TranslationSession.Request(
                    sourceText: bundle.joinedText,
                    clientIdentifier: String(bundleIndex)
                )
            )
        }

        // Fewer, larger requests than the old per-line path.
        let chunkSize = 8
        var translatedBlocks = Array(repeating: "", count: bundles.count)
        let chunks = requests.chunked(into: chunkSize)

        print("📦 [AppleTranslator] \(lyrics.count)줄을 \(bundles.count)묶음으로 나눠 번역합니다. (묶음당 최대 \(bundleSize)줄, 요청 그룹 \(chunks.count)개)")

        for (chunkIndex, chunk) in chunks.enumerated() {
            // Never call `session.translations` after cancel — Apple fatal-errors instead of throwing.
            // Do NOT wrap `translations` in a task-group timeout: cancelling mid-call also fatal-errors.
            try Task.checkCancellation()
            print("🔄 [AppleTranslator] [그룹 \(chunkIndex + 1)/\(chunks.count)] 번역 요청 시작...")

            do {
                let chunkResponses = try await session.translations(from: chunk)
                for response in chunkResponses {
                    guard
                        let id = response.clientIdentifier,
                        let bundleIndex = Int(id),
                        bundles.indices.contains(bundleIndex)
                    else { continue }
                    translatedBlocks[bundleIndex] = response.targetText
                }
                print("✅ [AppleTranslator] [그룹 \(chunkIndex + 1)/\(chunks.count)] 번역 완료! (\(chunkResponses.count)묶음 수신)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("❌ [AppleTranslator] [그룹 \(chunkIndex + 1)/\(chunks.count)] 번역 중 에러 발생: \(error.localizedDescription)")
                throw error
            }
        }

        // Bundle-level fallback: if a block is empty, re-translate that bundle line-by-line.
        for (bundleIndex, block) in translatedBlocks.enumerated() where block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Task.checkCancellation()
            let bundle = bundles[bundleIndex]
            print("↩️ [AppleTranslator] 묶음 \(bundleIndex) 비어 있음 — 줄 단위로 재시도")
            translatedBlocks[bundleIndex] = try await translateLinesIndividually(
                bundle.originalLines,
                using: session
            ).joined(separator: "\n")
        }

        let translated = LyricTranslationBundler.apply(
            bundles: bundles,
            translatedBlocks: translatedBlocks,
            into: lyrics
        )

        print("🎉 [AppleTranslator] 묶음 번역을 각 줄에 재배치 완료.")
        return translated
    }

    /// Last-resort path when a bundled response is empty.
    private func translateLinesIndividually(
        _ lines: [String],
        using session: TranslationSession
    ) async throws -> [String] {
        try Task.checkCancellation()
        let requests = lines.enumerated().compactMap { index, line -> TranslationSession.Request? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return TranslationSession.Request(sourceText: line, clientIdentifier: String(index))
        }
        guard !requests.isEmpty else { return lines }

        let responses = try await session.translations(from: requests)

        var result = lines
        for response in responses {
            guard let id = response.clientIdentifier, let index = Int(id), lines.indices.contains(index) else {
                continue
            }
            let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result[index] = text
            }
        }
        return result
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
