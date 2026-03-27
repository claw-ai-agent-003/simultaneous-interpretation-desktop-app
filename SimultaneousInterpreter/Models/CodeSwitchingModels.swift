import Foundation

// ============================================================
// MARK: - Language Tag
// ============================================================

/// Detected language for a token or segment.
enum LanguageTag: String, Sendable, Codable, Equatable {
    case english = "en"
    case chinese = "zh"
    case mixed   = "mixed"
    case unknown = "unknown"
}

// ============================================================
// MARK: - Tagged Token
// ============================================================

/// A single token (word or character cluster) with its detected language.
struct TaggedToken: Sendable, Equatable {
    /// The token text.
    let text: String

    /// Detected language tag.
    let language: LanguageTag

    /// Whether this token matches a protected term in the dictionary.
    let isProtectedTerm: Bool

    /// Zero-based index within the original sentence.
    let index: Int
}

// ============================================================
// MARK: - Language Detection Result
// ============================================================

/// Result of language detection on a sentence.
struct LanguageDetectionResult: Sendable {
    /// Individual tokens with their language tags.
    let tokens: [TaggedToken]

    /// Overall dominant language of the sentence.
    let dominantLanguage: LanguageTag

    /// Whether this sentence contains mixed languages (code-switching).
    let isMixed: Bool

    /// Detection latency in seconds.
    let detectionLatencySeconds: Double

    /// The original input text.
    let originalText: String
}

// ============================================================
// MARK: - Code-Switching Segment
// ============================================================

/// A homogeneous segment extracted from mixed-language text.
/// Each segment contains text of a single language or is a mixed/protected fragment.
struct CodeSwitchSegment: Sendable, Equatable {
    /// The segment text.
    let text: String

    /// Detected language of this segment.
    let language: LanguageTag

    /// Whether this segment contains code-switching (mixed languages).
    let isMixed: Bool

    /// Whether this segment should be preserved as-is (protected terms / mixed).
    let shouldPreserve: Bool

    /// Translation action to take for this segment.
    let translationAction: TranslationAction
}

// ============================================================
// MARK: - Translation Action
// ============================================================

/// Determines what to do with a segment before/instead of NLLB translation.
enum TranslationAction: Sendable, Equatable {
    /// Translate from source to target language via NLLB.
    case translate(sourceLanguage: String, targetLanguage: String)

    /// Keep the original text — do not send to NLLB.
    /// Used for mixed segments and protected-term-only segments.
    case preserve
}

// ============================================================
// MARK: - Processed Segment
// ============================================================

/// A segment that has been processed by the code-switching service,
/// ready for display or NLLB translation.
struct ProcessedSegment: Sendable {
    /// The original segment text.
    let original: String

    /// Translation action for this segment.
    let action: TranslationAction

    /// Protected terms found within this segment (for visual markup).
    let protectedTerms: [String]

    /// Language of this segment.
    let language: LanguageTag

    /// Final display text — either the NLLB translation or preserved original.
    /// Set after translation completes; initially nil for segments needing NLLB.
    var translatedText: String?

    /// Whether this segment still needs translation.
    var needsTranslation: Bool {
        switch action {
        case .translate: return translatedText == nil
        case .preserve:  return false
        }
    }

    /// The text to display — translated or preserved original.
    var displayText: String {
        return translatedText ?? original
    }
}

// ============================================================
// MARK: - Code-Switching Pipeline Result
// ============================================================

/// Full result of processing a Whisper transcription through the code-switching pipeline.
struct CodeSwitchingResult: Sendable {
    /// Individual segments after code-switching analysis.
    let segments: [ProcessedSegment]

    /// Whether code-switching was detected in the input.
    let hasCodeSwitching: Bool

    /// The original Whisper transcription text.
    let originalText: String

    /// Processing latency in seconds (language detection + segmentation).
    let processingLatencySeconds: Double

    /// Number of segments that will be sent to NLLB.
    var segmentsNeedingTranslation: Int {
        segments.filter(\.needsTranslation).count
    }

    /// Number of segments preserved as-is (mixed / protected).
    var segmentsPreserved: Int {
        segments.filter { $0.action == .preserve }.count
    }

    /// Reconstructed display text: translated segments + preserved originals interleaved.
    var reconstructedText: String {
        return segments.map(\.displayText).joined(separator: " ")
    }
}

// ============================================================
// MARK: - Term Dictionary Entry
// ============================================================

/// A single entry in the terminology dictionary.
struct TermEntry: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier (auto-generated from term + language).
    var id: String

    /// The term text (e.g. "API", "核心竞争力").
    let term: String

    /// Language of the term.
    let language: LanguageTag

    /// Whether this term should be preserved (not translated).
    let keep: Bool

    /// Optional category for organization.
    let category: TermCategory?

    init(term: String, language: LanguageTag, keep: Bool = true, category: TermCategory? = nil) {
        self.id = "\(term.lowercased())-\(language.rawValue)"
        self.term = term
        self.language = language
        self.keep = keep
        self.category = category
    }
}

// ============================================================
// MARK: - Term Category
// ============================================================

/// Categories for terminology entries.
enum TermCategory: String, Sendable, Codable, Equatable {
    case technology    = "technology"
    case business      = "business"
    case finance       = "finance"
    case management    = "management"
    case general       = "general"
    case custom        = "custom"
}

// ============================================================
// MARK: - Code-Switching Configuration
// ============================================================

/// Configuration for the code-switching detection and handling service.
struct CodeSwitchingConfig: Sendable {
    /// Whether code-switching handling is enabled.
    /// When false, the pipeline behaves identically to the original Whisper→NLLB flow.
    var enabled: Bool = true

    /// Minimum confidence threshold for language detection (0.0–1.0).
    /// Below this, tokens are marked as unknown.
    var detectionConfidenceThreshold: Float = 0.5

    /// Maximum number of characters in a segment sent to NLLB.
    /// Segments longer than this are split further.
    var maxSegmentLength: Int = 200

    /// Whether to use Apple's NLTagger for language detection.
    /// When false, falls back to a lightweight heuristic engine.
    var useNLTagger: Bool = true

    /// Whether to enable the term dictionary for protection.
    var termProtectionEnabled: Bool = true

    /// UserDefaults key for custom term dictionary storage.
    var customTermsUserDefaultsKey: String = "com.interpretation.customTermDictionary"
}
