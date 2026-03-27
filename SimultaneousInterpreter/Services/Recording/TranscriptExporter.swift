import Foundation
import AppKit
import NaturalLanguage

// ============================================================
// MARK: - Transcript Exporter
// ============================================================

/// Exports transcripts in various formats including TXT, SRT, and Meeting Brief PDF.
final class TranscriptExporter: @unchecked Sendable {

    // MARK: - Export Format

    enum ExportFormat: String, CaseIterable {
        case txt = "Plain Text (.txt)"
        case srt = "Subtitles (.srt)"
        case meetingBrief = "Meeting Brief PDF"
    }

    // MARK: - Properties

    private let logger = Logger(
        subsystem: "com.interpretation.SimultaneousInterpreter",
        category: "TranscriptExporter"
    )

    // MARK: - Public Interface

    /// Exports transcript segments to the specified format.
    /// - Parameters:
    ///   - segments: Array of transcript segments.
    ///   - format: Target export format.
    ///   - meetingTitle: Optional title for the meeting.
    /// - Returns: File URL of the exported file.
    func export(
        segments: [TranscriptSegment],
        format: ExportFormat,
        meetingTitle: String? = nil
    ) throws -> URL {
        switch format {
        case .txt:
            return try exportAsText(segments: segments, meetingTitle: meetingTitle)
        case .srt:
            return try exportAsSRT(segments: segments)
        case .meetingBrief:
            return try exportAsMeetingBriefPdf(segments: segments, meetingTitle: meetingTitle)
        }
    }

    // MARK: - Plain Text Export

    /// Exports transcript as plain text.
    private func exportAsText(segments: [TranscriptSegment], meetingTitle: String?) throws -> URL {
        let title = meetingTitle ?? "Transcript"
        let timestamp = formatTimestamp(Date())
        let filename = "\(title)-\(timestamp).txt"

        let url = try outputURL(filename: filename)

        var content = "\(title)\n"
        content += String(repeating: "=", count: 50) + "\n"
        content += "Exported: \(formatFullDate(Date()))\n\n"

        for segment in segments {
            let speaker = segment.speakerLabel ?? "Unknown"
            let time = formatTimestampSeconds(segment.startSeconds)
            content += "[\(time)] \(speaker): "
            let text = segment.sourceText.isEmpty ? segment.englishText : segment.sourceText
            content += "\(text)\n\n"
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Transcript exported as text: \(url.path)")
        return url
    }

    // MARK: - SRT Export

    /// Exports transcript as SRT subtitles.
    private func exportAsSRT(segments: [TranscriptSegment]) throws -> URL {
        let timestamp = formatTimestamp(Date())
        let filename = "Transcript-\(timestamp).srt"

        let url = try outputURL(filename: filename)

        var content = ""
        for (index, segment) in segments.enumerated() {
            // Subtitle number
            content += "\(index + 1)\n"

            // Timecode: 00:00:00,000 --> 00:00:00,000
            let startTC = formatSRTTimecode(segment.startSeconds)
            let endTC = formatSRTTimecode(segment.endSeconds)
            content += "\(startTC) --> \(endTC)\n"

            // Text: show source if available, else English
            let text = segment.sourceText.isEmpty ? segment.englishText : segment.sourceText
            content += "\(text)\n\n"
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Transcript exported as SRT: \(url.path)")
        return url
    }

    // MARK: - Meeting Brief PDF Export

    /// Exports transcript as a Meeting Brief PDF.
    /// - Parameters:
    ///   - segments: Array of transcript segments.
    ///   - meetingTitle: Optional meeting title override.
    /// - Returns: File URL of the generated PDF.
    func exportAsMeetingBriefPdf(
        segments: [TranscriptSegment],
        meetingTitle: String? = nil
    ) throws -> URL {
        guard !segments.isEmpty else {
            throw IntelligenceError.emptyTranscript
        }

        // Generate summary using SummarizationService
        let summarizer = SummarizationService()

        // Detect primary language
        let allText = segments.map { $0.sourceText.isEmpty ? $0.englishText : $0.sourceText }.joined(separator: " ")
        let language = detectLanguage(from: allText)

        let summary = try Task.synchronous {
            try await summarizer.generateSummary(from: segments, language: language)
        }

        // Override title if provided
        var finalSummary = summary
        if let title = meetingTitle {
            finalSummary = MeetingSummary(
                meetingTitle: title,
                language: summary.language,
                languagePair: summary.languagePair,
                meetingDate: summary.meetingDate,
                durationSeconds: summary.durationSeconds,
                participantCount: summary.participantCount,
                participantNames: summary.participantNames,
                keyTopics: summary.keyTopics,
                decisions: summary.decisions,
                actionItems: summary.actionItems,
                sentiment: summary.sentiment,
                briefText: summary.briefText
            )
        }

        // Generate PDF
        let pdfURL = try MeetingBriefPDFGenerator.generate(from: finalSummary)
        logger.info("Meeting Brief PDF exported: \(pdfURL.path)")
        return pdfURL
    }

    /// Exports directly from a MeetingSummary (already generated).
    func exportAsMeetingBriefPdf(from summary: MeetingSummary) throws -> URL {
        let pdfURL = try MeetingBriefPDFGenerator.generate(from: summary)
        logger.info("Meeting Brief PDF exported: \(pdfURL.path)")
        return pdfURL
    }

    // MARK: - Helpers

    private func outputURL(filename: String) throws -> URL {
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw IntelligenceError.pdfGenerationFailed("Desktop directory not accessible")
        }
        let sanitized = filename.replacingOccurrences(of: "/", with: "-")
        return desktopURL.appendingPathComponent(sanitized)
    }

    private func detectLanguage(from text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func formatTimestampSeconds(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func formatSRTTimecode(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }
}

// ============================================================
// MARK: - Task Synchronous Extension
// ============================================================

extension Task where Success == Never, Failure == Never {
    /// Blocks synchronously until the operation completes.
    /// Used for bridging async to sync in export operations.
    static func synchronous<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(NSError(domain: "Task", code: -1))

        _ = Task {
            do {
                let value = try await operation()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try result.get()
    }
}
