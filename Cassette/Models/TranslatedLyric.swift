import Foundation

struct TranslatedLyric: Identifiable, Hashable, Codable {
    var id: UUID
    let time: TimeInterval
    let originalText: String
    let translatedText: String
    let isBlank: Bool

    // 일반 생성자 (ViewModel에서 매핑할 때 사용)
    init(id: UUID = UUID(), time: TimeInterval, originalText: String, translatedText: String, isBlank: Bool) {
        self.id = id
        self.time = time
        self.originalText = originalText
        self.translatedText = translatedText
        self.isBlank = isBlank
    }

    // Codable (디코딩)을 위한 생성자 (Cache에서 복원할 때 사용)
    enum CodingKeys: String, CodingKey {
        case id
        case time
        case originalText
        case translatedText
        case isBlank
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 캐시에 저장된 id가 없다면 새로 생성하여 컴파일러 경고 우회
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.time = try container.decode(TimeInterval.self, forKey: .time)
        self.originalText = try container.decode(String.self, forKey: .originalText)
        self.translatedText = try container.decode(String.self, forKey: .translatedText)
        self.isBlank = try container.decode(Bool.self, forKey: .isBlank)
    }
}
