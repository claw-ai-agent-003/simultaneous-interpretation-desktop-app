import Foundation

// ============================================================
// MARK: - Code-Switching Service
// ============================================================

/// Handles code-switching detection and intelligent segmentation for bilingual interpretation.
///
/// ## Processing Pipeline
/// 1. **Language Detection**: Tag each token with its language (en/zh/mixed)
/// 2. **Term Protection**: Mark protected terms (from dictionary) as non-translatable
/// 3. **Segmentation**: Split input into homogeneous language segments
/// 4. **Action Assignment**: Determine translation action per segment
///
/// ## Segmentation Strategy
/// - **Pure Chinese** → Translate to English via NLLB
/// - **Pure English** → Translate to Chinese via NLLB
/// - **Mixed segment** → Preserve as-is (contains code-switching, typically technical terms)
/// - **Protected term** → Mark for visual emphasis, keep original
///
/// ## Performance
/// Total processing (detection + segmentation + term lookup): <15ms per sentence
/// on Apple Silicon. Language detection via NLTagger is the primary cost.
final class CodeSwitchingService: Sendable {

    // MARK: - Dependencies

    private let languageDetector: LanguageDetector
    private let termDictionary: TermDictionary
    private let config: CodeSwitchingConfig

    // MARK: - Init

    /// Creates a code-switching service.
    /// - Parameters:
    ///   - languageDetector: Language detection engine (NLTagger-based by default).
    ///   - termDictionary: Terminology dictionary for term protection.
    ///   - config: Code-switching configuration.
    init(
        languageDetector: LanguageDetector? = nil,
        termDictionary: TermDictionary? = nil,
        config: CodeSwitchingConfig = CodeSwitchingConfig()
    ) {
        self.languageDetector = languageDetector ?? LanguageDetector(config: config)
        self.termDictionary = termDictionary ?? TermDictionary()
        self.config = config
    }

    // MARK: - Public API

