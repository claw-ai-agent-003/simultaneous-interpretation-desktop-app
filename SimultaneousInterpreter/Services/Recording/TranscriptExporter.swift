import Foundation
import AppKit
import NaturalLanguage

final class TranscriptExporter: @unchecked Sendable {
    enum ExportFormat: String, CaseIterable {
        case txt = "Plain Text (.txt)"
        case srt = "Subtitles (.srt)"
        case meetingBrief = "Meeting Brief PDF"
    }

    private let logger = Logger(subsystem: "com.interpretation.SimultaneousInterpreter", category: "TranscriptExporter")

    func export(segments: [TranscriptSegment], format: ExportFormat, meetingTitle: String? = nil) throws -> URL {
        switch format {
        case .txt: return try exportAsText(segments: segments, meetingTitle: meetingTitle)
        case .srt: return try exportAsSRT(segments: segments)
        case .meetingBrief: return try await exportAsMeetingBriefPdf(segments: segments, meetingTitle: meetingTitle)
        }
    }

    private func exportAsText(segments: [TranscriptSegment], meetingTitle: String?) throws -> URL {
        let title = meetingTitle ?? "Transcript"
        let timestamp = formatTimestamp(Date())
        let url = try outputURL(filename: "\(title)-\(timestamp).txt")
        var content = "\(title)\n" + String(repeating: "=", count: 50) + "\nExported: \(formatFullDate(Date()))\n\n"
        for seg in segments {
            let speaker = seg.speakerLabel ?? "Unknown"
            let time = formatTimestampSeconds(seg.startSeconds)
            content += "[\(time)] \(speaker): "
            let text = seg.sourceText.isEmpty ? seg.englishText : seg.sourceText
            content += "\(text)\n\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Transcript exported as text: \(url.path)")
        return url
    }

    private func exportAsSRT(segments: [TranscriptSegment]) throws -> URL {
        let url = try outputURL(filename: "Transcript-\(formatTimestamp(Date())).srt")
        var content = ""
        for (i, seg) in segments.enumerated() {
            content += "\(i + 1)\n"
            content += "\(formatSRTTimecode(seg.startSeconds)) --> \(formatSRTTimecode(seg.endSeconds))\n"
            let text = seg.sourceText.isEmpty ? seg.englishText : seg.sourceText
            content += "\(text)\n\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Transcript exported as SRT: \(url.path)")
        return url
    }

    func exportAsMeetingBriefPdf(segments: [TranscriptSegment], meetingTitle: String? = nil) async throws -> URL {
        guard !segments.isEmpty else { throw IntelligenceError.emptyTranscript }
        let summarizer = SummarizationService()
        let allText = segments.map { $0.sourceText.isEmpty ? $0.englishText : $0.sourceText }.joined(separator: " ")
        let language = detectLanguage(from: allText)
        let summary = try await summarizer.generateSummary(from: segments, language: language)
        var finalSummary = summary
        if let t = meetingTitle {
            finalSummary = MeetingSummary(meetingTitle: t, language: summary.language, languagePair: summary.languagePair, meetingDate: summary.meetingDate, durationSeconds: summary.durationSeconds, participantCount: summary.participantCount, participantNames: summary.participantNames, keyTopics: summary.keyTopics, decisions: summary.decisions, actionItems: summary.actionItems, sentiment: summary.sentiment, briefText: summary.briefText)
        }
        let pdfURL = try MeetingBriefPDFGenerator.generate(from: finalSummary)
        logger.info("Meeting Brief PDF exported: \(pdfURL.path)")
        return pdfURL
    }

    func exportAsMeetingBriefPdf(from summary: MeetingSummary) throws -> URL {
        let pdfURL = try MeetingBriefPDFGenerator.generate(from: summary)
        logger.info("Meeting Brief PDF exported: \(pdfURL.path)")
        return pdfURL
    }

    private func outputURL(filename: String) throws -> URL {
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw IntelligenceError.pdfGenerationFailed("Desktop directory not accessible")
        }
        return desktopURL.appendingPathComponent(filename.replacingOccurrences(of: "/", with: "-"))
    }

    private func detectLanguage(from text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    private func formatTimestamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: d)
    }

    private func formatFullDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .medium; return f.string(from: d)
    }

    private func formatTimestampSeconds(_ s: Double) -> String {
        String(format: "%02d:%02d", Int(s)/60, Int(s)%60)
    }

    private func formatSRTTimecode(_ s: Double) -> String {
        String(format: "%02d:%02d:%02d,%03d", Int(s)/3600, (Int(s)%3600)/60, Int(s)%60, Int((s.truncatingRemainder(dividingBy: 1))*1000))
    }
}
