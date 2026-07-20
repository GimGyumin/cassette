import Foundation
import Translation

final class AppleTranslator {
    
    // SwiftUI 뷰의 .translationTask에서 확보해 온 실제 session을 받아 처리합니다.
    func translate(
        lyrics: [String],
        using session: TranslationSession
    ) async throws -> [String] {
        
        guard !lyrics.isEmpty else { return [] }
        
        var validRequests: [TranslationSession.Request] = []
        var validIndices: [Int] = []
        
        for (index, line) in lyrics.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                validRequests.append(TranslationSession.Request(sourceText: line, clientIdentifier: String(index)))
                validIndices.append(index)
            }
        }
        
        guard !validRequests.isEmpty else { return lyrics }
        var translatedResults = [Int: String]()
        
        let responses = try await session.translations(from: validRequests)
        for response in responses {
            if let idString = response.clientIdentifier, let originalIndex = Int(idString) {
                translatedResults[originalIndex] = response.targetText
            }
        }
        
        return lyrics.enumerated().map { index, originalLine in
            if validIndices.contains(index) {
                return translatedResults[index] ?? originalLine
            } else {
                return ""
            }
        }
    }
}
