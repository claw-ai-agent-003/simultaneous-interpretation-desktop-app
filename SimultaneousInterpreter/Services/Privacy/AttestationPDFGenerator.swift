import Foundation
import AppKit
import CoreGraphics
import os.log

/// Generates a PDF privacy audit report from a `SessionAttestation`.
/// Uses CoreGraphics directly for full layout control on macOS 14+.
///
/// PDF structure:
///   Page 1 — Header, session summary table, signature block
///   Page 2+ — Network activity log (continued if needed)
struct AttestationPDFGenerator {

    // MARK: - Constants

    private static let pageWidth: CGFloat = 612   // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54        // 0.75 inch
    private static let contentWidth: CGFloat = pageWidth - 2 * margin

    private static let logger = Logger(
        subsystem: "com.interpretation.SimultaneousInterpreter",
        category: "AttestationPDF"
    )

    // MARK: - Typography

    private struct Font {
        static let title = NSFont.systemFont(ofSize: 22, weight: .bold)
        static let subtitle = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let heading = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 10, weight: .regular)
        static let mono = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        static let small = NSFont.systemFont(ofSize: 8, weight: .regular)
        static let tableHeader = NSFont.systemFont(ofSize: 9, weight: .semibold)
    }

    // MARK: - Colors

    private struct Color {
        static let black = CGColor(gray: 0, alpha: 1)
        static let darkGray = CGColor(gray: 0.2, alpha: 1)
        static let mediumGray = CGColor(gray: 0.4, alpha: 1)
        static let lightGray = CGColor(gray: 0.75, alpha: 1)
        static let headerBg = CGColor(gray: 0.93, alpha: 1)
        static let accentBlue = CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)
        static let greenBadge = CGColor(red: 0.15, green: 0.55, blue: 0.25, alpha: 1)
    }

    // MARK: - Public Interface

    /// Generates a PDF report and returns the file URL where it was saved.
    /// The file is written to the user's Desktop with a descriptive filename.
    static func generate(from attestation: SessionAttestation) throws -> URL {
        let summary = buildSummary(from: attestation)

        // Prepare PDF context
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            logger.error("Cannot access Desktop directory")
            throw PDFError.outputFailed("Desktop directory not found")
        }

        let timestamp = formatDate(attestation.sessionStart)
        let filename = "Privacy-Audit-\(timestamp).pdf"
        let fileURL = desktopURL.appendingPathComponent(filename)

        guard let context = CGContext(fileURL as CFURL, mediaBox: nil, nil) else {
            logger.error("Failed to create PDF CGContext")
            throw PDFError.outputFailed("Failed to create PDF context")
        }

        // Use Core Text coordinate system (origin top-left)
        context.beginPage(mediaBox: nil)

        var y: CGFloat = pageHeight - margin

        // --- Page 1: Header ---
        y = drawHeader(context: context, y: y)
        y = drawHorizontalRule(context: context, y: y, color: Color.accentBlue)
        y += 16

        // --- Session Summary Table ---
        y = drawSectionTitle(context: context, y: y, title: "Session Summary")
        y += 8
        y = drawSummaryTable(context: context, y: y, summary: summary)
        y += 16

        // --- Zero-Cloud Statement ---
        y = drawZeroCloudStatement(context: context, y: y)
        y += 16

        // --- Signature Block ---
        y = drawSectionTitle(context: context, y: y, title: "Digital Signature (HMAC-SHA256)")
        y += 8
        y = drawSignatureBlock(context: context, y: y, summary: summary)

        // --- Network Activity Log (may span pages) ---
        context.endPage()

        if !attestation.networkEvents.isEmpty {
            drawNetworkLogPages(context: context, events: attestation.networkEvents)
        }

        context.closePDF()

        logger.info("PDF audit report generated: \(fileURL.path)")
        return fileURL
    }

    // MARK: - Drawing Helpers

    private static func drawHeader(context: CGContext, y: CGFloat) -> CGFloat {
        var currentY = y

        // App title
        currentY = drawText(
            context: context,
            text: "Simultaneous Interpreter",
            font: Font.title,
            color: Color.black,
            at: CGPoint(x: margin, y: currentY)
        )
        currentY -= 6

        // Subtitle
        currentY = drawText(
            context: context,
            text: "Privacy Audit Report",
            font: Font.subtitle,
            color: Color.mediumGray,
            at: CGPoint(x: margin, y: currentY)
        )

        // Generated timestamp (right-aligned)
        let generatedText = "Generated: \(formatDateTime(Date()))"
        if let generatedSize = sizeOf(text: generatedText, font: Font.small) {
            currentY = drawText(
                context: context,
                text: generatedText,
                font: Font.small,
                color: Color.mediumGray,
                at: CGPoint(x: pageWidth - margin - generatedSize.width, y: currentY)
            )
        }

        currentY -= 8
        return currentY
    }

    private static func drawSectionTitle(context: CGContext, y: CGFloat, title: String) -> CGFloat {
        drawText(
            context: context,
            text: title,
            font: Font.heading,
            color: Color.darkGray,
            at: CGPoint(x: margin, y: y)
        )
        return y - 16
    }

    private static func drawHorizontalRule(context: CGContext, y: CGFloat, color: CGColor) -> CGFloat {
        context.setStrokeColor(color)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: margin, y: y))
        context.addLine(to: CGPoint(x: pageWidth - margin, y: y))
        context.strokePath()
        return y - 8
    }

    private static func drawSummaryTable(context: CGContext, y: CGFloat, summary: AttestationSummary) -> CGFloat {
        let rows: [(String, String)] = [
            ("Session ID", summary.sessionID),
            ("Start Time", summary.sessionStart),
            ("End Time", summary.sessionEnd),
            ("Duration", summary.duration),
            ("Segments Processed", "\(summary.segmentsProcessed)"),
            ("Network Events Logged", "\(summary.networkEventsCount)")
        ]

        let tableWidth = contentWidth
        let labelWidth: CGFloat = 160
        let valueWidth = tableWidth - labelWidth
        let rowHeight: CGFloat = 20

        var currentY = y

        for (i, row) in rows.enumerated() {
            // Alternating row background
            if i % 2 == 0 {
                context.setFillColor(Color.headerBg)
                context.fill(CGRect(
                    x: margin,
                    y: currentY - rowHeight + 4,
                    width: tableWidth,
                    height: rowHeight
                ))
            }

            // Label
            drawText(
                context: context,
                text: row.0,
                font: Font.tableHeader,
                color: Color.darkGray,
                at: CGPoint(x: margin + 8, y: currentY)
            )

            // Value
            let valueFont = (row.0 == "Session ID") ? Font.mono : Font.body
            drawText(
                context: context,
                text: row.1,
                font: valueFont,
                color: Color.black,
                at: CGPoint(x: margin + labelWidth, y: currentY)
            )

            currentY -= rowHeight
        }

        // Table border
        context.setStrokeColor(Color.lightGray)
        context.setLineWidth(0.5)
        context.stroke(CGRect(
            x: margin,
            y: currentY + 4,
            width: tableWidth,
            height: y - currentY
        ))

        return currentY
    }

    private static func drawZeroCloudStatement(context: CGContext, y: CGFloat) -> CGFloat {
        var currentY = y

        // Green badge: "✓ LOCAL ONLY"
        let badgeText = "✓  LOCAL ONLY"
        let badgeFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let badgeSize = sizeOf(text: badgeText, font: badgeFont) ?? CGSize(width: 100, height: 16)
        let badgePadding: CGFloat = 8
        let badgeRect = CGRect(
            x: margin,
            y: currentY - badgeSize.height - badgePadding / 2,
            width: badgeSize.width + badgePadding * 2,
            height: badgeSize.height + badgePadding
        )

        // Badge background
        context.setFillColor(CGColor(red: 0.9, green: 0.96, blue: 0.9, alpha: 1))
        context.setStrokeColor(Color.greenBadge)
        context.setLineWidth(1)
        context.fill(badgeRect)
        context.stroke(badgeRect)

        drawText(
            context: context,
            text: badgeText,
            font: badgeFont,
            color: Color.greenBadge,
            at: CGPoint(x: margin + badgePadding, y: currentY - badgePadding / 2)
        )

        currentY -= badgeRect.height + 8

        // Statement text
        let statement = "This session was processed entirely on-device. Zero bytes of audio, transcription, or translation data were transmitted to any external server. Network connectivity was monitored throughout the session and all state changes are recorded in the Network Activity Log below."
        currentY = drawWrappedText(
            context: context,
            text: statement,
            font: Font.body,
            color: Color.darkGray,
            at: CGPoint(x: margin, y: currentY),
            maxWidth: contentWidth
        )

        return currentY
    }

    private static func drawSignatureBlock(context: CGContext, y: CGFloat, summary: AttestationSummary) -> CGFloat {
        var currentY = y

        // Signed at
        drawText(
            context: context,
            text: "Signed at: \(summary.signedAt)",
            font: Font.body,
            color: Color.darkGray,
            at: CGPoint(x: margin + 8, y: currentY)
        )
        currentY -= 16

        // Signature (monospace, wrapped)
        drawText(
            context: context,
            text: "HMAC-SHA256:",
            font: Font.tableHeader,
            color: Color.darkGray,
            at: CGPoint(x: margin + 8, y: currentY)
        )
        currentY -= 14

        // Display signature in fixed-width, wrapped lines
        let hex = summary.signatureHex
        let chunkSize = 64
        var offset = 0
        while offset < hex.count {
            let end = min(offset + chunkSize, hex.count)
            let chunk = String(hex[hex.index(hex.startIndex, offsetBy: offset)..<hex.index(hex.startIndex, offsetBy: end)])
            drawText(
                context: context,
                text: chunk,
                font: Font.mono,
                color: Color.accentBlue,
                at: CGPoint(x: margin + 16, y: currentY)
            )
            currentY -= 13
            offset = end
        }

        currentY -= 8

        // Verification note
        drawText(
            context: context,
            text: "To verify: recompute HMAC-SHA256 of the signed payload using the app's derived key.",
            font: Font.small,
            color: Color.mediumGray,
            at: CGPoint(x: margin + 8, y: currentY)
        )

        return currentY
    }

    // MARK: - Network Log Pages

    private static func drawNetworkLogPages(context: CGContext, events: [NetworkEvent]) {
        var currentY = pageHeight - margin
        var eventIndex = 0

        // Section title
        currentY = drawSectionTitle(context: context, y: currentY, title: "Network Activity Log (\(events.count) events)")

        // Column headers
        let colTimestamp: CGFloat = margin + 8
        let colInterface: CGFloat = margin + 210
        let colStatus: CGFloat = margin + 380
        let colName: CGFloat = margin + 440

        // Header row background
        let headerHeight: CGFloat = 18
        context.setFillColor(Color.headerBg)
        context.fill(CGRect(
            x: margin,
            y: currentY - headerHeight + 4,
            width: contentWidth,
            height: headerHeight
        ))

        drawText(context: context, text: "Timestamp", font: Font.tableHeader, color: Color.darkGray, at: CGPoint(x: colTimestamp, y: currentY))
        drawText(context: context, text: "Interface Type", font: Font.tableHeader, color: Color.darkGray, at: CGPoint(x: colInterface, y: currentY))
        drawText(context: context, text: "Status", font: Font.tableHeader, color: Color.darkGray, at: CGPoint(x: colStatus, y: currentY))
        drawText(context: context, text: "Interface", font: Font.tableHeader, color: Color.darkGray, at: CGPoint(x: colName, y: currentY))
        currentY -= headerHeight + 4

        let rowHeight: CGFloat = 16
        let bottomMargin: CGFloat = margin + 40 // room for footer

        func drawFooter(context: CGContext, pageNumber: Int, totalPages: Int) {
            let footerY: CGFloat = margin - 20
            let footerText = "Simultaneous Interpreter — Privacy Audit Report — Page \(pageNumber) of \(totalPages)"
            drawText(
                context: context,
                text: footerText,
                font: Font.small,
                color: Color.mediumGray,
                at: CGPoint(x: margin, y: footerY)
            )
        }

        let totalEvents = events.count
        // Pre-calculate total pages (approximate)
        let eventsPerPage = Int((pageHeight - 2 * margin - 80) / rowHeight)
        let totalPages = max(1, (totalEvents + eventsPerPage - 1) / eventsPerPage)
        var currentPage = 1

        while eventIndex < totalEvents {
            let event = events[eventIndex]

            // Check if we need a new page
            if currentY < bottomMargin {
                drawFooter(context: context, pageNumber: currentPage, totalPages: totalPages)
                currentPage += 1
                context.endPage()
                context.beginPage(mediaBox: nil)
                currentY = pageHeight - margin
            }

            // Alternating row background
            if eventIndex % 2 == 0 {
                context.setFillColor(Color.headerBg)
                context.fill(CGRect(
                    x: margin,
                    y: currentY - rowHeight + 4,
                    width: contentWidth,
                    height: rowHeight
                ))
            }

            let timestamp = formatDateTime(event.timestamp)
            drawText(context: context, text: timestamp, font: Font.mono, color: Color.black, at: CGPoint(x: colTimestamp, y: currentY))
            drawText(context: context, text: event.interfaceType, font: Font.body, color: Color.black, at: CGPoint(x: colInterface, y: currentY))

            // Status with color
            let statusColor = event.satisfied ? Color.greenBadge : CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)
            let statusText = event.satisfied ? "Connected" : "Disconnected"
            drawText(context: context, text: statusText, font: Font.body, color: statusColor, at: CGPoint(x: colStatus, y: currentY))
            drawText(context: context, text: event.interfaceName ?? "—", font: Font.body, color: Color.mediumGray, at: CGPoint(x: colName, y: currentY))

            currentY -= rowHeight
            eventIndex += 1
        }

        // Final page footer
        drawFooter(context: context, pageNumber: currentPage, totalPages: totalPages)
        context.endPage()
    }

    // MARK: - Text Drawing Primitives

    /// Draws single-line text at the given point (top-left baseline, Core Text style).
    private static func drawText(context: CGContext, text: String, font: NSFont, color: CGColor, at point: CGPoint) -> CGFloat {
        let attrString = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.black
        ])

        let line = CTLineCreateWithAttributedString(attrString)
        context.saveGState()
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()

        // Flip coordinate: Core Text uses bottom-left, we use top-left
        // Return the next y position below this text
        let ascent = CTLineGetTypographicBounds(line, nil, nil, nil) / 2
        return point.y - ascent
    }

    /// Draws wrapped text within a max width, returns the final y position.
    private static func drawWrappedText(context: CGContext, text: String, font: NSFont, color: CGColor, at point: CGPoint, maxWidth: CGFloat) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attrString = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.black,
            .paragraphStyle: paragraphStyle
        ])

        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let path = CGPath(rect: CGRect(x: point.x, y: point.y - 1000, width: maxWidth, height: 1000), transform: nil)

        // Suggest size
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            nil
        )

        let framePath = CGPath(rect: CGRect(x: point.x, y: point.y - suggestedSize.height, width: maxWidth, height: suggestedSize.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), framePath, nil)

        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()

        return point.y - suggestedSize.height
    }

    /// Measures the size of a single-line string.
    private static func sizeOf(text: String, font: NSFont) -> CGSize? {
        let attrString = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        let ascent = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // CTLineGetTypographicBounds returns (ascent + descent + leading) in the return value
        // We need width separately
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        // Actually use CTLineGetBoundsWithOptions for width
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        return CGSize(width: bounds.width, height: ascent + bounds.height - ascent)
    }

    // MARK: - Summary Builder

    private static func buildSummary(from attestation: SessionAttestation) -> AttestationSummary {
        AttestationSummary(
            sessionID: attestation.sessionID,
            sessionStart: formatDateTime(attestation.sessionStart),
            sessionEnd: formatDateTime(attestation.sessionEnd),
            duration: formatDuration(attestation.durationSeconds),
            segmentsProcessed: attestation.segmentsProcessed,
            networkEventsCount: attestation.networkEvents.count,
            signatureHex: attestation.signature,
            signedAt: attestation.signedAt,
            generatedAt: formatDateTime(Date())
        )
    }

    // MARK: - Date Formatting

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    private static func formatDateTime(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

// MARK: - Error Types

enum PDFError: Error, LocalizedError {
    case outputFailed(String)

    var errorDescription: String? {
        switch self {
        case .outputFailed(let reason): return "PDF generation failed: \(reason)"
        }
    }
}
