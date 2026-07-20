import Foundation

protocol LyricsTranslator {
    func translate(lyrics: [String], sourceLanguage: String, targetLanguage: String) async throws -> [String]
}

enum TranslationError: LocalizedError {
    case invalidAPIKey
    case networkError(String)
    case parsingError
    case lineCountMismatch(expected: Int, actual: Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "OpenAI API Key가 올바르지 않거나 비어있습니다."
        case .networkError(let msg):
            return "네트워크 오류: \(msg)"
        case .parsingError:
            return "번역 결과를 파싱하는 데 실패했습니다."
        case .lineCountMismatch(let exp, let act):
            return "원문 가사(\(exp)줄)와 번역 가사(\(act)줄)의 줄 수가 일치하지 않습니다."
        }
    }
}