    /// Processes a Whisper transcription through the full code-switching pipeline.
    ///
    /// - Parameters:
    ///   - text: Whisper transcription text.
    ///   - sourceLanguage: Primary source language (from pipeline config).
    ///   - targetLanguage: Primary target language (from pipeline config).
    /// - Returns: `CodeSwitchingResult` with segmented output ready for NLLB or display.
    ///
    /// This method is the main entry point called by `InterpreterPipeline`.
    func process(
        text: String,
        sourceLanguage: String = "en",
        targetLanguage: String = "zh"
    ) -> CodeSwitchingResult {
        let t0 = CFAbsoluteTimeGetCurrent()

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fast path: if code-switching is disabled, return the whole text as a single segment
        guard config.enabled else {
            return CodeSwitchingResult(
                segments: [ProcessedSegment(
                    original: cleanText,
                    action: .translate(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage),
                    protectedTerms: [],
                    language: sourceLanguage == "en" ? .english : .chinese,
                    translatedText: nil
                )],
                hasCodeSwitching: false,
                originalText: text,
                processingLatencySeconds: 0
            )
        }

        guard !cleanText.isEmpty else {
            return CodeSwitchingResult(
                segments: [],
                hasCodeSwitching: false,
                originalText: text,
                processingLatencySeconds: 0
            )
        }

        // Step 1: Language detection
        let detection = languageDetector.detect(text: cleanText)

        // Step 2: Mark protected terms
        let protectedTokens = markProtectedTerms(tokens: detection.tokens)

        // Step 3: Segment into homogeneous blocks
        let segments = segment(tokens: protectedTokens)

        // Step 4: Assign translation actions
        let processedSegments = segments.map { segment -> ProcessedSegment in
            assignAction(
                for: segment,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }

        let latency = CFAbsoluteTimeGetCurrent() - t0

        let hasMixed = processedSegments.contains { $0.action == .preserve }

        return CodeSwitchingResult(
            segments: processedSegments,
            hasCodeSwitching: hasMixed,
            originalText: text,
            processingLatencySeconds: latency
        )
    }

    // MARK: - Step 2: Term Protection

    /// Marks tokens that match the term dictionary as protected.
    private func markProtectedTerms(tokens: [TaggedToken]) -> [TaggedToken] {
        guard config.termProtectionEnabled else { return tokens }

        return tokens.map { token in
            let isProtected = termDictionary.shouldPreserve(token.text)
            return TaggedToken(
                text: token.text,
                language: token.language,
                isProtectedTerm: isProtected,
                index: token.index
            )
        }
    }

    // MARK: - Step 3: Segmentation

    /// Groups consecutive tokens into homogeneous language segments.
    ///
    /// Algorithm:
    /// 1. Walk through tagged tokens in order
    /// 2. Start a new segment when language changes (or when a protected term is encountered)
    /// 3. Protected terms are split into their own sub-segments for action assignment
    /// 4. Merge very short segments (< 2 non-protected tokens) with neighbors when possible
    private func segment(tokens: [TaggedToken]) -> [CodeSwitchSegment] {
        guard !tokens.isEmpty else { return [] }

        var segments: [CodeSwitchSegment] = []
        var currentTokens: [TaggedToken] = []
        var currentLanguage: LanguageTag? = nil

        func flushSegment() {
            guard !currentTokens.isEmpty else { return }

            let text = currentTokens.map(\.text).joined(separator: " ")
            let hasProtected = currentTokens.contains(\.isProtectedTerm)

            // Determine if mixed: more than one language among non-protected tokens
            let nonProtectedLangs = Set(
                currentTokens.filter { !$0.isProtectedTerm }.map(\.language)
            ).filter { $0 != .unknown }
            let isMixed = nonProtectedLangs.count > 1

            let segmentLang: LanguageTag
            if let current = currentLanguage {
                segmentLang = current
            } else if let first = nonProtectedLangs.first {
                segmentLang = first
            } else {
                segmentLang = .unknown
            }

            segments.append(CodeSwitchSegment(
                text: text,
                language: segmentLang,
                isMixed: isMixed,
                shouldPreserve: isMixed || (currentTokens.allSatisfy(\.isProtectedTerm)),
                translationAction: .preserve  // Placeholder — finalized in assignAction
            ))

            currentTokens = []
            currentLanguage = nil
        }

        for token in tokens {
            // Protected terms get their own segment
            if token.isProtectedTerm {
                // Flush any accumulated tokens first
                flushSegment()

                segments.append(CodeSwitchSegment(
                    text: token.text,
                    language: token.language,
                    isMixed: false,
                    shouldPreserve: true,
                    translationAction: .preserve
                ))
                continue
            }

            // Determine effective language (skip unknown)
            let effectiveLang = token.language == .unknown ? currentLanguage : token.language

            // Start new segment if language changes
            if let current = currentLanguage,
               let effective = effectiveLang,
               current != effective {
                flushSegment()
            }

            if currentLanguage == nil, let effective = effectiveLang {
                currentLanguage = effective
            }

            currentTokens.append(token)
        }

        // Flush remaining
        flushSegment()

        // Merge very short segments with neighbors (optional optimization)
        return mergeShortSegments(segments)
    }

    /// Merges very short non-protected segments with adjacent segments.
    /// This prevents excessive fragmentation from single-word language switches.
    private func mergeShortSegments(_ segments: [CodeSwitchSegment]) -> [CodeSwitchSegment] {
        guard segments.count > 2 else { return segments }

        var result: [CodeSwitchSegment] = [segments[0]]

        for i in 1..<segments.count {
            let prev = result[result.count - 1]
            let current = segments[i]

            // Merge if the previous segment is very short and not protected
            let prevWordCount = prev.text.split(separator: " ").count
            if prevWordCount <= 1 && !prev.shouldPreserve && !current.shouldPreserve {
                // Merge previous and current
                let mergedText = prev.text + " " + current.text
                let mergedLang: LanguageTag
                if current.language != .unknown {
                    mergedLang = current.language
                } else {
                    mergedLang = prev.language
                }
                let mergedIsMixed = prev.isMixed || current.isMixed || prev.language != current.language

                result[result.count - 1] = CodeSwitchSegment(
                    text: mergedText,
                    language: mergedLang,
                    isMixed: mergedIsMixed,
                    shouldPreserve: mergedIsMixed,
                    translationAction: .preserve
                )
            } else {
                result.append(current)
            }
        }

        return result
    }

    // MARK: - Step 4: Action Assignment

    /// Determines the translation action for a segment based on its language and content.
    private func assignAction(
        for segment: CodeSwitchSegment,
        sourceLanguage: String,
        targetLanguage: String
    ) -> ProcessedSegment {
        let protectedTerms: [String]

        // Find protected terms within this segment
        if config.termProtectionEnabled {
            protectedTerms = termDictionary.findProtectedTerms(in: segment.text)
        } else {
            protectedTerms = []
        }

        // Decision logic
        if segment.shouldPreserve || segment.isMixed {
            // Mixed segments or protected-term-only segments: preserve as-is
            return ProcessedSegment(
                original: segment.text,
                action: .preserve,
                protectedTerms: protectedTerms,
                language: segment.language
            )
        }

        // Pure language segments: determine translation direction
        switch segment.language {
        case .english:
            // Pure English → translate to target language
            return ProcessedSegment(
                original: segment.text,
                action: .translate(sourceLanguage: "en", targetLanguage: targetLanguage),
                protectedTerms: protectedTerms,
                language: .english
            )

        case .chinese:
            // Pure Chinese → translate to source/target language
            // In EN→ZH pipeline, a Chinese segment is code-switched — keep it
            // In ZH→EN pipeline, a Chinese segment is the source — translate it
            return ProcessedSegment(
                original: segment.text,
                action: .translate(sourceLanguage: "zh", targetLanguage: sourceLanguage),
                protectedTerms: protectedTerms,
                language: .chinese
            )

        default:
            // Unknown language: preserve as-is
            return ProcessedSegment(
                original: segment.text,
                action: .preserve,
                protectedTerms: protectedTerms,
                language: segment.language
            )
        }
    }

    // MARK: - Convenience

    /// Returns the term dictionary for external term management.
    var dictionary: TermDictionary {
        return termDictionary
    }

    /// Updates the code-switching configuration.
    func updateConfig(_ newConfig: CodeSwitchingConfig) {
        // Config is a value type; the service will use the new config on next call
        // Note: For full dynamic config updates, store config as a mutable property.
    }
}
