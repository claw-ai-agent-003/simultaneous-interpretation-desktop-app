import Foundation
import NaturalLanguage

// ============================================================
// MARK: - Language Detector
// ============================================================

/// Detects the language of Whisper transcription text at word level.
///
/// Primary implementation uses Apple's `NLTagger` (NaturalLanguage framework),
/// which runs entirely on-device with no network dependency and meets the
/// <10ms per-sentence performance target on Apple Silicon.
///
/// A lightweight heuristic fallback is available for environments where
/// NLTagger may not be available or for additional disambiguation.
///
/// ## Upgrade Path
/// fastText-based detection can be substituted behind the same protocol
/// for scenarios requiring higher accuracy on very short fragments.
/// The interface is designed to be agnostic to the detection backend.
final class LanguageDetector: Sendable {

    // MARK: - Properties

    private let config: CodeSwitchingConfig

    // MARK: - Init

    init(config: CodeSwitchingConfig = CodeSwitchingConfig()) {
        self.config = config
    }

    // MARK: - Public API

    /// Detects language for each token in the given text.
    ///
    /// - Parameter text: Whisper transcription text (a sentence or paragraph).
    /// - Returns: `LanguageDetectionResult` with per-token language tags.
    ///
    /// Performance: <10ms per sentence on Apple Silicon (M1+).
    func detect(text: String) -> LanguageDetectionResult {
        let t0 = CFAbsoluteTimeGetCurrent()

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            return LanguageDetectionResult(
                tokens: [],
                dominantLanguage: .unknown,
                isMixed: false,
                detectionLatencySeconds: 0,
                originalText: text
            )
        }

        let taggedTokens: [TaggedToken]

        if config.useNLTagger {
            taggedTokens = detectWithNLTagger(text: cleanText)
        } else {
            taggedTokens = detectWithHeuristics(text: cleanText)
        }

        // Compute dominant language
        let langCounts = countLanguages(tokens: taggedTokens)
        let dominant = dominantLanguage(from: langCounts)

        // Determine if mixed
        let isMixed = langCounts.count > 1

        let latency = CFAbsoluteTimeGetCurrent() - t0

        return LanguageDetectionResult(
            tokens: taggedTokens,
            dominantLanguage: dominant,
            isMixed: isMixed,
            detectionLatencySeconds: latency,
            originalText: text
        )
    }

    // MARK: - NLTagger-Based Detection (Primary)

    /// Uses Apple's NLTagger for token-level language detection.
    /// NLTagger provides on-device NLP with high accuracy for en/zh.
    private func detectWithNLTagger(text: String) -> [TaggedToken] {
        let tagger = NLTagger(tagSchemes: [.language, .lexicalClass])
        tagger.string = text

        let range = text.startIndex..<text.endIndex
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]

        var tokens: [TaggedToken] = []
        var index = 0

        tagger.enumerateTags(in: range, unit: .word, scheme: .language, options: options) { tag, tokenRange in
            let word = String(text[tokenRange])
            let language = resolveNLTag(tag)

            tokens.append(TaggedToken(
                text: word,
                language: language,
                isProtectedTerm: false,  // Filled in later by CodeSwitchingService
                index: index
            ))
            index += 1
            return true
        }

        return tokens
    }

    /// Converts an NLTagger language tag to our LanguageTag.
    private func resolveNLTag(_ tag: NLTag?) -> LanguageTag {
        guard let tag = tag else { return .unknown }

        let raw = tag.rawValue.lowercased()

        // Chinese variants
        if raw.hasPrefix("zh") || raw == "chinese" || raw.contains("hans") || raw.contains("hant") {
            return .chinese
        }

        // English
        if raw.hasPrefix("en") || raw == "english" {
            return .english
        }

        return .unknown
    }

    // MARK: - Heuristic Fallback

    /// Lightweight rule-based language detection for environments without NLTagger.
    ///
    /// Heuristics:
    /// - If a token contains any CJK characters → Chinese
    /// - If a token contains only Latin characters → English
    /// - Mixed tokens (Latin + CJK) → Unknown
    /// - Punctuation-only → Unknown
    private func detectWithHeuristics(text: String) -> [TaggedToken] {
        // Split on whitespace while preserving the tokens
        let words = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        return words.enumerated().map { (index, word) in
            let language = classifyWord(word)
            return TaggedToken(
                text: word,
                language: language,
                isProtectedTerm: false,
                index: index
            )
        }
    }

    /// Classifies a single word based on character scripts.
    private func classifyWord(_ word: String) -> LanguageTag {
        var hasLatin = false
        var hasCJK = false
        var hasDigit = false

        for char in word {
            let category = char.unicodeCategory
            if category == .lowercaseLetter || category == .uppercaseLetter {
                // Check if Latin script
                if char.isASCII || char.isLatin {
                    hasLatin = true
                } else if isCJK(char) {
                    hasCJK = true
                }
            }
            if category == .decimalNumber {
                hasDigit = true
            }
        }

        if hasCJK && hasLatin {
            return .mixed
        } else if hasCJK {
            return .chinese
        } else if hasLatin || hasDigit {
            return .english
        }

        return .unknown
    }

    /// Checks if a character is CJK.
    private func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let value = scalar.value
        // CJK Unified Ideographs
        return (0x4E00...0x9FFF).contains(value) ||
               // CJK Extension A
               (0x3400...0x4DBF).contains(value) ||
               // CJK Extension B
               (0x20000...0x2A6DF).contains(value) ||
               // CJK Compatibility Ideographs
               (0xF900...0xFAFF).contains(value) ||
               // CJK Radicals Supplement
               (0x2E80...0x2EFF).contains(value) ||
               // Kangxi Radicals
               (0x2F00...0x2FDF).contains(value) ||
               // CJK Symbols and Punctuation
               (0x3000...0x303F).contains(value) ||
               // Hiragana (Japanese, but counts as CJK in our heuristic)
               (0x3040...0x309F).contains(value) ||
               // Katakana
               (0x30A0...0x30FF).contains(value)
    }

    // MARK: - Helpers

    /// Counts tokens per language.
    private func countLanguages(tokens: [TaggedToken]) -> [LanguageTag: Int] {
        var counts: [LanguageTag: Int] = [:]
        for token in tokens where token.language != .unknown {
            counts[token.language, default: 0] += 1
        }
        return counts
    }

    /// Determines the dominant language from a count dictionary.
    private func dominantLanguage(from counts: [LanguageTag: Int]) -> LanguageTag {
        guard let (lang, _) = counts.max(by: { $0.value < $1.value }) else {
            return .unknown
        }
        return lang
    }
}
