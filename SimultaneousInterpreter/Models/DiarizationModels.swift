import Foundation

// ============================================================
// MARK: - Diarization Models
// ============================================================

/// A speaker embedding vector extracted from an audio chunk.
/// Stores the raw floating-point embedding alongside its source audio chunk metadata.
struct SpeakerEmbedding: Sendable, Identifiable {
    /// Unique identifier for this embedding instance.
    let id: UUID

    /// Monotonic chunk index matching the pipeline chunk index.
    let chunkIndex: Int

    /// The embedding vector (e.g. 256-dimensional).
    let vector: [Float]

    /// Timestamp when this embedding was extracted.
    let timestamp: Date

    init(chunkIndex: Int, vector: [Float]) {
        self.id = UUID()
        self.chunkIndex = chunkIndex
        self.vector = vector
        self.timestamp = Date()
    }
}

// ============================================================
// MARK: - Speaker Label
// ============================================================

/// Represents an identified speaker with a stable label and color.
/// Once assigned, a speaker's label and color remain consistent for the entire session.
struct SpeakerLabel: Sendable, Identifiable, Hashable {
    /// Unique internal identifier.
    let id: UUID

    /// Human-readable label (e.g. "Speaker A", "Speaker B").
    let displayName: String

    /// Index for ordering (0 = first speaker, 1 = second, etc.).
    let index: Int

    /// The display color for this speaker in the overlay.
    let color: SpeakerColor

    init(index: Int) {
        self.id = UUID()
        self.index = index
        self.displayName = "Speaker \(Self.letter(for: index))"
        self.color = SpeakerColor.fromIndex(index)
    }

    /// Converts a 0-based index to a letter (A, B, C, ...).
    private static func letter(for index: Int) -> String {
        // A=0, B=1, ..., Z=25, then AA, AB, ...
        guard index >= 0 else { return "?" }
        if index < 26 {
            let scalar = UInt32(("A" as Character).asciiValue! + UInt8(index))
            return String(UnicodeScalar(scalar)!)
        }
        // Fallback for >26 speakers (unlikely, max is 10)
        return String(format: " %d", index + 1)
    }

    // Hashable conformance based on id
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SpeakerLabel, rhs: SpeakerLabel) -> Bool {
        lhs.id == rhs.id
    }
}

// ============================================================
// MARK: - Speaker Color
// ============================================================

/// Predefined color palette for speaker identification.
/// Maps a speaker index to a distinct, accessible color.
enum SpeakerColor: Sendable {
    case blue       // Speaker A
    case green      // Speaker B
    case orange     // Speaker C
    case purple     // Speaker D
    case pink       // Speaker E
    case cyan       // Speaker F
    case yellow     // Speaker G
    case red        // Speaker H
    case teal       // Speaker I
    case indigo     // Speaker J

    /// The emoji circle for this color.
    var emoji: String {
        switch self {
        case .blue:    return "🔵"
        case .green:   return "🟢"
        case .orange:  return "🟠"
        case .purple:  return "🟣"
        case .pink:    return "🩷"
        case .cyan:    return "🩵"
        case .yellow:  return "🟡"
        case .red:     return "🔴"
        case .teal:    return "🩵"
        case .indigo:  return "🫐"
        }
    }

    /// Hex color string for programmatic use.
    var hex: String {
        switch self {
        case .blue:    return "#3399E0"
        case .green:   return "#34C759"
        case .orange:  return "#FF9500"
        case .purple:  return "#AF52DE"
        case .pink:    return "#FF2D55"
        case .cyan:    return "#5AC8FA"
        case .yellow:  return "#FFCC00"
        case .red:     return "#FF3B30"
        case .teal:    return "#00C7BE"
        case .indigo:  return "#5856D6"
        }
    }

