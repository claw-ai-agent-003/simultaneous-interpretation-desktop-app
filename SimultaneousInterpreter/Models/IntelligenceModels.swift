import Foundation

// MARK: - Meeting Sentiment
enum MeetingSentiment: String, Codable, Sendable {
    case positive, neutral, negative
    var displayLabel: String { rawValue }
    var emoji: String { rawValue }
}

// MARK: - Action Item
struct ActionItem: Identifiable, Codable, Sendable {
    let id: UUID
    let description: String
    var owner: String?
    var deadline: Date?
    let sourceSentence: String
    let timestampSeconds: Double
    init(description: String, owner: String? = nil, deadline: Date? = nil, sourceSentence: String, timestampSeconds: Double) {
        self.id = UUID(); self.description = description; self.owner = owner; self.deadline = deadline; self.sourceSentence = sourceSentence; self.timestampSeconds = timestampSeconds
    }
    var formattedTimestamp: String { String(format: "%02d:%02d", Int(timestampSeconds)/60, Int(timestampSeconds)%60) }
}

// MARK: - Decision
struct Decision: Identifiable, Codable, Sendable {
    let id: UUID
    let description: String
    let sourceSentence: String
    let timestampSeconds: Double
    init(description: String, sourceSentence: String, timestampSeconds: Double) {
        self.id = UUID(); self.description = description; self.sourceSentence = sourceSentence; self.timestampSeconds = timestampSeconds
    }
    var formattedTimestamp: String { String(format: "%02d:%02d", Int(timestampSeconds)/60, Int(timestampSeconds)%60) }
}

// MARK: - Key Topic
struct KeyTopic: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    var weight: Double
    let firstMentionSeconds: Double
    var lastMentionSeconds: Double
    var isConcluded: Bool = true
    init(title: String, summary: String, weight: Double, firstMentionSeconds: Double, lastMentionSeconds: Double) {
        self.id = UUID(); self.title = title; self.summary = summary; self.weight = weight; self.firstMentionSeconds = firstMentionSeconds; self.lastMentionSeconds = lastMentionSeconds
    }
}

// MARK: - Meeting Summary
struct MeetingSummary: Codable, Sendable {
    let meetingTitle: String
    let language: String
    var languagePair: String
    let meetingDate: Date
    let durationSeconds: Double
    let participantCount: Int
    var participantNames: [String]
    let keyTopics: [KeyTopic]
    let decisions: [Decision]
    let actionItems: [ActionItem]
    let sentiment: MeetingSentiment
    let briefText: String
    let generatedAt: Date
    init(meetingTitle: String, language: String, languagePair: String, meetingDate: Date, durationSeconds: Double, participantCount: Int, participantNames: [String], keyTopics: [KeyTopic], decisions: [Decision], actionItems: [ActionItem], sentiment: MeetingSentiment, briefText: String) {
        self.meetingTitle = meetingTitle; self.language = language; self.languagePair = languagePair; self.meetingDate = meetingDate; self.durationSeconds = durationSeconds
        self.participantCount = participantCount; self.participantNames = participantNames; self.keyTopics = keyTopics; self.decisions = decisions; self.actionItems = actionItems; self.sentiment = sentiment; self.briefText = briefText; self.generatedAt = Date()
    }
    var formattedDuration: String {
        let t = Int(durationSeconds); let m = t/60; let s = t%60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
    var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .short; return f.string(from: meetingDate)
    }
}

// MARK: - Transcript Segment
struct TranscriptSegment: Sendable, Identifiable {
    let id: UUID
    let sourceText: String
    let englishText: String
    let mandarinText: String
    let startSeconds: Double
    let endSeconds: Double
    let speakerLabel: String?
    let confidence: Float
    init(sourceText: String, englishText: String, mandarinText: String, startSeconds: Double, endSeconds: Double, speakerLabel: String? = nil, confidence: Float = 1.0) {
        self.id = UUID(); self.sourceText = sourceText; self.englishText = englishText; self.mandarinText = mandarinText; self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.speakerLabel = speakerLabel; self.confidence = confidence
    }
    var durationSeconds: Double { endSeconds - startSeconds }
}

// MARK: - IntelligenceError
enum IntelligenceError: Error, LocalizedError {
    case emptyTranscript, nlpProcessingFailed(String), pdfGenerationFailed(String), insufficientData
    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "The transcript is empty."
        case .nlpProcessingFailed(let r): return "NLP failed: \(r)"
        case .pdfGenerationFailed(let r): return "PDF failed: \(r)"
        case .insufficientData: return "Not enough data."
        }
    }
}
