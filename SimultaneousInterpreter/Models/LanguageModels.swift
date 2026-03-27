import Foundation

// ============================================================
// MARK: - LanguageCode
// ============================================================

/// Supported language codes for the interpreter.
/// Extend with additional cases to add more languages.
/// Each case corresponds to a BCP-47 tag and NLLB-200 / Whisper language code.
enum LanguageCode: String, CaseIterable, Codable, Sendable {
    case en   /// English
    case zh   /// Mandarin Chinese (simplified)
    case ja   /// Japanese
    case ko   /// Korean
    case ext  /// Reserved extension slot

    // MARK: - Properties

    /// BCP-47 tag for this language.
    var bcp47: String {
        switch self {
        case .en:  return "en"
        case .zh:  return "zh"
        case .ja:  return "ja"
        case .ko:  return "ko"
        case .ext: return "ext"
        }
    }

    /// NLLB-200 language code used as forced decoder token.
    var nllbCode: String {
        switch self {
        case .en:  return "eng_Latn"
        case .zh:  return "zho_Hans"
        case .ja:  return "jpn_Jpan"
        case .ko:  return "kor_Hang"
        case .ext: return "eng_Latn"
        }
    }

    /// NLLB forced decoder token ID.
    /// Used as the forced target language token during NLLB decoding.
    var nllbTokenID: Int {
        switch self {
        case .en:  return 66804
        case .zh:  return 70426
        case .ja:  return 88880
        case .ko:  return 98535
        case .ext: return 66804
        }
    }

    /// Display name for UI labels.
    var displayName: String {
        switch self {
        case .en:  return "English"
        case .zh:  return "中文"
        case .ja:  return "日本語"
        case .ko:  return "한국어"
        case .ext: return "Extension"
        }
    }

    /// Short label shown on segment rows.
    /// Chinese shows "中", English shows "EN", Japanese shows "日", Korean shows "한".
    var shortLabel: String {
        switch self {
        case .en:  return "EN"
        case .zh:  return "中"
        case .ja:  return "日"
        case .ko:  return "한"
        case .ext: return "?"
        }
    }

    /// Language tag used as Whisper decoder prompt (e.g. <<en>>, <<zh>>).
    var whisperPromptTag: String {
        ">>\(bcp47)<<"
    }

    /// Whether this language is currently supported for translation and transcription.
    var isActive: Bool {
        switch self {
        case .en, .zh, .ja, .ko:
            return true
        case .ext:
            return false
        }
    }
}

// ============================================================
// MARK: - LanguagePair
// ============================================================

/// Represents a directional language pair: source → target.
/// For example, en→zh means "transcribe in English, translate to Mandarin".
struct LanguagePair: Codable, Equatable, Hashable, Sendable {

    /// The language being spoken / transcribed.
    let source: LanguageCode

    /// The language to translate into for display.
    let target: LanguageCode

    /// Human-readable label, e.g. "EN → 中文".
    var displayLabel: String {
        "\(source.shortLabel) → \(target.shortLabel)"
    }

    /// Full description, e.g. "English → Mandarin Chinese".
    var description: String {
        "\(source.displayName) → \(target.displayName)"
    }

    /// Returns the reverse pair (swap source and target).
    var reversed: LanguagePair {
        LanguagePair(source: target, target: source)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case source, target
    }

    init(source: LanguageCode, target: LanguageCode) {
        self.source = source
        self.target = target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceRaw = try container.decode(String.self, forKey: .source)
        let targetRaw = try container.decode(String.self, forKey: .target)
        guard let source = LanguageCode(rawValue: sourceRaw),
              let target = LanguageCode(rawValue: targetRaw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid language code"
                )
            )
        }
        self.source = source
        self.target = target
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source.rawValue, forKey: .source)
        try container.encode(target.rawValue, forKey: .target)
    }
}

// ============================================================
// MARK: - SupportedLanguages
// ============================================================

/// Configuration for available and default language pairs.
struct SupportedLanguages: Codable, Sendable {

    // MARK: - Supported Pairs

    /// All supported language pairs. Ordered by priority for display.
    let pairs: [LanguagePair]

    /// Default language pair (index into `pairs`).
    let defaultPairIndex: Int

    /// All supported individual language codes (deduplicated).
    var supportedLanguageCodes: [LanguageCode] {
        var seen = Set<LanguageCode>()
        for pair in pairs {
            seen.insert(pair.source)
            seen.insert(pair.target)
        }
        return Array(seen).sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Defaults

    /// Default multi-language configuration: EN↔ZH, EN↔JA, EN↔KO.
    static let `default` = SupportedLanguages(
        pairs: [
            LanguagePair(source: .en, target: .zh),
            LanguagePair(source: .zh, target: .en),
            LanguagePair(source: .en, target: .ja),
            LanguagePair(source: .ja, target: .en),
            LanguagePair(source: .en, target: .ko),
            LanguagePair(source: .ko, target: .en),
        ],
        defaultPairIndex: 0
    )

    /// Loads supported languages from languages.json in the app bundle.
    static func loadFromBundle() -> SupportedLanguages {
        guard let url = Bundle.main.url(forResource: "languages", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SupportedLanguages.self, from: data) else {
            return .default
        }
        return config
    }
}

// ============================================================
// MARK: - LanguageSwitchEvent
// ============================================================

/// Broadcast when the active language pair changes.
struct LanguageSwitchEvent: Sendable {
    let previousPair: LanguagePair
    let newPair: LanguagePair
    let changedAt: UInt64

    init(previous: LanguagePair, new: LanguagePair, changedAt: UInt64 = mach_absolute_time()) {
        self.previousPair = previous
        self.newPair = new
        self.changedAt = changedAt
    }
}
