import Foundation

enum TranslationSource: String, Codable, Equatable, Hashable, Sendable {
    case ttml
    case appleAPI
    case openAI
    case server
    case none
}

struct TranslatedLyric: Identifiable, Hashable, Codable {
    var id: UUID
    let time: TimeInterval
    let originalText: String
    let translatedText: String
    /// Background / chorus translation extracted from TTML `<span ttm:role="x-bg">`.
    /// Never merged into `translatedText` — rendered as a separate secondary line.
    let backgroundTranslation: String
    /// Start of the x-bg span inside the translation (seconds) — the translation's own
    /// timing, NOT the main line's begin. `nil` when the x-bg span is untimed.
    let backgroundBegin: Double?
    /// End of the x-bg span inside the translation (seconds). `nil` when untimed.
    let backgroundEnd: Double?
    /// OpenSubsonic songLyrics v2 pronunciation / reading layer (e.g. furigana).
    let pronunciationText: String
    let isBlank: Bool
    let translationSource: TranslationSource

    init(
        id: UUID = UUID(),
        time: TimeInterval,
        originalText: String,
        translatedText: String,
        backgroundTranslation: String = "",
        backgroundBegin: Double? = nil,
        backgroundEnd: Double? = nil,
        pronunciationText: String = "",
        isBlank: Bool,
        translationSource: TranslationSource = .none
    ) {
        self.id = id
        self.time = time
        self.originalText = originalText
        self.translatedText = translatedText
        self.backgroundTranslation = backgroundTranslation
        self.backgroundBegin = backgroundBegin
        self.backgroundEnd = backgroundEnd
        self.pronunciationText = pronunciationText
        self.isBlank = isBlank
        self.translationSource = translationSource
    }

    enum CodingKeys: String, CodingKey {
        case id
        case time
        case originalText
        case translatedText
        case backgroundTranslation
        case backgroundBegin
        case backgroundEnd
        case pronunciationText
        case isBlank
        case translationSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.time = try container.decode(TimeInterval.self, forKey: .time)
        self.originalText = try container.decode(String.self, forKey: .originalText)
        self.translatedText = try container.decode(String.self, forKey: .translatedText)
        self.backgroundTranslation = try container.decodeIfPresent(String.self, forKey: .backgroundTranslation) ?? ""
        self.backgroundBegin = try container.decodeIfPresent(Double.self, forKey: .backgroundBegin)
        self.backgroundEnd = try container.decodeIfPresent(Double.self, forKey: .backgroundEnd)
        self.pronunciationText = try container.decodeIfPresent(String.self, forKey: .pronunciationText) ?? ""
        self.isBlank = try container.decode(Bool.self, forKey: .isBlank)
        self.translationSource = try container.decodeIfPresent(TranslationSource.self, forKey: .translationSource) ?? .none
    }
}