import Foundation

final class OpenAITranslator: LyricsTranslator {
    func translate(lyrics: [String], sourceLanguage: String, targetLanguage: String) async throws -> [String] {
        let apiKey = LyricsTranslationSettings.shared.openAIAPIKey
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey
        }
        
        let fullText = lyrics.joined(separator: "\n")
        
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let systemPrompt = """
        You are a professional song translator.
        Translate the lyrics from \(sourceLanguage) into the requested language: \(targetLanguage).
        
        Rules:
        - Keep exactly the same number of lines (\(lyrics.count) lines total).
        - Do NOT merge lines.
        - Do NOT split lines.
        - Preserve blank lines exactly as they are.
        - Preserve poetic meaning and subtext.
        - Return ONLY translated lyrics. No explanations, no introductory text, no note markup.
        """
        
        let jsonBody: [String: Any] = [
            "model": "gpt-4.1-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": fullText]
            ],
            "temperature": 0.3
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranslationError.networkError("OpenAI API returned status code \(status)")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parsingError
        }
        
        // 개행 단위로 쪼개어 가사 배열 생성
        let translatedLines = content.components(separatedBy: "\n")
        
        // 엄격한 원문 데이터 개수 동기화 확인
        if translatedLines.count != lyrics.count {
            // 줄 수가 가끔 맞지 않는 예외 상황 처리를 위해 빈 줄 패딩 보정 스크립트 가동
            if translatedLines.count > lyrics.count {
                return Array(translatedLines.prefix(lyrics.count))
            } else {
                var paddedLines = translatedLines
                while paddedLines.count < lyrics.count {
                    paddedLines.append("")
                }
                return paddedLines
            }
        }
        
        return translatedLines
    }
}
