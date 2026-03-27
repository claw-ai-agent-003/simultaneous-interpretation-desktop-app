import Foundation
import NaturalLanguage

final class ActionItemExtractor: @unchecked Sendable {
    private struct Pattern {
        static let chineseMust = /要(.+)/
        static let chineseNeed = /需要(.+)/
        static let chineseMustDo = /必须(.+)/
        static let chineseLetSomeone = /让([\S]{1,20})去做(.+)/
        static let chineseIWill = /我会(.+)/
        static let englishWill = /(?i:will)(.+)/.+
        static let englishShould = /(?i:should)(.+)/.+
        static let englishNeedTo = /(?i:need to)(.+)/.+
        static let englishAction = /(?i:action:\s*)(.+)/.+
        static let englishTodo = /(?i:todo:\s*)(.+)/.+
        static let englishToDo = /(?i:to-?do)(.+)/.+
        static let englishShall = /(?i:shall)(.+)/.+
        static let englishLetSomeone = /(?i:let\s+)(\S+)\s+do(.+)/.+
        static let byDate = /(?i:by\s+)(\w+\s+\d+|\d\d?\/\d\d?)/.+
        static let nextWeek = /(?i:next\s+week)/.+
        static let tomorrow = /(?i:tomorrow)/.+
        static let today = /(?i:today)/.+
    }
    private let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])

    func extractActionItems(from segments: [TranscriptSegment]) -> [ActionItem] {
        var items: [ActionItem] = []
        var seen: Set<String> = []
        for seg in segments {
            let text = seg.sourceText.isEmpty ? seg.englishText : seg.sourceText
            for sent in splitIntoSentences(text) {
                let trimmed = sent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count > 5 else { continue }
                if let item = parseSentence(trimmed, ts: seg.startSeconds) {
                    let norm = item.description.lowercased().replacingOccurrences(of: " ", with: "").prefix(60)
                    if !seen.contains(String(norm)) { seen.insert(String(norm)); items.append(item) }
                }
            }
        }
        return items.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        let chinese = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count > text.unicodeScalars.count / 3
        if chinese { return text.components(separatedBy: "。！？；").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        var sents: [String] = []
        let range = text.startIndex..<text.endIndex
        tagger.string = text
        tagger.enumerateTags(in: range, unit: .sentence, scheme: .tokenType, options: []) { _, r in
            let sent = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sent.isEmpty { sents.append(sent) }
            return true
        }
        return sents
    }

    private func parseSentence(_ s: String, ts: Double) -> ActionItem? {
        if let m = try? Pattern.chineseMust.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: "要做: \(d)", owner: extractChineseOwner(s), deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.chineseNeed.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: "需要做: \(d)", owner: extractChineseOwner(s), deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.chineseMustDo.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: "必须做: \(d)", owner: extractChineseOwner(s), deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.chineseLetSomeone.firstMatch(in: s) {
            let o = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let d = String(m.2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, owner: o, deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.chineseIWill.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.englishWill.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, owner: extractEnglishOwner(s), deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.englishShould.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, owner: extractEnglishOwner(s), deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.englishNeedTo.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, owner: extractEnglishOwner(s), deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.englishAction.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.englishTodo.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.englishShall.firstMatch(in: s) {
            let d = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, owner: extractEnglishOwner(s), deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        if let m = try? Pattern.englishLetSomeone.firstMatch(in: s) {
            let o = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let d = String(m.2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard d.count > 2 else { return nil }
            return ActionItem(description: d, owner: o, deadline: extractDeadline(s), sourceSentence: s, timestampSeconds: ts)
        }
        return nil
    }

    private func extractChineseOwner(_ s: String) -> String? {
        let patterns = [ /(\S{2,4})(?:先生|女士|老师|总监会|总监|经理|负责人)/ ]
        for p in patterns { if let m = try? p.firstMatch(in: s) { return String(m.1) } }
        return nil
    }

    private func extractEnglishOwner(_ s: String) -> String? {
        var owner: String?
        let range = s.startIndex..<s.endIndex
        tagger.string = s
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, r in
            if tag == .personalName || tag == .organizationName { owner = String(s[r]); return false }
            return true
        }
        return owner
    }

    private func extractDeadline(_ s: String) -> Date? {
        var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        if s.range(of: "next week", options: .caseInsensitive) != nil { comp.day.map { $0 + 7 }; return Calendar.current.date(from: comp) }
        if s.range(of: "tomorrow", options: .caseInsensitive) != nil { comp.day.map { $0 + 1 }; return Calendar.current.date(from: comp) }
        if s.range(of: "today", options: .caseInsensitive) != nil { return Date() }
        if let m = try? Pattern.byDate.firstMatch(in: s) {
            let ds = String(m.1)
            let f = DateFormatter()
            for fmt in ["MMM d", "MMMM d", "d/MM", "MM/dd"] { f.dateFormat = fmt; if let d = f.date(from: ds) { var c = Calendar.current.dateComponents([.month, .day], from: d); c.year = Calendar.current.component(.year, from: Date()); return Calendar.current.date(from: c) } }
        }
        return nil
    }
}
