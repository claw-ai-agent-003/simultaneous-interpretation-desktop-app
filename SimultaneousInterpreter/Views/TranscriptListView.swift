import AppKit
import NaturalLanguage
import os.log

// MARK: - Transcript List View

/// A panel view for displaying meeting transcripts, generating summaries,
/// and exporting Meeting Brief PDFs.
///
/// Shown when the user taps the "📒 会议记录" button in the overlay.
class TranscriptListView: NSPanel, NSToolbarDelegate {

    // MARK: - Constants

    private static let logger = Logger(
        subsystem: "com.interpretation.SimultaneousInterpreter",
        category: "TranscriptListView"
    )

    // MARK: - UI Components

    private let scrollView: NSScrollView
    private let tableView: NSTableView
    private let headerLabel: NSTextField
    private let generateSummaryButton: NSButton
    private let exportPDFButton: NSButton
    private let closeButton: NSButton
    private let statusLabel: NSTextField
    private let loadingIndicator: NSProgressIndicator

    /// Summary panel shown after generation.
    private let summaryContainer: NSView
    private let summaryTitleLabel: NSTextField
    private let summaryTextView: NSTextView
    private let summaryScrollView: NSScrollView
    private let actionItemsTableView: NSTableView
    private let actionItemsScrollView: NSScrollView
    private let exportBriefButton: NSButton
    private let hideSummaryButton: NSButton

    // MARK: - State

    private var segments: [TranscriptSegment] = []
    private var meetingSummary: MeetingSummary?
    private let transcriptExporter = TranscriptExporter()
    private var isGeneratingSummary = false

    // MARK: - Initialization

