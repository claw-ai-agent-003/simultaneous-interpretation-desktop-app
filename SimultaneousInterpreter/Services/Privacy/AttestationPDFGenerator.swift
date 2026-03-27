import AppKit
import CoreGraphics
import Foundation

// ============================================================
// MARK: - PDF Attestation Report Generator
// ============================================================

/// Generates a professional PDF privacy audit report from a `SessionAttestation`.
///
/// The report includes:
/// - Company header and report title
/// - Session summary (ID, timestamps, duration, segments)
/// - Privacy verdict with color-coded status
/// - Detailed network activity log table
/// - HMAC-SHA256 signature verification block
///
/// Uses CoreGraphics directly for full control over layout and typography.
class AttestationPDFGenerator {

    // MARK: - Constants

    private let pageWidth: CGFloat = 612.0   // US Letter width
    private let pageHeight: CGFloat = 792.0  // US Letter height
    private let marginTop: CGFloat = 60.0
    private let marginBottom: CGFloat = 60.0
    private let marginLeft: CGFloat = 54.0
    private let marginRight: CGFloat = 54.0
    private let contentWidth: CGFloat

    private let companyName = "SimultaneousInterpreter"
    private let reportTitle = "Privacy Audit Report"

    // MARK: - Colors

    private let colorText = CGColor(gray: 0.2, alpha: 1.0)
    private let colorSecondaryText = CGColor(gray: 0.4, alpha: 1.0)
    private let colorHeaderBg = CGColor(red: 0.1, green: 0.1, alpha: 1.0)
    private let colorHeaderFg = CGColor(gray: 1.0, alpha: 1.0)
    private let colorRowEven = CGColor(gray: 0.97, alpha: 1.0)
    private let colorRowOdd = CGColor(gray: 1.0, alpha: 1.0)
    private let colorBorder = CGColor(gray: 0.85, alpha: 1.0)
    private let colorGreen = CGColor(red: 0.2, green: 0.7, alpha: 0.2)
    private let colorGreenText = CGColor(red: 0.1, green: 0.6, alpha: 1.0)
    private let colorRed = CGColor(red: 0.9, green: 0.2, alpha: 0.2)
    private let colorRedText = CGColor(red: 0.8, green: 0.1, alpha: 1.0)
    private let colorSignatureBg = CGColor(gray: 0.95, alpha: 1.0)

    // MARK: - Initialization

    init() {
        contentWidth = pageWidth - marginLeft - marginRight
    }

    // MARK: - Public Interface

    /// Generates a PDF report from the given attestation.
    /// - Parameter attestation: The session attestation to report on.
    /// - Returns: `Data` containing the complete PDF document.
    func generatePDF(from attestation: SessionAttestation) -> Data {
        let mutableData = NSMutableData()
        guard let context = CGContext(mutableData, mediaBox: nil) else {
            print("AttestationPDFGenerator: Failed to create PDF context")
            return Data()
        }

        var yOffset = pageHeight - marginTop
        var pageIndex = 0

        // --- Page 1 ---

        // Header
        drawHeader(context: context, yOffset: &yOffset)

        // Session summary
        yOffset -= 12
        drawSessionSummary(context: context, attestation: attestation, yOffset: &yOffset)

        // Privacy verdict
        yOffset -= 12
        drawVerdict(context: context, attestation: attestation, yOffset: &yOffset)

        // Network activity log header
        yOffset -= 16
        if yOffset < marginBottom + 200 {
            context.beginPage(mediaBox: nil)
            pageIndex += 1
            yOffset = pageHeight - marginTop
            drawPageFooter(context: context, yOffset: &yOffset, pageIndex: pageIndex)
        }

        drawNetworkLogHeader(context: context, yOffset: &yOffset)

        // Network activity log rows
        for (index, record) in attestation.networkLog.enumerated() {
            let rowHeight: CGFloat = 36.0

            if yOffset - rowHeight < marginBottom + 30 {
                // New page
                context.beginPage(mediaBox: nil)
                pageIndex += 1
                yOffset = pageHeight - marginTop
                drawPageFooter(context: context, yOffset: &yOffset, pageIndex: pageIndex)
                drawNetworkLogHeader(context: context, yOffset: &yOffset)
            }

            drawNetworkLogRow(context: context, record: record, index: index, yOffset: &yOffset)
        }

        // Signature block
        yOffset -= 24
        if yOffset < marginBottom + 180 {
            context.beginPage(mediaBox: nil)
            pageIndex += 1
            yOffset = pageHeight - marginTop
            drawPageFooter(context: context, yOffset: &yOffset, pageIndex: pageIndex)
        }

        drawSignatureBlock(context: context, attestation: attestation, yOffset: &yOffset)

        // Page 1 footer
        drawPageFooter(context: context, yOffset: &yOffset, pageIndex: pageIndex)

        context.closePDF()

        return mutableData as Data
    }

