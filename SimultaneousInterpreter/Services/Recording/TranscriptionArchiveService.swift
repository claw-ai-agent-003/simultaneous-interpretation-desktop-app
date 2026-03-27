import Foundation

/// Service responsible for persisting, loading, and searching meeting transcripts.
/// Transcripts are stored as JSON files in the Application Support directory.
class TranscriptionArchiveService {

    // MARK: - Properties

    /// Directory where transcripts are stored.
    private let transcriptsDirectory: URL

    /// Directory where recording audio files are stored.
    private let recordingsDirectory: URL

    /// Shared JSON encoder for transcripts.
    private let encoder: JSONEncoder

    /// Shared JSON decoder for transcripts.
    private let decoder: JSONDecoder

    // MARK: - Errors

    enum ArchiveError: LocalizedError {
        case directoryCreationFailed(Error)
        case transcriptNotFound(sessionId: String)
        case saveFailed(Error)
        case loadFailed(Error)
        case invalidTranscriptData

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let error):
                return "Failed to create transcripts directory: \(error.localizedDescription)"
            case .transcriptNotFound(let sessionId):
                return "No transcript found for session: \(sessionId)"
            case .saveFailed(let error):
                return "Failed to save transcript: \(error.localizedDescription)"
            case .loadFailed(let error):
                return "Failed to load transcript: \(error.localizedDescription)"
            case .invalidTranscriptData:
                return "Transcript data is invalid or corrupted."
            }
        }
    }

    // MARK: - Initialization

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        transcriptsDirectory = appSupport
            .appendingPathComponent("SimultaneousInterpreter", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)

        recordingsDirectory = appSupport
            .appendingPathComponent("SimultaneousInterpreter", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)

        // Ensure directories exist
        try? FileManager.default.createDirectory(
            at: transcriptsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Configure encoder with ISO8601 dates
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Configure decoder
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Public Interface

    /// Saves a transcript to disk.
    /// - Parameters:
    ///   - session: The recording session to associate with the transcript.
    ///   - transcript: The transcript to save.
    /// - Throws: ArchiveError if saving fails.
    func saveTranscript(session: RecordingSession, transcript: MeetingTranscript) throws {
        let fileName = "\(session.sessionId)_transcript.json"
        let fileURL = transcriptsDirectory.appendingPathComponent(fileName)

        do {
            let data = try encoder.encode(transcript)
            try data.write(to: fileURL, options: .atomic)
            print("TranscriptionArchiveService: Saved transcript for session \(session.sessionId)")
        } catch let error as EncodingError {
            print("TranscriptionArchiveService: Encoding error: \(error)")
            throw ArchiveError.saveFailed(error)
        } catch {
            throw ArchiveError.saveFailed(error)
        }
    }

    /// Loads a transcript for the given session ID.
    /// - Parameter sessionId: The session ID to look up.
    /// - Returns: MeetingTranscript if found.
    /// - Throws: ArchiveError if not found or loading fails.
    func loadTranscript(sessionId: String) throws -> MeetingTranscript {
        let fileName = "\(sessionId)_transcript.json"
        let fileURL = transcriptsDirectory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ArchiveError.transcriptNotFound(sessionId: sessionId)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let transcript = try decoder.decode(MeetingTranscript.self, from: data)
            return transcript
        } catch let error as DecodingError {
            print("TranscriptionArchiveService: Decoding error: \(error)")
            throw ArchiveError.loadFailed(error)
        } catch {
            throw ArchiveError.loadFailed(error)
        }
    }

    /// Searches all transcripts for a query string.
    /// - Parameters:
    ///   - query: The search string (matched against both original and translated text).
    ///   - since: Optional date to restrict search to sessions after this date.
    /// - Returns: Array of search results sorted by recency.
    func searchTranscripts(query: String, since: Date? = nil) -> [TranscriptSearchResult] {
        guard !query.isEmpty else { return [] }

        let lowercasedQuery = query.lowercased()
        var results: [TranscriptSearchResult] = []

        let transcripts = listTranscripts()
        for transcript in transcripts {
            // Filter by date if specified
            if let since = since, transcript.sessionDate < since {
                continue
            }

            for segment in transcript.segments {
                let originalLower = segment.originalText.lowercased()
                let translatedLower = segment.translatedText.lowercased()

                if originalLower.contains(lowercasedQuery) || translatedLower.contains(lowercasedQuery) {
                    let snippet = buildSnippet(
                        segment: segment,
                        query: lowercasedQuery,
                        originalText: segment.originalText,
                        translatedText: segment.translatedText
                    )

                    let result = TranscriptSearchResult(
                        sessionId: transcript.sessionId,
                        sessionDate: transcript.sessionDate,
                        matchedSegment: segment,
                        snippet: snippet
                    )
                    results.append(result)
                }
            }
        }

        // Sort by recency (most recent first)
        results.sort { $0.sessionDate > $1.sessionDate }
        return results
    }

    /// Lists all available transcripts, sorted by date (most recent first).
    /// - Returns: Array of MeetingTranscript metadata (segments excluded for efficiency).
    func listTranscripts() -> [MeetingTranscript] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: transcriptsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        let transcriptFiles = files.filter { $0.pathExtension == "json" }

        var transcripts: [MeetingTranscript] = []
        for fileURL in transcriptFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let transcript = try? decoder.decode(MeetingTranscript.self, from: data) else {
                continue
            }
            transcripts.append(transcript)
        }

        // Sort by date, most recent first
        transcripts.sort { $0.sessionDate > $1.sessionDate }
        return transcripts
    }

    /// Returns a summary of a transcript (without full segment data) for list display.
    /// - Parameter sessionId: The session ID.
    /// - Returns: TranscriptSummary if found.
    /// - Throws: ArchiveError if not found.
    func loadTranscriptSummary(sessionId: String) throws -> TranscriptSummary {
        let transcript = try loadTranscript(sessionId: sessionId)
        return TranscriptSummary(from: transcript)
    }

    /// Deletes a transcript and optionally the associated recording file.
    /// - Parameters:
    ///   - sessionId: The session ID.
    ///   - deleteAudio: Whether to also delete the audio recording file.
    /// - Throws: ArchiveError if transcript not found.
    func deleteTranscript(sessionId: String, deleteAudio: Bool = false) throws {
        let fileName = "\(sessionId)_transcript.json"
        let fileURL = transcriptsDirectory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ArchiveError.transcriptNotFound(sessionId: sessionId)
        }

        try FileManager.default.removeItem(at: fileURL)

        if deleteAudio {
            // Try to delete the audio file with any timestamp
            if let audioFiles = try? FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) {
                for audioFile in audioFiles where audioFile.lastPathComponent.hasPrefix(sessionId) {
                    try? FileManager.default.removeItem(at: audioFile)
                }
            }
        }

        print("TranscriptionArchiveService: Deleted transcript for session \(sessionId)")
    }

    /// Checks whether a transcript exists for the given session ID.
    func transcriptExists(sessionId: String) -> Bool {
        let fileName = "\(sessionId)_transcript.json"
        let fileURL = transcriptsDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Private Helpers

    /// Builds a snippet string showing the matched segment with surrounding context.
    private func buildSnippet(
        segment: TranscriptSegment,
        query: String,
        originalText: String,
        translatedText: String
    ) -> String {
        // Prefer showing the translated text if query matches it
        let textToShow: String
        if translatedText.lowercased().contains(query) {
            textToShow = translatedText
        } else {
            textToShow = originalText
        }

        let maxLength = 120
        if textToShow.count <= maxLength {
            return textToShow
        }

        // Truncate with ellipsis
        let start = textToShow.index(textToShow.startIndex, offsetBy: 0)
        let end = textToShow.index(textToShow.startIndex, offsetBy: maxLength - 3)
        return String(textToShow[start..<end]) + "..."
    }
}

// MARK: - Transcript Summary

/// Lightweight summary of a transcript for list display.
/// Contains metadata without full segment data.
struct TranscriptSummary: Codable {
    let sessionId: String
    let sessionDate: Date
    let sourceLanguage: String
    let targetLanguage: String
    let segmentCount: Int
    let totalDuration: TimeInterval
    let audioFileExists: Bool

    init(from transcript: MeetingTranscript) {
        self.sessionId = transcript.sessionId
        self.sessionDate = transcript.sessionDate
        self.sourceLanguage = transcript.sourceLanguage
        self.targetLanguage = transcript.targetLanguage
        self.segmentCount = transcript.segmentCount
        self.totalDuration = transcript.totalDuration

        // Check if audio file exists
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport
            .appendingPathComponent("SimultaneousInterpreter", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)

        var exists = false
        if let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            exists = files.contains { $0.lastPathComponent.hasPrefix(transcript.sessionId) }
        }
        self.audioFileExists = exists
    }

    /// Formatted date string.
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: sessionDate)
    }

    /// Formatted duration string.
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

    /// Language pair string.
    var languagePair: String {
        "\(sourceLanguage) → \(targetLanguage)"
    }
}