    init() {
        scrollView = NSScrollView()
        tableView = NSTableView()
        headerLabel = NSTextField(labelWithString: "")
        generateSummaryButton = NSButton(title: "", target: nil, action: nil)
        exportPDFButton = NSButton(title: "", target: nil, action: nil)
        closeButton = NSButton(title: "", target: nil, action: nil)
        statusLabel = NSTextField(labelWithString: "")
        loadingIndicator = NSProgressIndicator()
        summaryContainer = NSView()
        summaryTitleLabel = NSTextField(labelWithString: "")
        summaryTextView = NSTextView()
        summaryScrollView = NSScrollView()
        actionItemsTableView = NSTableView()
        actionItemsScrollView = NSScrollView()
        exportBriefButton = NSButton(title: "", target: nil, action: nil)
        hideSummaryButton = NSButton(title: "", target: nil, action: nil)

        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 700)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.title = "Meeting Records"
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        setupViews()
        setupTableView()
        setupToolbar()
    }

    // MARK: - Setup

    private func setupViews() {
        guard let contentView = self.contentView else { return }
        contentView.wantsLayer = true

        // ── Header ────────────────────────────────────────────────────────────
        headerLabel.stringValue = "Transcript"
        headerLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.drawsBackground = false
        headerLabel.isBezeled = false
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerLabel)

        // Status label
        statusLabel.stringValue = "No sessions recorded"
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.drawsBackground = false
        statusLabel.isBezeled = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        // Loading indicator
        loadingIndicator.style = .spinning
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loadingIndicator)

        // ── Table View ────────────────────────────────────────────────────────
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // ── Button Row ─────────────────────────────────────────────────────────
        generateSummaryButton.title = "📋 Generate Summary"
        generateSummaryButton.bezelStyle = .rounded
        generateSummaryButton.controlSize = .regular
        generateSummaryButton.target = self
        generateSummaryButton.action = #selector(generateSummaryTapped(_:))
        generateSummaryButton.isEnabled = false
        generateSummaryButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(generateSummaryButton)

        exportPDFButton.title = "📄 Export Meeting Brief PDF"
        exportPDFButton.bezelStyle = .rounded
        exportPDFButton.controlSize = .regular
        exportPDFButton.target = self
        exportPDFButton.action = #selector(exportPDFTapped(_:))
        exportPDFButton.isEnabled = false
        exportPDFButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(exportPDFButton)

        closeButton.title = "Close"
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .regular
        closeButton.target = self
        closeButton.action = #selector(closeTapped(_:))
        closeButton.keyEquivalent = "\u{1b}" // Escape key
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(closeButton)

        // ── Summary Container (hidden initially) ───────────────────────────────
        summaryContainer.wantsLayer = true
        summaryContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        summaryContainer.layer?.cornerRadius = 8
        summaryContainer.isHidden = true
        summaryContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summaryContainer)

        // Summary title
        summaryTitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        summaryTitleLabel.textColor = .labelColor
        summaryTitleLabel.drawsBackground = false
        summaryTitleLabel.isBezeled = false
        summaryTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(summaryTitleLabel)

        // Summary text view
        summaryTextView.isEditable = false
        summaryTextView.isSelectable = true
        summaryTextView.font = NSFont.systemFont(ofSize: 11)
        summaryTextView.textColor = .labelColor
        summaryTextView.drawsBackground = true
        summaryTextView.backgroundColor = NSColor.textBackgroundColor
        summaryTextView.autoresizingMask = [.width]
        summaryTextView.isVerticallyResizable = true
        summaryTextView.isHorizontallyResizable = false
        summaryTextView.textContainer?.widthTracksTextView = true

        summaryScrollView.documentView = summaryTextView
        summaryScrollView.hasVerticalScroller = true
        summaryScrollView.hasHorizontalScroller = false
        summaryScrollView.autohidesScrollers = true
        summaryScrollView.borderType = .bezelBorder
        summaryScrollView.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(summaryScrollView)

        // Action items table in summary
        setupActionItemsTableView()

        // Summary action buttons
        exportBriefButton.title = "📄 Export Meeting Brief PDF"
        exportBriefButton.bezelStyle = .rounded
        exportBriefButton.controlSize = .regular
        exportBriefButton.target = self
        exportBriefButton.action = #selector(exportBriefTapped(_:))
        exportBriefButton.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(exportBriefButton)

        hideSummaryButton.title = "Hide Summary"
        hideSummaryButton.bezelStyle = .rounded
        hideSummaryButton.controlSize = .regular
        hideSummaryButton.target = self
        hideSummaryButton.action = #selector(hideSummaryTapped(_:))
        hideSummaryButton.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(hideSummaryButton)

        // ── Layout ─────────────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            statusLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            loadingIndicator.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            loadingIndicator.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: generateSummaryButton.topAnchor, constant: -12),

            generateSummaryButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            generateSummaryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            generateSummaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            exportPDFButton.leadingAnchor.constraint(equalTo: generateSummaryButton.trailingAnchor, constant: 12),
            exportPDFButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            exportPDFButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            // Summary container
            summaryContainer.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            summaryContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            summaryContainer.bottomAnchor.constraint(equalTo: exportBriefButton.topAnchor, constant: -12),

            summaryTitleLabel.topAnchor.constraint(equalTo: summaryContainer.topAnchor, constant: 12),
            summaryTitleLabel.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 12),
            summaryTitleLabel.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor, constant: -12),

            summaryScrollView.topAnchor.constraint(equalTo: summaryTitleLabel.bottomAnchor, constant: 8),
            summaryScrollView.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 12),
            summaryScrollView.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor, constant: -12),
            summaryScrollView.heightAnchor.constraint(equalToConstant: 120),

            actionItemsScrollView.topAnchor.constraint(equalTo: summaryScrollView.bottomAnchor, constant: 8),
            actionItemsScrollView.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 12),
            actionItemsScrollView.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor, constant: -12),
            actionItemsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            exportBriefButton.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 12),
            exportBriefButton.bottomAnchor.constraint(equalTo: summaryContainer.bottomAnchor, constant: -12),

            hideSummaryButton.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor, constant: -12),
            hideSummaryButton.bottomAnchor.constraint(equalTo: summaryContainer.bottomAnchor, constant: -12),
        ])
    }

    private func setupTableView() {
        // Speaker column
        let speakerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("speaker"))
        speakerColumn.title = "Speaker"
        speakerColumn.width = 100
        speakerColumn.minWidth = 60
        tableView.addTableColumn(speakerColumn)

        // Time column
        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.title = "Time"
        timeColumn.width = 70
        timeColumn.minWidth = 50
        tableView.addTableColumn(timeColumn)

        // Text column
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "Transcript"
        textColumn.width = 380
        textColumn.minWidth = 200
        tableView.addTableColumn(textColumn)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.allowsMultipleSelection = false
        tableView.headerView?.needsDisplay = true
    }

    private func setupActionItemsTableView() {
        let descColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("desc"))
        descColumn.title = "Action"
        descColumn.width = 220
        actionItemsTableView.addTableColumn(descColumn)

        let ownerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("owner"))
        ownerColumn.title = "Owner"
        ownerColumn.width = 100
        actionItemsTableView.addTableColumn(ownerColumn)

        let deadlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("deadline"))
        deadlineColumn.title = "Deadline"
        deadlineColumn.width = 80
        actionItemsTableView.addTableColumn(deadlineColumn)

        actionItemsTableView.delegate = self
        actionItemsTableView.dataSource = self
        actionItemsTableView.usesAlternatingRowBackgroundColors = true
        actionItemsTableView.rowHeight = 22
        actionItemsTableView.headerView?.needsDisplay = true

        actionItemsScrollView.documentView = actionItemsTableView
        actionItemsScrollView.hasVerticalScroller = true
        actionItemsScrollView.borderType = .bezelBorder
    }

    private func setupToolbar() {
        // Toolbar is optional for this floating panel
    }

    // MARK: - Public Interface

    /// Sets the transcript segments to display.
    func setSegments(_ segments: [TranscriptSegment]) {
        self.segments = segments

        if segments.isEmpty {
            statusLabel.stringValue = "No sessions recorded"
            generateSummaryButton.isEnabled = false
            exportPDFButton.isEnabled = false
        } else {
            statusLabel.stringValue = "\(segments.count) segments recorded"
            generateSummaryButton.isEnabled = true
            exportPDFButton.isEnabled = true
        }

        tableView.reloadData()
        Self.logger.info("Loaded \(segments.count) transcript segments")
    }

    // MARK: - Actions

    @objc private func generateSummaryTapped(_ sender: NSButton) {
        guard !segments.isEmpty else { return }

        isGeneratingSummary = true
        loadingIndicator.startAnimation(nil)
        statusLabel.stringValue = "Generating summary..."
        generateSummaryButton.isEnabled = false

        Task {
            do {
                let summarizer = SummarizationService()
                let language = detectLanguage(from: segments)
                let summary = try await summarizer.generateSummary(from: segments, language: language)

                await MainActor.run {
                    self.meetingSummary = summary
                    self.isGeneratingSummary = false
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "Summary generated ✓"
                    self.generateSummaryButton.isEnabled = true
                    self.showSummaryPanel(summary: summary)
                }
            } catch {
                await MainActor.run {
                    self.isGeneratingSummary = false
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "Summary failed: \(error.localizedDescription)"
                    self.generateSummaryButton.isEnabled = true
                }
                Self.logger.error("Summary generation failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func exportPDFTapped(_ sender: NSButton) {
        guard !segments.isEmpty else { return }

        loadingIndicator.startAnimation(nil)
        statusLabel.stringValue = "Exporting PDF..."
        exportPDFButton.isEnabled = false

        Task {
            do {
                let url = try await transcriptExporter.export(
                    segments: segments,
                    format: .meetingBrief,
                    meetingTitle: meetingSummary?.meetingTitle
                )

                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "PDF exported ✓"
                    self.exportPDFButton.isEnabled = true
                    self.openExportedFile(url)
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
                    self.exportPDFButton.isEnabled = true
                }
                Self.logger.error("PDF export failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func exportBriefTapped(_ sender: NSButton) {
        guard let summary = meetingSummary else { return }

        loadingIndicator.startAnimation(nil)
        statusLabel.stringValue = "Exporting Meeting Brief..."

        Task {
            do {
                let url = try await transcriptExporter.exportAsMeetingBriefPdf(from: summary)

                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "Meeting Brief exported ✓"
                    self.openExportedFile(url)
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
                }
                Self.logger.error("Meeting Brief export failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func hideSummaryTapped(_ sender: NSButton) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            summaryContainer.animator().isHidden = true
            scrollView.animator().isHidden = false
        }
    }

    @objc private func closeTapped(_ sender: NSButton) {
        self.orderOut(nil)
        self.close()
    }

    // MARK: - Summary Panel

    private func showSummaryPanel(summary: MeetingSummary) {
        summaryTitleLabel.stringValue = "📋 \(summary.meetingTitle)"

        // Build summary text
        var summaryText = summary.briefText
        summaryText += "\n\n---\n"
        summaryText += "Duration: \(summary.formattedDuration)  |  "
        summaryText += "Participants: \(summary.participantCount)  |  "
        summaryText += "Tone: \(summary.sentiment.displayLabel)\n\n"

        if !summary.keyTopics.isEmpty {
            summaryText += "Key Topics:\n"
            for (i, topic) in summary.keyTopics.prefix(5).enumerated() {
                summaryText += "  \(i + 1). \(topic.title)\n"
            }
            summaryText += "\n"
        }

        if !summary.decisions.isEmpty {
            summaryText += "Decisions:\n"
            for decision in summary.decisions.prefix(5) {
                summaryText += "  ✓ \(decision.description)\n"
            }
            summaryText += "\n"
        }

        if !summary.actionItems.isEmpty {
            summaryText += "Action Items: \(summary.actionItems.count) items detected\n"
        }

        summaryTextView.string = summaryText

        // Reload action items table
        actionItemsTableView.reloadData()

        // Show summary container
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            scrollView.animator().isHidden = true
            summaryContainer.animator().isHidden = false
        }
    }

    // MARK: - Helpers

    private func detectLanguage(from segments: [TranscriptSegment]) -> String {
        let allText = segments.map { $0.sourceText.isEmpty ? $0.englishText : $0.sourceText }.joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(allText)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func openExportedFile(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - NSTableViewDataSource

extension TranscriptListView: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == self.tableView {
            return segments.count
        } else if tableView == actionItemsTableView {
            return meetingSummary?.actionItems.count ?? 0
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if tableView == self.tableView {
            guard row < segments.count else { return nil }
            let segment = segments[row]

            switch tableColumn?.identifier.rawValue {
            case "speaker":
                return segment.speakerLabel ?? "—"
            case "time":
                return formatTimestamp(segment.startSeconds)
            case "text":
                return segment.sourceText.isEmpty ? segment.englishText : segment.sourceText
            default:
                return nil
            }
        } else if tableView == actionItemsTableView {
            guard let summary = meetingSummary, row < summary.actionItems.count else { return nil }
            let item = summary.actionItems[row]

            switch tableColumn?.identifier.rawValue {
            case "desc":
                return item.description
            case "owner":
                return item.owner ?? "—"
            case "deadline":
                if let deadline = item.deadline {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    return formatter.string(from: deadline)
                }
                return "—"
            default:
                return nil
            }
        }
        return nil
    }
}

// MARK: - NSTableViewDelegate

extension TranscriptListView: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView == self.tableView {
            return 28
        } else if tableView == actionItemsTableView {
            return 22
        }
        return 22
    }
}
