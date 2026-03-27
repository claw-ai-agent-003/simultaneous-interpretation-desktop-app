import Foundation
import NaturalLanguage

final class SummarizationService: @unchecked Sendable {
    private let actionItemExtractor = ActionItemExtractor()
    private let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .language])
    private let languageRecognizer = NLLanguageRecognizer()
    private let enKeywords: Set<String> = ["important","critical","key","decide","decision","agreed","action","deadline","priority","urgent","must","need","plan","schedule","budget","cost","revenue","goal","milestone","deliverable","review","approve","confirm","risk","issue","blocker","update","progress","next"]
    private let zhKeywords: Set<String> = ["重要","关键","决定","决策","同意","必须","需要","计划","安排","预算","成本","收入","目标","里程碑","交付","审核","批准","确认","风险","问题","阻碍","更新","进展","下一步","会议","讨论","商定","确认"]

    func generateSummary(from transcript: [TranscriptSegment], language: String) async throws -> MeetingSummary {
        guard !transcript.isEmpty else { throw IntelligenceError.emptyTranscript }
        let allText = transcript.map { $0.sourceText.isEmpty ? $0.englishText : $0.sourceText }.joined(separator: " ")
        guard allText.count > 20 else { throw IntelligenceError.insufficientData }
        let detectedLang = detectLanguage(from: allText, hint: language)
        let topics = extractKeyTopics(from: transcript, language: detectedLang)
        let decisions = extractDecisions(from: transcript, language: detectedLang)
        let actions = actionItemExtractor.extractActionItems(from: transcript)
        let sentiment = analyzeSentiment(from: transcript, language: detectedLang)
        let title = inferMeetingTitle(from: transcript, language: detectedLang)
        let brief = generateBriefText(title: title, topics: topics, decisions: decisions, sentiment: sentiment, language: detectedLang)
        let maxEnd = transcript.map { $0.endSeconds }.max() ?? 0
        let minStart = transcript.map { $0.startSeconds }.min() ?? 0
        let duration = maxEnd - minStart
        let speakers = Set(transcript.compactMap { $0.speakerLabel }).count
        let langPair = langPairString(detectedLang)
        return MeetingSummary(meetingTitle: title, language: detectedLang, languagePair: langPair, meetingDate: Date(), durationSeconds: duration, participantCount: max(speakers, 1), participantNames: Array(Set(transcript.compactMap { $0.speakerLabel })), keyTopics: topics, decisions: decisions, actionItems: actions, sentiment: sentiment, briefText: brief)
    }

    private func extractKeyTopics(from segments: [TranscriptSegment], language: String) -> [KeyTopic] {
        guard !segments.isEmpty else { return [] }
        let isZh = language == "zh"
        var scored: [(TranscriptSegment, Double)] = []
        for seg in segments {
            let text = seg.sourceText.isEmpty ? seg.englishText : seg.sourceText
            let score = scoreImportance(text, isZh: isZh)
            if score > 0 { scored.append((seg, score)) }
        }
        scored.sort { $0.1 > $1.1 }
        var topics: [KeyTopic] = []
        var used: Set<Int> = []
        for (i, item) in scored.enumerated() {
            guard !used.contains(i), item.1 >= 1.0 else { continue }
            let text = item.0.sourceText.isEmpty ? item.0.englishText : item.0.sourceText
            var clusterSegs = [item.0]; var clusterIdx = [i]; let ct = item.0.startSeconds
            for (j, other) in scored.enumerated() {
                guard !clusterIdx.contains(j), abs(other.0.startSeconds - ct) < 120 else { continue }
                clusterSegs.append(other.0); clusterIdx.append(j)
            }
            clusterIdx.forEach { used.insert($0) }
            let ct2 = clusterSegs.map { $0.sourceText.isEmpty ? $0.englishText : $0.sourceText }.joined(separator: " ")
            let t = extractTopicTitle(ct2, isZh: isZh)
            let summ = generateTopicSummary(ct2, isZh: isZh)
            topics.append(KeyTopic(title: t, summary: summ, weight: item.1 / 10.0, firstMentionSeconds: clusterSegs.map { $0.startSeconds }.min() ?? 0, lastMentionSeconds: clusterSegs.map { $0.endSeconds }.max() ?? 0))
        }
        return topics.sorted { $0.firstMentionSeconds < $1.firstMentionSeconds }
    }

    private func scoreImportance(_ s: String, isZh: Bool) -> Double {
        var score: Double = 0
        let kw = isZh ? zhKeywords : enKeywords
        let low = s.lowercased()
        for k in kw { score += Double(low.components(separatedBy: k).count - 1) * 1.5 }
        let wc = s.split(separator: " ").count
        if wc >= 5 && wc <= 50 { score += 1.0 }
        return score
    }

    private func extractTopicTitle(_ text: String, isZh: Bool) -> String {
        var names: [String] = []
        let range = text.startIndex..<text.endIndex
        tagger.string = text
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitWhitespace]) { tag, r in
            if tag == .organizationName || tag == .placeName { names.append(String(text[r])) }
            return names.count < 3
        }
        if !names.isEmpty { return names.prefix(2).joined(separator: " / ") }
        let sents = text.components(separatedBy: isZh ? "。" : ".").filter { !$0.isEmpty }
        return String((sents.first ?? text).prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateTopicSummary(_ text: String, isZh: Bool) -> String {
        let sents = text.components(separatedBy: isZh ? "。" : ".").filter { !$0.isEmpty }
        return sents.first.map { String($0.prefix(100)) } ?? ""
    }

    private func extractDecisions(from segments: [TranscriptSegment], language: String) -> [Decision] {
        let isZh = language == "zh"
        let patterns: [String] = isZh ? ["决定","确认","同意","批准","通过","商定","达成"] : ["decided","agreed","confirmed","approved","finalized","resolved","concluded","we will","we'll"]
        var decisions: [Decision] = []; var seen: Set<String> = []
        for seg in segments {
            let text = seg.sourceText.isEmpty ? seg.englishText : seg.sourceText
            for sent in splitSentences(text, isZh: isZh) {
                let low = sent.lowercased()
                for p in patterns {
                    if low.contains(p.lowercased()) {
                        let norm = low.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !seen.contains(norm) && sent.count > 10 { seen.insert(norm); decisions.append(Decision(description: sent.trimmingCharacters(in: .whitespacesAndNewlines), sourceSentence: sent, timestampSeconds: seg.startSeconds)); break }
                    }
                }
            }
        }
        return decisions.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    private func splitSentences(_ text: String, isZh: Bool) -> [String] {
        if isZh { return text.components(separatedBy: "。！？；").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        var sents: [String] = []
        let range = text.startIndex..<text.endIndex
        tagger.string = text
        tagger.enumerateTags(in: range, unit: .sentence, scheme: .tokenType, options: []) { _, r in
            let s = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sents.append(s) }
            return true
        }
        return sents
    }

    private func analyzeSentiment(from segments: [TranscriptSegment], language: String) -> MeetingSentiment {
        let isZh = language == "zh"
        let pos: [String] = isZh ? ["好","很好","太好了","满意","成功","达成","同意","不错","优秀"] : ["good","great","excellent","perfect","happy","satisfied","success","agreed","approved","progress","improved","better"]
        let neg: [String] = isZh ? ["问题","困难","风险","失败","不满意","担心","延迟","糟糕"] : ["problem","issue","risk","fail","concern","delay","worry","difficult","challenge","blocker","missing","failed","bad"]
        var pc = 0; var nc = 0
        for seg in segments {
            let text = (seg.sourceText.isEmpty ? seg.englishText : seg.sourceText).lowercased()
            for k in pos { pc += text.components(separatedBy: k.lowercased()).count - 1 }
            for k in neg { nc += text.components(separatedBy: k.lowercased()).count - 1 }
        }
        let total = pc + nc
        if total == 0 { return .neutral }
        let ratio = Double(pc) / Double(total)
        return ratio > 0.6 ? .positive : (ratio < 0.4 ? .negative : .neutral)
    }

    private func inferMeetingTitle(from segments: [TranscriptSegment], language: String) -> String {
        let isZh = language == "zh"
        let allText = segments.map { $0.sourceText.isEmpty ? $0.englishText : $0.sourceText }.joined(separator: " ")
        var entities: [String] = []
        let early = String(allText.prefix(500)); let range = early.startIndex..<early.endIndex
        tagger.string = early
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitWhitespace]) { tag, r in
            if tag == .organizationName { entities.append(String(early[r])) }
            return entities.count < 3
        }
        if !entities.isEmpty {
            let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"
            return "\(entities[0]) Meeting - \(f.string(from: Date()))"
        }
        let title = titleFallback(allText, isZh: isZh)
        return !title.isEmpty ? title : (isZh ? "会议纪要" : "Meeting Summary")
    }

    private func titleFallback(_ text: String, isZh: Bool) -> String {
        let sep = isZh ? "。" : "."
        let first = text.components(separatedBy: sep).first ?? text
        return String(first.replacingOccurrences(of: isZh ? "我们讨论" : "we discussed", with: "").replacingOccurrences(of: isZh ? "今天" : "today", with: "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    private func generateBriefText(title: String, topics: [KeyTopic], decisions: [Decision], sentiment: MeetingSentiment, language: String) -> String {
        let isZh = language == "zh"
        var brief = isZh ? "本次会议" : "This meeting "
        if isZh {
            brief += "主要讨论了"
            brief += topics.prefix(3).map { $0.title }.joined(separator: "、")
            brief += "。"
            if !decisions.isEmpty { brief += "会议确定了\(decisions.count)项决定，包括："; brief += decisions.prefix(2).map { $0.description }.joined(separator: "；"); brief += "。" }
        } else {
            brief += "focused on "; brief += topics.prefix(3).map { $0.title }.joined(separator: ", "); brief += ". "
            if !decisions.isEmpty { brief += "\(decisions.count) decisions were made, including: "; brief += decisions.prefix(2).map { $0.description }.joined(separator: "; "); brief += ". " }
        }
        return brief
    }

    private func detectLanguage(from text: String, hint: String) -> String {
        languageRecognizer.reset(); languageRecognizer.processString(text)
        if let dom = languageRecognizer.dominantLanguage { return dom.rawValue }
        return !hint.isEmpty ? hint : "en"
    }

    private func langPairString(_ lang: String) -> String {
        lang == "zh" ? "en -> zh" : (lang == "en" ? "en -> zh" : "\(lang) -> zh/en")
    }
}