    /// CSS/appkit RGBA components (premultiplied for dark backgrounds).
    var redComponent: CGFloat { CGFloat(Self.rgbaValues[self]?.0 ?? 0) / 255.0 }
    var greenComponent: CGFloat { CGFloat(Self.rgbaValues[self]?.1 ?? 0) / 255.0 }
    var blueComponent: CGFloat { CGFloat(Self.rgbaValues[self]?.2 ?? 0) / 255.0 }

    private static let rgbaValues: [SpeakerColor: (Int, Int, Int)] = [
        .blue:   (0x33, 0x99, 0xE0),
        .green:  (0x34, 0xC7, 0x59),
        .orange: (0xFF, 0x95, 0x00),
        .purple: (0xAF, 0x52, 0xDE),
        .pink:   (0xFF, 0x2D, 0x55),
        .cyan:   (0x5A, 0xC8, 0xFA),
        .yellow: (0xFF, 0xCC, 0x00),
        .red:    (0xFF, 0x3B, 0x30),
        .teal:   (0x00, 0xC7, 0xBE),
        .indigo: (0x58, 0x56, 0xD6),
    ]

    /// Maps a speaker index (0-based) to a color.
    static func fromIndex(_ index: Int) -> SpeakerColor {
        let allColors: [SpeakerColor] = [
            .blue, .green, .orange, .purple, .pink,
            .cyan, .yellow, .red, .teal, .indigo
        ]
        return allColors[index % allColors.count]
    }
}

// ============================================================
// MARK: - Diarized Segment
// ============================================================

/// A transcription segment annotated with speaker identity.
/// Produced by the DiarizationService and consumed by the overlay.
struct DiarizedSegment: Sendable, Identifiable {
    let id: UUID

    /// Monotonic chunk index matching the pipeline.
    let chunkIndex: Int

    /// The identified speaker for this segment.
    let speaker: SpeakerLabel

    /// Original transcription text (source language).
    let sourceText: String

    /// Translated text (target language), if available.
    var translatedText: String?

    /// Whisper confidence score.
    let confidence: Float

    /// Duration of the source audio in seconds.
    let durationSeconds: Double

    /// When this segment was produced.
    let producedAt: Date

    init(
        chunkIndex: Int,
        speaker: SpeakerLabel,
        sourceText: String,
        confidence: Float,
        durationSeconds: Double
    ) {
        self.id = UUID()
        self.chunkIndex = chunkIndex
        self.speaker = speaker
        self.sourceText = sourceText
        self.confidence = confidence
        self.durationSeconds = durationSeconds
        self.producedAt = Date()
    }
}

// ============================================================
// MARK: - Diarization Configuration
// ============================================================

/// Configuration for the speaker diarization pipeline.
struct DiarizationConfig: Sendable {
    /// Minimum number of speakers to detect.
    var minSpeakers: Int = 2

    /// Maximum number of speakers to detect.
    var maxSpeakers: Int = 10

    /// Cosine similarity threshold for same-speaker classification.
    /// Embeddings with similarity above this value are considered the same speaker.
    /// Range: 0.0–1.0, higher = more likely to merge speakers.
    var similarityThreshold: Float = 0.75

    /// Minimum number of embeddings required before clustering begins.
    var warmupEmbeddings: Int = 4

    /// Dimensionality of speaker embeddings.
    var embeddingDimension: Int = 256

    /// Number of recent embeddings to keep in the buffer for comparison.
    /// Older embeddings are pruned to keep memory bounded.
    var maxBufferedEmbeddings: Int = 200
}

// ============================================================
// MARK: - Diarization Events
// ============================================================

/// Events emitted by the diarization pipeline for observability.
enum DiarizationEvent: Sendable {
    case embeddingExtracted(chunkIndex: Int, durationMs: Double)
    case embeddingFailed(chunkIndex: Int, error: String)
    case speakerAssigned(chunkIndex: Int, speaker: String)
    case newSpeakerDetected(speaker: String, totalSpeakers: Int)
    case clusteringCompleted(totalSpeakers: Int)
}