    /// Generates the PDF and writes it to a temporary file, then returns the URL.
    func generatePDFAndSave(attestation: SessionAttestation) throws -> URL {
        let pdfData = generatePDF(from: attestation)

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "privacy-audit-\(attestation.sessionId).pdf"
        let fileURL = tempDir.appendingPathComponent(fileName)

        try pdfData.write(to: fileURL, options: .atomic)
        print("AttestationPDFGenerator: PDF saved to \(fileURL.path)")
        return fileURL
    }

    // MARK: - Drawing: Header

    private func drawHeader(context: CGContext, yOffset: inout CGFloat) {
        // Dark header background
        let headerHeight: CGFloat = 70.0
        let rect = CGRect(x: marginLeft, y: yOffset - headerHeight, width: contentWidth, height: headerHeight)

        context.setFillColor(colorHeaderBg)
        context.fill(rect)

        // Company name
        let companyNameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor(cgColor: colorHeaderFg)!
        ]
        let companyStr = NSAttributedString(string: companyName, attributes: companyNameAttrs)
        let companySize = companyStr.size()
        companyStr.draw(at: CGPoint(x: marginLeft + 16, y: yOffset - 30))

        // Report title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor(cgColor: CGColor(gray: 0.7, alpha: 1.0))!
        ]
        let titleStr = NSAttributedString(string: reportTitle, attributes: titleAttrs)
        titleStr.draw(at: CGPoint(x: marginLeft + 16, y: yOffset - 50))

        yOffset -= headerHeight + 8
    }

    // MARK: - Drawing: Session Summary

    private func drawSessionSummary(context: CGContext, attestation: SessionAttestation, yOffset: inout CGFloat) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(cgColor: colorSecondaryText)!
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(cgColor: colorText)!
        ]

        let rows: [(String, String)] = [
            ("Session ID", attestation.sessionId),
            ("Start Time", attestation.sessionStartTime),
            ("End Time", attestation.sessionEndTime),
            ("Duration", formatDuration(attestation.sessionDurationSeconds)),
            ("Segments Processed", "\(attestation.segmentCount)"),
            ("Network Events", "\(attestation.networkEventCount)"),
            ("Total Outbound Bytes", "\(attestation.totalOutboundBytes)"),
            ("App Version", attestation.appVersion),
            ("OS Version", attestation.osVersion),
            ("Hardware", attestation.hardwareModel)
        ]

        let rowHeight: CGFloat = 22.0
        let totalHeight = CGFloat(rows.count) * rowHeight + 12.0

        // Section title
        let sectionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor(cgColor: colorText)!
        ]
        let sectionStr = NSAttributedString(string: "Session Summary", attributes: sectionAttrs)
        sectionStr.draw(at: CGPoint(x: marginLeft, y: yOffset - 16))
        yOffset -= 20

        // Table border
        let tableRect = CGRect(x: marginLeft, y: yOffset - totalHeight, width: contentWidth, height: totalHeight)
        context.setStrokeColor(colorBorder)
        context.setLineWidth(0.5)
        context.stroke(tableRect)

        for (index, (label, value)) in rows.enumerated() {
            let y = yOffset - CGFloat(index + 1) * rowHeight

            // Alternating row background
            if index % 2 == 0 {
                context.setFillColor(colorRowEven)
            } else {
                context.setFillColor(colorRowOdd)
            }
            context.fill(CGRect(x: marginLeft, y: y - 2, width: contentWidth, height: rowHeight))

            let labelStr = NSAttributedString(string: label, attributes: labelAttrs)
            let valueStr = NSAttributedString(string: value, attributes: valueAttrs)

            labelStr.draw(at: CGPoint(x: marginLeft + 12, y: y + 4))
            valueStr.draw(at: CGPoint(x: marginLeft + 180, y: y + 4))
        }

        yOffset -= totalHeight
    }

    // MARK: - Drawing: Verdict

    private func drawVerdict(context: CGContext, attestation: SessionAttestation, yOffset: inout CGFloat) {
        let boxHeight: CGFloat = 50.0
        let boxRect = CGRect(x: marginLeft, y: yOffset - boxHeight, width: contentWidth, height: boxHeight)

        // Color-coded background
        if attestation.zeroBytesSent {
            context.setFillColor(colorGreen)
        } else {
            context.setFillColor(colorRed)
        }
        context.fill(boxRect)

        // Border
        context.setStrokeColor(attestation.zeroBytesSent ? colorGreenText : colorRedText)
        context.setLineWidth(1.5)
        context.stroke(boxRect)

        // Status icon + verdict text
        let statusText = attestation.zeroBytesSent ? "✓  CLEAN — Zero bytes sent to any external server" : "✗  WARNING — Data was sent to external servers"
        let textColor = attestation.zeroBytesSent
            ? NSColor(cgColor: colorGreenText)!
            : NSColor(cgColor: colorRedText)!

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: textColor
        ]
        let str = NSAttributedString(string: statusText, attributes: attrs)
        let strSize = str.size()
        let x = marginLeft + (contentWidth - strSize.width) / 2
        let y = boxRect.midY - strSize.height / 2
        str.draw(at: CGPoint(x: x, y: y))

        yOffset -= boxHeight
    }

    // MARK: - Drawing: Network Log

    private func drawNetworkLogHeader(context: CGContext, yOffset: inout CGFloat) {
        // Section title
        let sectionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor(cgColor: colorText)!
        ]
        let sectionStr = NSAttributedString(string: "Network Activity Log", attributes: sectionAttrs)
        sectionStr.draw(at: CGPoint(x: marginLeft, y: yOffset - 16))
        yOffset -= 20

        // Column headers
        let headerHeight: CGFloat = 28.0
        let headerRect = CGRect(x: marginLeft, y: yOffset - headerHeight, width: contentWidth, height: headerHeight)
        context.setFillColor(colorHeaderBg)
        context.fill(headerRect)

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(cgColor: colorHeaderFg)!
        ]

        let columns = [
            ("#", marginLeft + 8),
            ("Timestamp", marginLeft + 32),
            ("Remote Host", marginLeft + 190),
            ("Port", marginLeft + 350),
            ("Bytes", marginLeft + 400),
            ("Status", marginLeft + 460)
        ]

        for (title, x) in columns {
            let str = NSAttributedString(string: title, attributes: headerAttrs)
            str.draw(at: CGPoint(x: x, y: yOffset - 18))
        }

        yOffset -= headerHeight
    }

    private func drawNetworkLogRow(context: CGContext, record: NetworkActivityRecord, index: Int, yOffset: inout CGFloat) {
        let rowHeight: CGFloat = 36.0

        // Alternating row background
        if index % 2 == 0 {
            context.setFillColor(colorRowEven)
        } else {
            context.setFillColor(colorRowOdd)
        }
        context.fill(CGRect(x: marginLeft, y: yOffset - rowHeight, width: contentWidth, height: rowHeight))

        // Row border
        context.setStrokeColor(colorBorder)
        context.setLineWidth(0.25)
        context.stroke(CGRect(x: marginLeft, y: yOffset - rowHeight, width: contentWidth, height: rowHeight))

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(cgColor: colorText)!
        ]

        let bytesColor = record.bytesSent > 0
            ? NSColor(cgColor: colorRedText)!
            : NSColor(cgColor: colorGreenText)!

        let bytesAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: bytesColor
        ]

        let statusText = record.satisfied ? "OK" : "N/A"
        let portText = record.remotePort.map { "\($0)" } ?? "—"

        let fields: [(String, CGFloat, [NSAttributedString.Key: Any])] = [
            ("\(index + 1)", marginLeft + 8, textAttrs),
            (record.timestamp, marginLeft + 32, textAttrs),
            (record.remoteHost, marginLeft + 190, textAttrs),
            (portText, marginLeft + 350, textAttrs),
            ("\(record.bytesSent)", marginLeft + 400, bytesAttrs),
            (statusText, marginLeft + 460, textAttrs)
        ]

        for (text, x, attrs) in fields {
            let str = NSAttributedString(string: text, attributes: attrs)
            str.draw(at: CGPoint(x: x, y: yOffset - 22))
        }

        yOffset -= rowHeight
    }

    // MARK: - Drawing: Signature Block

    private func drawSignatureBlock(context: CGContext, attestation: SessionAttestation, yOffset: inout CGFloat) {
        let boxHeight: CGFloat = 120.0
        let boxRect = CGRect(x: marginLeft, y: yOffset - boxHeight, width: contentWidth, height: boxHeight)

        // Background
        context.setFillColor(colorSignatureBg)
        context.fill(boxRect)
        context.setStrokeColor(colorBorder)
        context.setLineWidth(0.5)
        context.stroke(boxRect)

        // Section title
        let sectionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor(cgColor: colorText)!
        ]
        let sectionStr = NSAttributedString(string: "Digital Signature", attributes: sectionAttrs)
        sectionStr.draw(at: CGPoint(x: marginLeft + 16, y: yOffset - 22))

        // Signature details
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor(cgColor: colorSecondaryText)!
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(cgColor: colorText)!
        ]

        let fields = [
            ("Algorithm:", attestation.signatureAlgorithm),
            ("Signature:", attestation.signature)
        ]

        var y = yOffset - 44
        for (label, value) in fields {
            let labelStr = NSAttributedString(string: label, attributes: labelAttrs)
            labelStr.draw(at: CGPoint(x: marginLeft + 16, y: y))

            let valueStr = NSAttributedString(string: value, attributes: valueAttrs)
            valueStr.draw(at: CGPoint(x: marginLeft + 100, y: y))

            y -= 18
        }

        // Verification note
        let noteAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .italic),
            .foregroundColor: NSColor(cgColor: colorSecondaryText)!
        ]
        let noteStr = NSAttributedString(
            string: "This attestation was signed with HMAC-SHA256 using a device-specific key stored in macOS Keychain.",
            attributes: noteAttrs
        )
        noteStr.draw(at: CGPoint(x: marginLeft + 16, y: y - 6))

        yOffset -= boxHeight
    }

    // MARK: - Drawing: Page Footer

    private func drawPageFooter(context: CGContext, yOffset: inout CGFloat, pageIndex: Int) {
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor(cgColor: colorSecondaryText)!
        ]
        let footerStr = NSAttributedString(string: "\(companyName) — \(reportTitle) — Page \(pageIndex + 1)", attributes: footerAttrs)
        let size = footerStr.size()
        footerStr.draw(at: CGPoint(x: marginLeft, y: marginBottom - 20))
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? "\(String(format: "%.1f", seconds))s"
    }
}
