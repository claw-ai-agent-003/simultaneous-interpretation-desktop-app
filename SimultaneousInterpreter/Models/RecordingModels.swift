import Foundation

// MARK: - Recording Session

/// Represents a single recording session.
/// Audio is captured from the microphone and saved to a file.
struct RecordingSession: Codable, Identifiable {
    let id: String
    let sessionId: String
    let startTime: Date
    var endTime: Date?
    let audioFileURL: URL
    var segments: [TranscriptSegment]

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        audioFileURL: URL,
        segments: [TranscriptSegment] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.startTime = startTime
        self.endTime = endTime
        self.audioFileURL = audioFileURL
        self.segments = segments
    }

    /// Duration of the recording in seconds.
    var durationSeconds: TimeInterval {
        guard let end = endTime else {
            return Date().timeIntervalSince(startTime)
        }
        return end.timeIntervalSince(startTime)
    }

    /// Formatted duration string (HH:MM:SS).
    var formattedDuration: String {
        let total = Int(durationSeconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Language pair string (e.g., "EN → ZH").
    var languagePair: String {
        guard let first = segments.first,
              let last = segments.last else {
            return "—"
        }
        return "\(first.sourceLanguage) → \(last.targetLanguage)"
    }
}

// MARK: - Transcript Segment

/// A single segment within a meeting transcript.
/// Represents one captured piece of speech with its transcription and translation.
struct TranscriptSegment: Codable, Identifiable {
    let id: String
    let timestamp: TimeInterval  // seconds from session start
    let duration: TimeInterval
    let originalText: String
    let translatedText: String
    let speakerLabel: String?
    let sourceLanguage: String
    let targetLanguage: String

    init(
        id: String = UUID().uuidString,
        timestamp: TimeInterval,
        duration: TimeInterval,
        originalText: String,
        translatedText: String,
        speakerLabel: String? = nil,
        sourceLanguage: String = "en",
        targetLanguage: String = "zh"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.originalText = originalText
        self.translatedText = translatedText
        self.speakerLabel = speakerLabel
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    /// Formatted timestamp for display (MM:SS or HH:MM:SS).
    var formattedTimestamp: String {
        let total = Int(timestamp)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Meeting Transcript

/// The complete transcript of a meeting session.
struct MeetingTranscript: Codable, Identifiable {
    let id: String
    let sessionId: String
    let sessionDate: Date
    let sourceLanguage: String
    let targetLanguage: String
    var segments: [TranscriptSegment]

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        sessionDate: Date = Date(),
        sourceLanguage: String = "en",
        targetLanguage: String = "zh",
        segments: [TranscriptSegment] = []
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sessionDate = sessionDate
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.segments = segments
    }

    /// Total duration of the transcript in seconds.
    var totalDuration: TimeInterval {
        segments.map { $0.timestamp + $0.duration }.max() ?? 0
    }

    /// Formatted total duration.
    var formattedDuration: String {
        let total = Int(totalDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Number of segments in the transcript.
    var segmentCount: Int {
        segments.count
    }

    /// Full concatenated text (original).
    var fullOriginalText: String {
        segments.map { $0.originalText }.joined(separator: " ")
    }

    /// Full concatenated text (translated).
    var fullTranslatedText: String {
        segments.map { $0.translatedText }.joined(separator: " ")
    }
}

// MARK: - Search Result

/// A search result from transcript search.
struct TranscriptSearchResult: Codable, Identifiable {
    let id: String
    let sessionId: String
    let sessionDate: Date
    let matchedSegment: TranscriptSegment
    let snippet: String  // Surrounding context text

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        sessionDate: Date,
        matchedSegment: TranscriptSegment,
        snippet: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sessionDate = sessionDate
        self.matchedSegment = matchedSegment
        self.snippet = snippet
    }
}

// MARK: - Export Format

/// Supported transcript export formats.
enum TranscriptExportFormat: String, CaseIterable {
    case txt = "TXT"
    case srt = "SRT"
    case json = "JSON"

    var fileExtension: String {
        rawValue.lowercased()
    }

    var displayName: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .srt: return "Subtitles (.srt)"
        case .json: return "JSON Data (.json)"
        }
    }
}
