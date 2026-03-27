import AppKit
import NaturalLanguage
import os.log

class TranscriptListView: NSPanel, NSToolbarDelegate {
    private static let logger = Logger(subsystem: "com.interpretation.SimultaneousInterpreter", category: "TranscriptListView")

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let generateSummaryButton = NSButton(title: "", target: nil, action: nil)
    private let exportPDFButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private let summaryContainer = NSView()
    private let summaryTitleLabel = NSTextField(labelWithString: "")
    private let summaryTextView = NSTextView()
    private let summaryScrollView = NSScrollView()
    private let actionItemsTableView = NSTableView()
    private let actionItemsScrollView = NSScrollView()
    private let exportBriefButton = NSButton(title: "", target: nil, action: nil)
    private let hideSummaryButton = NSButton(title: "", target: nil, action: nil)

    private var segments: [TranscriptSegment] = []
    private var meetingSummary: MeetingSummary?
    private let transcriptExporter = TranscriptExporter()
    private var isGeneratingSummary = false

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 700)
        super.init(contentRect: contentRect, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.title = "Meeting Records"
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setupViews()
        setupTableView()
    }

    private func setupViews() {
        guard let contentView = self.contentView else { return }
        contentView.wantsLayer = true

        headerLabel.stringValue = "Transcript"
        headerLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.drawsBackground = false
        headerLabel.isBezeled = false
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerLabel)

        statusLabel.stringValue = "No sessions recorded"
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.drawsBackground = false
        statusLabel.isBezeled = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        loadingIndicator.style = .spinning
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loadingIndicator)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        generateSummaryButton.title = "Generate Summary"
        generateSummaryButton.bezelStyle = .rounded
        generateSummaryButton.controlSize = .regular
        generateSummaryButton.target = self
        generateSummaryButton.action = #selector(generateSummaryTapped(_:))
        generateSummaryButton.isEnabled = false
        generateSummaryButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(generateSummaryButton)

        exportPDFButton.title = "Export Meeting Brief PDF"
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
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(closeButton)

        summaryContainer.wantsLayer = true
        summaryContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        summaryContainer.layer?.cornerRadius = 8
        summaryContainer.isHidden = true
        summaryContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summaryContainer)

        summaryTitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        summaryTitleLabel.textColor = .labelColor
        summaryTitleLabel.drawsBackground = false
        summaryTitleLabel.isBezeled = false
        summaryTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(summaryTitleLabel)

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

        setupActionItemsTableView()

        exportBriefButton.title = "Export Meeting Brief PDF"
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
        let speakerCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("speaker"))
        speakerCol.title = "Speaker"; speakerCol.width = 100; speakerCol.minWidth = 60
        tableView.addTableColumn(speakerCol)
        let timeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeCol.title = "Time"; timeCol.width = 70; timeCol.minWidth = 50
        tableView.addTableColumn(timeCol)
        let textCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textCol.title = "Transcript"; textCol.width = 380; textCol.minWidth = 200
        tableView.addTableColumn(textCol)
        tableView.delegate = self; tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24; tableView.allowsMultipleSelection = false
        tableView.headerView?.needsDisplay = true
    }

    private func setupActionItemsTableView() {
        let descCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("desc"))
        descCol.title = "Action"; descCol.width = 220
        actionItemsTableView.addTableColumn(descCol)
        let ownerCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("owner"))
        ownerCol.title = "Owner"; ownerCol.width = 100
        actionItemsTableView.addTableColumn(ownerCol)
        let deadlineCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("deadline"))
        deadlineCol.title = "Deadline"; deadlineCol.width = 80
        actionItemsTableView.addTableColumn(deadlineCol)
        actionItemsTableView.delegate = self; actionItemsTableView.dataSource = self
        actionItemsTableView.usesAlternatingRowBackgroundColors = true
        actionItemsTableView.rowHeight = 22
        actionItemsTableView.headerView?.needsDisplay = true
        actionItemsScrollView.documentView = actionItemsTableView
        actionItemsScrollView.hasVerticalScroller = true
        actionItemsScrollView.borderType = .bezelBorder
    }

    func setSegments(_ segments: [TranscriptSegment]) {
        self.segments = segments
        updateUIForSegments()
    }

    func setBilingualSegments(_ bilingualSegments: [BilingualSegment]) {
        var ts: [TranscriptSegment] = []; var current: Double = 0
        for seg in bilingualSegments {
            let start = current; let end = current + seg.durationSeconds; current = end
            ts.append(TranscriptSegment(sourceText: seg.sourceText, englishText: seg.english, mandarinText: seg.mandarin, startSeconds: start, endSeconds: end, speakerLabel: seg.speakerLabel?.displayName, confidence: seg.confidence))
        }
        self.segments = ts; updateUIForSegments()
    }

    private func updateUIForSegments() {
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
        Self.logger.info("Loaded \(self.segments.count) transcript segments")
    }

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
                    self.statusLabel.stringValue = "Summary generated"
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
                let url = try await transcriptExporter.export(segments: segments, format: .meetingBrief, meetingTitle: meetingSummary?.meetingTitle)
                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "PDF exported"
                    self.exportPDFButton.isEnabled = true
                    self.openExportedFile(url)
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
                    self.exportPDFButton.isEnabled = true
                }
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
                    self.statusLabel.stringValue = "Meeting Brief exported"
                    self.openExportedFile(url)
                }
            } catch {
                await MainActor.run {
                    self.loadingIndicator.stopAnimation(nil)
                    self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func hideSummaryTapped(_ sender: NSButton) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            summaryContainer.animator().isHidden = true
            scrollView.animator().isHidden = false
        }
    }

    @objc private func closeTapped(_ sender: NSButton) {
        self.orderOut(nil); self.close()
    }

    private func showSummaryPanel(summary: MeetingSummary) {
        summaryTitleLabel.stringValue = summary.meetingTitle
        var text = summary.briefText
        text += "\n\n---\nDuration: \(summary.formattedDuration)  |  Participants: \(summary.participantCount)  |  Tone: \(summary.sentiment.displayLabel)\n\n"
        if !summary.keyTopics.isEmpty {
            text += "Key Topics:\n"
            for (i, t) in summary.keyTopics.prefix(5).enumerated() { text += "  \(i+1). \(t.title)\n" }
            text += "\n"
        }
        if !summary.decisions.isEmpty {
            text += "Decisions:\n"
            for d in summary.decisions.prefix(5) { text += "  - \(d.description)\n" }
            text += "\n"
        }
        if !summary.actionItems.isEmpty { text += "Action Items: \(summary.actionItems.count) items detected\n" }
        summaryTextView.string = text
        actionItemsTableView.reloadData()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            scrollView.animator().isHidden = true
            summaryContainer.animator().isHidden = false
        }
    }

    private func detectLanguage(from segments: [TranscriptSegment]) -> String {
        let text = segments.map { $0.sourceText.isEmpty ? $0.englishText : $0.sourceText }.joined(separator: " ")
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    private func formatTimestamp(_ s: Double) -> String {
        String(format: "%02d:%02d", Int(s)/60, Int(s)%60)
    }

    private func openExportedFile(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

extension TranscriptListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == self.tableView { return segments.count }
        else if tableView == actionItemsTableView { return meetingSummary?.actionItems.count ?? 0 }
        return 0
    }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if tableView == self.tableView {
            guard row < segments.count else { return nil }
            let seg = segments[row]
            switch tableColumn?.identifier.rawValue {
            case "speaker": return seg.speakerLabel ?? "-"
            case "time": return formatTimestamp(seg.startSeconds)
            case "text": return seg.sourceText.isEmpty ? seg.englishText : seg.sourceText
            default: return nil
            }
        } else if tableView == actionItemsTableView {
            guard let summary = meetingSummary, row < summary.actionItems.count else { return nil }
            let item = summary.actionItems[row]
            switch tableColumn?.identifier.rawValue {
            case "desc": return item.description
            case "owner": return item.owner ?? "-"
            case "deadline": return item.deadline.map { let f = DateFormatter(); f.dateStyle = .short; return f.string(from: $0) } ?? "-"
            default: return nil
            }
        }
        return nil
    }
}

extension TranscriptListView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView == self.tableView ? 28 : 22
    }
}
