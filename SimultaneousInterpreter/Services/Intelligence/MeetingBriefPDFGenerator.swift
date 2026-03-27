import Foundation
import AppKit
import CoreGraphics
import os.log

struct MeetingBriefPDFGenerator {
    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54
    private static let contentWidth: CGFloat = pageWidth - 2 * margin

    private static let logger = Logger(subsystem: "com.interpretation.SimultaneousInterpreter", category: "MeetingBriefPDF")

    private struct Font {
        static let title = NSFont.systemFont(ofSize: 22, weight: .bold)
        static let subtitle = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let heading = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 10, weight: .regular)
        static let small = NSFont.systemFont(ofSize: 8, weight: .regular)
        static let tableHeader = NSFont.systemFont(ofSize: 9, weight: .semibold)
        static let tableCell = NSFont.systemFont(ofSize: 9, weight: .regular)
    }

    private struct Color {
        static let black = CGColor(gray: 0, alpha: 1)
        static let darkGray = CGColor(gray: 0.15, alpha: 1)
        static let mediumGray = CGColor(gray: 0.4, alpha: 1)
        static let lightGray = CGColor(gray: 0.75, alpha: 1)
        static let headerBg = CGColor(gray: 0.94, alpha: 1)
        static let accentBlue = CGColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 1)
        static let positiveGreen = CGColor(red: 0.15, green: 0.55, blue: 0.3, alpha: 1)
        static let neutralYellow = CGColor(red: 0.7, green: 0.65, blue: 0.1, alpha: 1)
        static let negativeRed = CGColor(red: 0.7, green: 0.2, blue: 0.15, alpha: 1)
        static let white = CGColor(gray: 1, alpha: 1)
    }

    static func generate(from summary: MeetingSummary) throws -> URL {
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw IntelligenceError.pdfGenerationFailed("Desktop directory not found")
        }
        let timestamp = formatTimestamp(summary.meetingDate)
        let sanitizedTitle = summary.meetingTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let filename = "Meeting-Brief-\(sanitizedTitle.prefix(30))-\(timestamp).pdf"
        let fileURL = desktopURL.appendingPathComponent(filename)

        guard let context = CGContext(fileURL as CFURL, mediaBox: nil, nil) else {
            throw IntelligenceError.pdfGenerationFailed("Failed to create PDF context")
        }

        context.beginPage(mediaBox: nil)
        var y: CGFloat = pageHeight - margin
        y = drawHeader(context: context, summary: summary, y: y)
        y = drawHorizontalRule(context: context, y: y, color: Color.accentBlue, thickness: 1.5)
        y += 20
        y = drawBriefText(context: context, summary: summary, y: y)
        y -= 10
        y = drawHorizontalRule(context: context, y: y, color: Color.lightGray, thickness: 0.5)
        y += 10
        y = drawMetadataTable(context: context, summary: summary, y: y)
        y += 20
        y = drawHorizontalRule(context: context, y: y, color: Color.lightGray, thickness: 0.5)
        y += 15
        y = drawSectionHeader(context: context, title: "Key Discussion Topics", y: y)
        y += 5
        y = drawTopicsList(context: context, topics: summary.keyTopics, y: y)
        if y < margin + 200 { context.beginPage(mediaBox: nil); y = pageHeight - margin }
        y += 15
        y = drawHorizontalRule(context: context, y: y, color: Color.lightGray, thickness: 0.5)
        y += 15
        y = drawSectionHeader(context: context, title: "Decisions Made", y: y)
        y += 5
        y = drawDecisionsList(context: context, decisions: summary.decisions, y: y)
        if !summary.actionItems.isEmpty {
            let estH: CGFloat = CGFloat(summary.actionItems.count) * 28 + 40
            if y + estH > pageHeight - margin { context.beginPage(mediaBox: nil); y = pageHeight - margin }
            y += 15
            y = drawHorizontalRule(context: context, y: y, color: Color.lightGray, thickness: 0.5)
            y += 15
            y = drawSectionHeader(context: context, title: "Action Items", y: y)
            y += 5
            y = drawActionItemsTable(context: context, actionItems: summary.actionItems, y: y)
        }
        y += 15
        y = drawHorizontalRule(context: context, y: y, color: Color.lightGray, thickness: 0.5)
        y += 15
        y = drawSentiment(context: context, summary: summary, y: y)
        drawFooter(context: context)
        context.endPage()
        context.closePDF()
        logger.info("Meeting Brief PDF generated: \(fileURL.path)")
        return fileURL
    }

    private static func drawHeader(context: CGContext, summary: MeetingSummary, y: CGFloat) -> CGFloat {
        var yPos = y
        let titleAttr: [NSAttributedString.Key: Any] = [.font: Font.title, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]
        drawText(NSAttributedString(string: summary.meetingTitle, attributes: titleAttr), in: context, x: margin, y: yPos, width: contentWidth, align: .left)
        yPos -= 24
        let subAttr: [NSAttributedString.Key: Any] = [.font: Font.subtitle, .foregroundColor: NSColor(cgColor: Color.mediumGray) ?? .gray]
        drawText(NSAttributedString(string: "Meeting Brief - \(summary.formattedDate)", attributes: subAttr), in: context, x: margin, y: yPos, width: contentWidth, align: .left)
        yPos -= 16
        let badgeText = summary.languagePair
        let badgeAttr: [NSAttributedString.Key: Any] = [.font: Font.small, .foregroundColor: NSColor.white]
        let badgeSize = measureText(badgeText, font: Font.small)
        let badgeBgRect = CGRect(x: margin, y: yPos - 4, width: badgeSize.width + 16, height: badgeSize.height + 8)
        context.setFillColor(Color.accentBlue)
        let bp = CGPath(roundedRect: badgeBgRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(bp); context.fillPath()
        drawText(NSAttributedString(string: badgeText, attributes: badgeAttr), in: context, x: margin + 8, y: yPos, width: badgeSize.width, align: .left)
        return yPos - badgeSize.height - 16
    }

    private static func drawBriefText(context: CGContext, summary: MeetingSummary, y: CGFloat) -> CGFloat {
        var yPos = y
        let lAttr: [NSAttributedString.Key: Any] = [.font: Font.heading, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]
        drawText(NSAttributedString(string: "Summary", attributes: lAttr), in: context, x: margin, y: yPos, width: contentWidth, align: .left)
        yPos -= 16
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 4
        let bAttr: [NSAttributedString.Key: Any] = [.font: Font.body, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black, .paragraphStyle: ps]
        drawText(NSAttributedString(string: summary.briefText, attributes: bAttr), in: context, x: margin, y: yPos, width: contentWidth, align: .left)
        let bh = measureTextHeight(summary.briefText, font: Font.body, width: contentWidth)
        return yPos - bh - 8
    }

    private static func drawMetadataTable(context: CGContext, summary: MeetingSummary, y: CGFloat) -> CGFloat {
        var yPos = y
        let rows: [(String, String)] = [
            ("Duration", summary.formattedDuration),
            ("Language Pair", summary.languagePair),
            ("Participants", "\(summary.participantCount)"),
            ("Key Topics", "\(summary.keyTopics.count)"),
            ("Decisions", "\(summary.decisions.count)"),
            ("Action Items", "\(summary.actionItems.count)")
        ]
        let cw: [CGFloat] = [120, 200]; let rh: CGFloat = 18
        let hRect = CGRect(x: margin, y: yPos - rh, width: cw[0] + cw[1], height: rh)
        context.setFillColor(Color.headerBg); context.fill(hRect)
        let hAttr: [NSAttributedString.Key: Any] = [.font: Font.tableHeader, .foregroundColor: NSColor(cgColor: Color.mediumGray) ?? .gray]
        drawText(NSAttributedString(string: "Field", attributes: hAttr), in: context, x: margin + 8, y: yPos - rh + 4, width: cw[0], align: .left)
        drawText(NSAttributedString(string: "Value", attributes: hAttr), in: context, x: margin + cw[0] + 8, y: yPos - rh + 4, width: cw[1], align: .left)
        yPos -= rh
        let cAttr: [NSAttributedString.Key: Any] = [.font: Font.tableCell, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]
        for (i, row) in rows.enumerated() {
            context.setFillColor(i % 2 == 0 ? Color.white : Color.headerBg)
            context.fill(CGRect(x: margin, y: yPos - rh, width: cw[0] + cw[1], height: rh))
            drawText(NSAttributedString(string: row.0, attributes: cAttr), in: context, x: margin + 8, y: yPos - rh + 4, width: cw[0], align: .left)
            drawText(NSAttributedString(string: row.1, attributes: cAttr), in: context, x: margin + cw[0] + 8, y: yPos - rh + 4, width: cw[1], align: .left)
            yPos -= rh
        }
        context.setStrokeColor(Color.lightGray); context.setLineWidth(0.5)
        context.stroke(CGRect(x: margin, y: yPos, width: cw[0] + cw[1], height: CGFloat(rows.count + 1) * rh))
        return yPos - 5
    }

    private static func drawTopicsList(context: CGContext, topics: [KeyTopic], y: CGFloat) -> CGFloat {
        var yPos = y
        if topics.isEmpty {
            drawText(NSAttributedString(string: "No specific topics identified.", attributes: [.font: Font.body, .foregroundColor: NSColor(cgColor: Color.mediumGray) ?? .gray]), in: context, x: margin, y: yPos, width: contentWidth, align: .left)
            return yPos - 16
        }
        for topic in topics.prefix(10) {
            drawText(NSAttributedString(string: "*", attributes: [.font: Font.body, .foregroundColor: NSColor(cgColor: Color.accentBlue) ?? .blue]), in: context, x: margin, y: yPos, width: 16, align: .center)
            drawText(NSAttributedString(string: topic.title, attributes: [.font: Font.body, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]), in: context, x: margin + 16, y: yPos, width: contentWidth - 16, align: .left)
            yPos -= 14
            drawText(NSAttributedString(string: String(topic.summary.prefix(120)), attributes: [.font: Font.small, .foregroundColor: NSColor(cgColor: Color.mediumGray) ?? .gray]), in: context, x: margin + 24, y: yPos, width: contentWidth - 24, align: .left)
            yPos -= 14
            drawText(NSAttributedString(string: "[\(formatTimestampSeconds(topic.firstMentionSeconds)) - \(formatTimestampSeconds(topic.lastMentionSeconds))]", attributes: [.font: Font.small, .foregroundColor: NSColor(cgColor: Color.lightGray) ?? .lightGray]), in: context, x: margin + 24, y: yPos, width: contentWidth - 24, align: .left)
            yPos -= 18
        }
        return yPos
    }

    private static func drawDecisionsList(context: CGContext, decisions: [Decision], y: CGFloat) -> CGFloat {
        var yPos = y
        if decisions.isEmpty {
            drawText(NSAttributedString(string: "No explicit decisions recorded.", attributes: [.font: Font.body, .foregroundColor: NSColor(cgColor: Color.mediumGray) ?? .gray]), in: context, x: margin, y: yPos, width: contentWidth, align: .left)
            return yPos - 16
        }
        for decision in decisions.prefix(8) {
            context.setFillColor(Color.accentBlue); context.fill(CGRect(x: margin, y: yPos - 4, width: 20, height: 16))
            drawText(NSAttributedString(string: "D", attributes: [.font: Font.small, .foregroundColor: NSColor.white]), in: context, x: margin, y: yPos, width: 20, align: .center)
            drawText(NSAttributedString(string: String(decision.description.prefix(100)), attributes: [.font: Font.body, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]), in: context, x: margin + 28, y: yPos, width: contentWidth - 28, align: .left)
            yPos -= 14
            drawText(NSAttributedString(string: "at \(formatTimestampSeconds(decision.timestampSeconds))", attributes: [.font: Font.small, .foregroundColor: NSColor(cgColor: Color.lightGray) ?? .lightGray]), in: context, x: margin + 28, y: yPos, width: contentWidth - 28, align: .left)
            yPos -= 18
        }
        return yPos
    }

    private static func drawActionItemsTable(context: CGContext, actionItems: [ActionItem], y: CGFloat) -> CGFloat {
        var yPos = y
        let cols: [CGFloat] = [220, 100, 80, 50]; let rh: CGFloat = 26; let tw = cols.reduce(0, +)
        let hRect = CGRect(x: margin, y: yPos - rh, width: tw, height: rh)
        context.setFillColor(Color.accentBlue); context.fill(hRect)
        let hAttr: [NSAttributedString.Key: Any] = [.font: Font.tableHeader, .foregroundColor: NSColor.white]
        var xp = margin + 6
        for (i, h) in ["Description", "Owner", "Deadline", "Time"].enumerated() {
            drawText(NSAttributedString(string: h, attributes: hAttr), in: context, x: xp, y: yPos - rh + 7, width: cols[i] - 8, align: .left)
            xp += cols[i]
        }
        yPos -= rh
        let cAttr: [NSAttributedString.Key: Any] = [.font: Font.tableCell, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]
        for (i, item) in actionItems.prefix(15).enumerated() {
            context.setFillColor(i % 2 == 0 ? Color.white : Color.headerBg)
            context.fill(CGRect(x: margin, y: yPos - rh, width: tw, height: rh))
            context.setStrokeColor(Color.lightGray); context.setLineWidth(0.3)
            context.move(to: CGPoint(x: margin, y: yPos - rh)); context.addLine(to: CGPoint(x: margin + tw, y: yPos - rh)); context.strokePath()
            xp = margin + 6
            drawText(NSAttributedString(string: String(item.description.prefix(45)), attributes: cAttr), in: context, x: xp, y: yPos - rh + 7, width: cols[0] - 8, align: .left); xp += cols[0]
            drawText(NSAttributedString(string: item.owner ?? "-", attributes: cAttr), in: context, x: xp, y: yPos - rh + 7, width: cols[1] - 8, align: .left); xp += cols[1]
            drawText(NSAttributedString(string: item.deadline.map { formatDate($0) } ?? "-", attributes: cAttr), in: context, x: xp, y: yPos - rh + 7, width: cols[2] - 8, align: .left); xp += cols[2]
            drawText(NSAttributedString(string: item.formattedTimestamp, attributes: cAttr), in: context, x: xp, y: yPos - rh + 7, width: cols[3] - 8, align: .left)
            yPos -= rh
        }
        context.setStrokeColor(Color.lightGray); context.setLineWidth(0.5)
        context.stroke(CGRect(x: margin, y: yPos, width: tw, height: CGFloat(min(actionItems.count, 15) + 1) * rh))
        return yPos
    }

    private static func drawSentiment(context: CGContext, summary: MeetingSummary, y: CGFloat) -> CGFloat {
        var yPos = y
        drawText(NSAttributedString(string: "Meeting Tone", attributes: [.font: Font.heading, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]), in: context, x: margin, y: yPos, width: 200, align: .left)
        yPos -= 18
        let sc: CGColor
        switch summary.sentiment { case .positive: sc = Color.positiveGreen; case .neutral: sc = Color.neutralYellow; case .negative: sc = Color.negativeRed }
        context.setFillColor(sc); context.fill(CGPath(roundedRect: CGRect(x: margin, y: yPos - 4, width: 120, height: 22), cornerWidth: 4, cornerHeight: 4, transform: nil))
        drawText(NSAttributedString(string: "\(summary.sentiment.emoji) \(summary.sentiment.displayLabel)", attributes: [.font: Font.body, .foregroundColor: NSColor.white]), in: context, x: margin + 8, y: yPos, width: 110, align: .left)
        return yPos - 30
    }

    private static func drawSectionHeader(context: CGContext, title: String, y: CGFloat) -> CGFloat {
        drawText(NSAttributedString(string: title, attributes: [.font: Font.heading, .foregroundColor: NSColor(cgColor: Color.darkGray) ?? .black]), in: context, x: margin, y: y, width: contentWidth, align: .left)
        return y - 18
    }

    private static func drawFooter(context: CGContext) {
        drawText(NSAttributedString(string: "Generated by Simultaneous Interpreter - \(formatTimestamp(Date()))", attributes: [.font: Font.small, .foregroundColor: NSColor(cgColor: Color.lightGray) ?? .lightGray]), in: context, x: margin, y: margin - 20, width: contentWidth, align: .center)
    }

    private enum TAlign { case left, center, right }
    private static func drawText(_ s: NSAttributedString, in c: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, align: TAlign) {
        let ts = s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
        var xo: CGFloat; switch align { case .left: xo = x; case .center: xo = x + (width - ts.width) / 2; case .right: xo = x + width - ts.width }
        c.saveGState(); c.textMatrix = CGAffineTransform(scaleX: 1, y: -1); c.textPosition = CGPoint(x: xo, y: pageHeight - y - ts.height)
        CTLineDraw(CTLineCreateWithAttributedString(s), c); c.restoreGState()
    }
    private static func measureText(_ t: String, font: NSFont) -> CGSize {
        NSAttributedString(string: t, attributes: [.font: font]).boundingRect(with: CGSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
    }
    private static func measureTextHeight(_ t: String, font: NSFont, width: CGFloat) -> CGFloat {
        NSAttributedString(string: t, attributes: [.font: font]).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
    }
    private static func drawHorizontalRule(context: CGContext, y: CGFloat, color: CGColor, thickness: CGFloat) -> CGFloat {
        context.setStrokeColor(color); context.setLineWidth(thickness)
        context.move(to: CGPoint(x: margin, y: y)); context.addLine(to: CGPoint(x: pageWidth - margin, y: y)); context.strokePath()
        return y - 8
    }
    private static func formatTimestamp(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: d) }
    private static func formatDate(_ d: Date) -> String { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f.string(from: d) }
    private static func formatTimestampSeconds(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }
}
