import AppKit

/// The main view rendered inside the overlay window.
/// Displays pre-session prompt, audio level bar, and bilingual transcription segments.
class OverlayView: NSView {

    // MARK: - UI Components

    private let blurView: NSVisualEffectView
    private let stackView: NSStackView
    private let privacyIndicator: NSView
    private let privacyDot: NSView
    private let privacyLabel: NSTextField
    private let privacyToggle: NSSwitch
    private let audioLevelBar: NSProgressIndicator
    private let audioLevelLabel: NSTextField
    private let preSessionLabel: NSTextField
    private let scrollView: NSScrollView
    private let segmentsStackView: NSStackView

    /// Shown when session ends.
    private let sessionEndedLabel: NSTextField

    /// Button to export the privacy audit report as PDF.
    private let exportAuditButton: NSButton

    /// Panic button for human interpreter fallback (P3.3).
    private(set) var panicButton: InterpreterPanicButton?

    /// Language pair switching popup button.
    private let languageSwitcher: NSPopUpButton

    /// Toolbar row containing language switcher and privacy controls.
    private var toolbarRow: NSStackView?

    // MARK: - State

    private var segments: [BilingualSegment] = []
    private let maxSegments = 50

    /// Active segment views keyed by chunk index for partial updates.
    private var segmentViews: [Int: SegmentView] = [:]

    /// Whether session has ended.
    private var sessionEnded = false

    /// Timer for auto-clearing session-ended state.
    private var sessionEndTimer: Timer?

    /// Callback invoked when the user taps "Export Audit Report".
    var onExportAuditReport: (() -> Void)?

    /// Callback invoked when the user selects a new language pair.
    var onLanguagePairChanged: ((LanguagePair) -> Void)?

    /// Privacy mode is always active in Phase 1 (no actual network monitoring).
    /// The toggle lets users acknowledge they understand local-only processing.
    private var privacyModeActive = true

    /// Reference to the privacy row for show/hide.
    private var privacyRow: NSStackView?

    /// Current language pair for display labels.
    private var currentLanguagePair: LanguagePair = LanguagePair(source: .en, target: .zh)

    /// Supported language pairs for the switcher popup.
    private var availablePairs: [LanguagePair] = SupportedLanguages.default.pairs

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        blurView = NSVisualEffectView()
        stackView = NSStackView()
        privacyIndicator = NSView()
        privacyDot = NSView()
        privacyLabel = NSTextField(labelWithString: "Privacy Mode: Active")
        privacyToggle = NSSwitch()
        audioLevelBar = NSProgressIndicator()
        audioLevelLabel = NSTextField(labelWithString: "🎤 Audio Level")
        preSessionLabel = NSTextField(labelWithString: "Point your mic at the speaker and speech will appear here.")
        scrollView = NSScrollView()
        segmentsStackView = NSStackView()
        sessionEndedLabel = NSTextField(labelWithString: "")
        exportAuditButton = NSButton(title: "📄 Export Audit Report", target: nil, action: nil)
        languageSwitcher = NSPopUpButton(frame: .zero, pullsDown: false)

        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        // Blur background
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 16
        blurView.layer?.masksToBounds = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Audio level indicator
        audioLevelBar.style = .bar
        audioLevelBar.minValue = 0
        audioLevelBar.maxValue = 1
        audioLevelBar.doubleValue = 0
        audioLevelBar.translatesAutoresizingMaskIntoConstraints = false

        audioLevelLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        audioLevelLabel.textColor = .secondaryLabelColor

        let audioStack = NSStackView(views: [audioLevelLabel, audioLevelBar])
        audioStack.orientation = .horizontal
        audioStack.spacing = 8
        audioStack.translatesAutoresizingMaskIntoConstraints = false

        // Pre-session label
        preSessionLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        preSessionLabel.textColor = .secondaryLabelColor
        preSessionLabel.alignment = .center
        preSessionLabel.translatesAutoresizingMaskIntoConstraints = false

        // Segments scroll view
        segmentsStackView.orientation = .vertical
        segmentsStackView.alignment = .leading
        segmentsStackView.spacing = 4
        segmentsStackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = segmentsStackView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Session ended label (hidden initially)
        sessionEndedLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        sessionEndedLabel.textColor = .secondaryLabelColor
        sessionEndedLabel.alignment = .center
        sessionEndedLabel.isHidden = true
        sessionEndedLabel.translatesAutoresizingMaskIntoConstraints = false

        // Export audit report button (hidden initially, shown when session ends)
        exportAuditButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        exportAuditButton.bezelStyle = .rounded
        exportAuditButton.isHidden = true
        exportAuditButton.translatesAutoresizingMaskIntoConstraints = false
        exportAuditButton.target = self
        exportAuditButton.action = #selector(exportAuditReport(_:))

        // Privacy indicator: dot + label + toggle
        privacyDot.wantsLayer = true
        privacyDot.layer?.cornerRadius = 5
        privacyDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        privacyDot.translatesAutoresizingMaskIntoConstraints = false

        privacyLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        privacyLabel.textColor = .secondaryLabelColor

        privacyToggle.controlSize = .small
        privacyToggle.state = .on
        privacyToggle.target = self
        privacyToggle.action = #selector(privacyToggleChanged(_:))

        privacyRow = NSStackView(views: [privacyDot, privacyLabel, privacyToggle])
        privacyRow!.orientation = .horizontal
        privacyRow!.spacing = 6
        privacyRow!.alignment = .centerY
        privacyRow!.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            privacyDot.widthAnchor.constraint(equalToConstant: 10),
            privacyDot.heightAnchor.constraint(equalToConstant: 10)
        ])

        // === Language Switcher ===
        // NSPopUpButton for selecting the active language pair.
        // Shown only during live sessions.
        languageSwitcher.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        languageSwitcher.controlSize = .small
        languageSwitcher.target = self
        languageSwitcher.action = #selector(languageSwitcherChanged(_:))
        populateLanguageSwitcher()

        let langLabel = NSTextField(labelWithString: "语言:")
        langLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        langLabel.textColor = .secondaryLabelColor

        let langRow = NSStackView(views: [langLabel, languageSwitcher])
        langRow.orientation = .horizontal
        langRow.spacing = 6
        langRow.alignment = .centerY
        langRow.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar row: language switcher on the left, privacy on the right
        toolbarRow = NSStackView(views: [langRow, privacyRow!])
        toolbarRow!.orientation = .horizontal
        toolbarRow!.spacing = 12
        toolbarRow!.alignment = .centerY
        toolbarRow!.distribution = .equalSpacing
        toolbarRow!.translatesAutoresizingMaskIntoConstraints = false

        // Main stack
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(toolbarRow!)
        stackView.addArrangedSubview(preSessionLabel)
        stackView.addArrangedSubview(audioStack)
        stackView.addArrangedSubview(scrollView)
        stackView.addArrangedSubview(sessionEndedLabel)
        stackView.addArrangedSubview(exportAuditButton)

        blurView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: blurView.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: blurView.bottomAnchor, constant: -16),

            audioStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, multiplier: 0.8),
            audioLevelBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])

        // Hide toolbar row initially (pre-session state), show during session
        toolbarRow?.isHidden = true

        // Hide scroll view initially (pre-session state)
        scrollView.isHidden = true

        // === Interpreter Panic Button (P3.3) ===
        // Red circular button positioned in the top-right corner.
        // Visible during live session; hidden in pre-session and ended states.
        panicButton = InterpreterPanicButton(frame: .zero)
        panicButton!.translatesAutoresizingMaskIntoConstraints = false
        panicButton!.isHidden = true
        addSubview(panicButton!)

        NSLayoutConstraint.activate([
            panicButton!.topAnchor.constraint(equalTo: blurView.topAnchor, constant: 4),
            panicButton!.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -4),
        ])
    }

    // MARK: - Public Interface

    /// Updates the audio level meter. Called from the audio capture thread.
    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.audioLevelBar.doubleValue = Double(level)
        }
    }

    /// Shows a partial segment: source text with placeholder.
    /// The target translation will be filled in later via finalizePartialSegment.
    func showPartialSegment(chunkIndex: Int, english: String, confidence: Float, speakerLabel: SpeakerLabel? = nil) {
        DispatchQueue.main.async {
            guard !self.sessionEnded else { return }
            self.showLiveSession()

            // Remove any existing segment with the same chunkIndex (shouldn't happen)
            if let existing = self.segmentViews[chunkIndex] {
                self.segmentsStackView.removeArrangedSubview(existing)
                existing.removeFromSuperview()
            }

            let segmentView = SegmentView(
                languagePair: self.currentLanguagePair,
                sourceText: english,
                targetText: "",        // Empty at first, filled in later
                confidence: confidence,
                isPlaceholder: true,   // pulsing animation enabled
                speakerLabel: speakerLabel
            )
            self.segmentViews[chunkIndex] = segmentView
            self.segmentsStackView.addArrangedSubview(segmentView)
            self.segments.append(BilingualSegment(english: english, mandarin: "", confidence: confidence, speakerLabel: speakerLabel))

            // Trim old segments
            while self.segmentsStackView.arrangedSubviews.count > self.maxSegments {
                if let first = self.segmentsStackView.arrangedSubviews.first {
                    if let idx = self.segmentViews.first(where: { $0.value === first })?.key {
                        self.segmentViews.removeValue(forKey: idx)
                    }
                    self.segmentsStackView.removeArrangedSubview(first)
                    first.removeFromSuperview()
                    self.segments.removeFirst()
                }
            }

            self.scrollToBottom()
        }
    }

    /// Fills in the target language translation for a previously shown partial segment.
    func finalizePartialSegment(chunkIndex: Int, mandarin: String) {
        DispatchQueue.main.async {
            guard let segmentView = self.segmentViews[chunkIndex] else { return }
            segmentView.setTargetText(mandarin)
            // Update the segments data
            if let idx = self.segments.firstIndex(where: { $0.english == segmentView.sourceText }) {
                self.segments[idx] = BilingualSegment(
                    english: self.segments[idx].english,
                    mandarin: mandarin,
                    confidence: self.segments[idx].confidence
                )
            }
        }
    }

    /// Fills in the target language translation with code-switching markup.
    /// Protected terms are highlighted in bold, mixed segments are visually distinguished.
    func finalizePartialSegment(
        chunkIndex: Int,
        mandarin: String,
        protectedTerms: [String],
        hasCodeSwitching: Bool
    ) {
        DispatchQueue.main.async {
            guard let segmentView = self.segmentViews[chunkIndex] else { return }
            segmentView.setTargetText(mandarin, protectedTerms: protectedTerms, isMixed: hasCodeSwitching)
            if let idx = self.segments.firstIndex(where: { $0.english == segmentView.sourceText }) {
                self.segments[idx] = BilingualSegment(
                    english: self.segments[idx].english,
                    mandarin: mandarin,
                    confidence: self.segments[idx].confidence
                )
            }
        }
    }

    /// Appends a fully-resolved bilingual segment (both source and target known).
    func appendSegment(english: String, mandarin: String, confidence: Float, speakerLabel: SpeakerLabel? = nil) {
        DispatchQueue.main.async {
            guard !self.sessionEnded else { return }
            self.showLiveSession()

            // Use a unique chunkIndex based on current count
            let chunkIndex = self.segments.count

            // Remove any existing partial for this index
            if let existing = self.segmentViews[chunkIndex] {
                self.segmentsStackView.removeArrangedSubview(existing)
                existing.removeFromSuperview()
                self.segmentViews.removeValue(forKey: chunkIndex)
            }

            let segmentView = SegmentView(
                languagePair: self.currentLanguagePair,
                sourceText: english,
                targetText: mandarin,
                confidence: confidence,
                isPlaceholder: false,
                speakerLabel: speakerLabel
            )
            self.segmentViews[chunkIndex] = segmentView
            self.segmentsStackView.addArrangedSubview(segmentView)
            self.segments.append(BilingualSegment(english: english, mandarin: mandarin, confidence: confidence, speakerLabel: speakerLabel))

            // Trim old segments
            while self.segments.count > self.maxSegments {
                if let first = self.segmentsStackView.arrangedSubviews.first {
                    if let idx = self.segmentViews.first(where: { $0.value === first })?.key {
                        self.segmentViews.removeValue(forKey: idx)
                    }
                    self.segmentsStackView.removeArrangedSubview(first)
                    first.removeFromSuperview()
                    self.segments.removeFirst()
                }
            }

            self.scrollToBottom()
        }
    }

    /// Ends the session: shows "Session ended" message, freezes final segment.
    func endSession() {
        DispatchQueue.main.async {
            self.sessionEnded = true
            self.sessionEndTimer?.invalidate()
            self.sessionEndTimer = nil
            self.scrollView.isHidden = true
            self.toolbarRow?.isHidden = true
            self.panicButton?.isHidden = true  // Hide panic button when session ends
            self.sessionEndedLabel.stringValue = "Session ended"
            self.sessionEndedLabel.isHidden = false
            self.exportAuditButton.isHidden = false

            // Auto-clear after 10 seconds
            self.sessionEndTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                self?.clearSessionEnded()
            }
        }
    }

    /// Clears the session-ended state and resets to pre-session.
    func clearSessionEnded() {
        DispatchQueue.main.async {
            self.sessionEnded = false
            self.sessionEndTimer?.invalidate()
            self.sessionEndTimer = nil
            self.sessionEndedLabel.isHidden = true
            self.sessionEndedLabel.stringValue = ""
            self.exportAuditButton.isHidden = true

            // Remove all segments
            for (_, view) in self.segmentViews {
                self.segmentsStackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            self.segmentViews.removeAll()
            self.segments.removeAll()

            // Reset privacy toggle to ON (active) for fresh session
            self.privacyModeActive = true
            self.privacyToggle.state = .on
            self.updatePrivacyIndicator()

            // Return to pre-session state
            self.preSessionLabel.isHidden = false
            self.scrollView.isHidden = true
            self.toolbarRow?.isHidden = true
            self.panicButton?.isHidden = true  // Reset panic button
        }
    }

    // MARK: - State Transitions

    private func showLiveSession() {
        preSessionLabel.isHidden = true
        scrollView.isHidden = false
        toolbarRow?.isHidden = false
        panicButton?.isHidden = false  // Show interpreter panic button during session
    }

    // MARK: - Privacy Toggle

    @objc private func privacyToggleChanged(_ sender: NSSwitch) {
        privacyModeActive = (sender.state == .on)
        updatePrivacyIndicator()
    }

    /// Export audit report button action.
    @objc private func exportAuditReport(_ sender: NSButton) {
        onExportAuditReport?()
    }

    private func updatePrivacyIndicator() {
        if privacyModeActive {
            privacyDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            privacyLabel.stringValue = "Privacy Mode: Active"
            privacyLabel.textColor = .secondaryLabelColor
        } else {
            privacyDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            privacyLabel.stringValue = "Privacy Mode: Off"
            privacyLabel.textColor = .tertiaryLabelColor
        }
    }

    // MARK: - Language Switcher

    /// Populates the language switcher popup with available language pairs.
    private func populateLanguageSwitcher() {
        languageSwitcher.removeAllItems()
        for (index, pair) in availablePairs.enumerated() {
            languageSwitcher.addItem(withTitle: pair.displayLabel)
            languageSwitcher.item(at: index)?.tag = index
        }
        // Select default
        languageSwitcher.selectItem(at: SupportedLanguages.default.defaultPairIndex)
        currentLanguagePair = availablePairs[SupportedLanguages.default.defaultPairIndex]
    }

    /// Called when the user selects a new language pair from the switcher.
    @objc private func languageSwitcherChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < availablePairs.count else { return }
        let newPair = availablePairs[index]
        guard newPair != currentLanguagePair else { return }
        currentLanguagePair = newPair
        onLanguagePairChanged?(newPair)
    }

    /// Updates the available language pairs and refreshes the switcher.
    /// - Parameter pairs: New list of language pairs to display.
    func updateLanguagePairs(_ pairs: [LanguagePair]) {
        availablePairs = pairs
        populateLanguageSwitcher()
    }

    /// Returns the currently selected language pair.
    func getCurrentLanguagePair() -> LanguagePair {
        currentLanguagePair
    }

    private func scrollToBottom() {
        if let docView = self.scrollView.documentView {
            let scrollHeight = docView.frame.height
            docView.scroll(to: NSPoint(x: 0, y: scrollHeight))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }
}

// MARK: - SegmentView

/// Renders a single bilingual segment: language tag + source text, language tag + target text.
/// Supports placeholder mode with pulsing animation.
/// Dynamic language labels: EN, 中, 日, 한 based on the active language pair.
class SegmentView: NSView {

    private let sourceLabel: NSTextField
    private let targetLabel: NSTextField
    private let confidenceIndicator: NSView
    private let speakerTagView: NSTextField?
    private var pulseTimer: Timer?

    /// The source text of this segment (stored for update matching).
    private(set) var sourceText: String = ""

    /// Language pair used for display labels and colors.
    private let languagePair: LanguagePair

    init(
        languagePair: LanguagePair,
        sourceText: String,
        targetText: String,
        confidence: Float,
        isPlaceholder: Bool = false,
        speakerLabel: SpeakerLabel? = nil
    ) {
        self.languagePair = languagePair
        self.sourceLabel = NSTextField(labelWithString: "")
        self.targetLabel = NSTextField(labelWithString: "")
        self.confidenceIndicator = NSView()

        // Create speaker tag label if a speaker label is provided
        if let label = speakerLabel {
            let speakerTag = NSTextField(labelWithString: "")
            speakerTag.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            speakerTag.textColor = NSColor(
                calibratedRed: label.color.redComponent,
                green: label.color.greenComponent,
                blue: label.color.blueComponent,
                alpha: 1.0
            )
            speakerTag.stringValue = "\(label.color.emoji) \(label.displayName)"
            speakerTag.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            speakerTagView = speakerTag
        } else {
            speakerTagView = nil
        }

        super.init(frame: .zero)

        setupView(sourceText: sourceText, targetText: targetText, confidence: confidence, isPlaceholder: isPlaceholder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the target label text with the final translation.
    func setTargetText(_ target: String) {
        setTargetText(target, protectedTerms: [], isMixed: false)
    }

    /// Replaces the target label text with code-switching markup.
    /// - Parameters:
    ///   - target: The translated text.
    ///   - protectedTerms: Terms that should be highlighted in bold/special color.
    ///   - isMixed: Whether this segment contains code-switching (visual distinction).
    func setTargetText(_ target: String, protectedTerms: [String], isMixed: Bool) {
        pulseTimer?.invalidate()
        pulseTimer = nil

        if protectedTerms.isEmpty && !isMixed {
            // Simple case: no markup needed
            targetLabel.stringValue = target
            targetLabel.textColor = .white
        } else if let attributed = Self.attributedString(
            text: target,
            protectedTerms: protectedTerms,
            isMixed: isMixed
        ) {
            targetLabel.attributedStringValue = attributed
            targetLabel.textColor = .white  // Fallback; attributed string sets per-range color
        } else {
            targetLabel.stringValue = target
            targetLabel.textColor = isMixed
                ? NSColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)  // Light blue for mixed
                : .white
        }
    }

    // MARK: - Attributed String Builder

    /// Builds an attributed string with protected terms highlighted.
    /// - Parameters:
    ///   - text: The full text.
    ///   - protectedTerms: Terms to highlight in bold yellow.
    ///   - isMixed: Whether the whole segment is a code-switched mix.
    /// - Returns: An NSAttributedString with per-term styling, or nil on failure.
    private static func attributedString(
        text: String,
        protectedTerms: [String],
        isMixed: Bool
    ) -> NSAttributedString? {
        let baseColor: NSColor = isMixed
            ? NSColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)  // Light blue for mixed segments
            : .white

        let termColor = NSColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1.0)  // Gold/yellow for terms
        let termFont = NSFont.systemFont(ofSize: 14, weight: .bold)
        let baseFont = NSFont.systemFont(ofSize: 14, weight: .regular)

        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: baseColor
            ]
        )

        // Mark each protected term with bold + special color
        let nsString = text as NSString
        for term in protectedTerms {
            let range = nsString.range(of: term, options: .caseInsensitive)
            if range.location != NSNotFound {
                result.addAttributes(
                    [.font: termFont, .foregroundColor: termColor],
                    range: range
                )
            }
        }

        return result
    }

    private func setupView(sourceText: String, targetText: String, confidence: Float, isPlaceholder: Bool) {
        self.sourceText = sourceText

        // Source language line: e.g. "EN  <text>" or "中  <text>"
        let sourceLangTag = NSTextField(labelWithString: languagePair.source.shortLabel + " ")
        sourceLangTag.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        sourceLangTag.textColor = languageColor(for: languagePair.source)

        sourceLabel.stringValue = sourceText
        sourceLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        sourceLabel.textColor = .white
        sourceLabel.lineBreakMode = .byWordWrapping
        sourceLabel.maximumNumberOfLines = 2
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sourceRow = NSStackView(views: [sourceLangTag, sourceLabel])
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .firstBaseline
        sourceRow.spacing = 6

        // Target language line: e.g. "中  <text>" or "日  <text>" or "한  <text>"
        let targetLangTag = NSTextField(labelWithString: languagePair.target.shortLabel + " ")
        targetLangTag.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        targetLangTag.textColor = languageColor(for: languagePair.target)

        let placeholder = isPlaceholder ? Self.translatingPlaceholder(for: languagePair.target) : targetText
        targetLabel.stringValue = placeholder
        targetLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        targetLabel.textColor = isPlaceholder ? NSColor.secondaryLabelColor : .white
        targetLabel.lineBreakMode = .byWordWrapping
        targetLabel.maximumNumberOfLines = 2
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let targetRow = NSStackView(views: [targetLangTag, targetLabel])
        targetRow.orientation = .horizontal
        targetRow.alignment = .firstBaseline
        targetRow.spacing = 6

        // Confidence indicator dot
        let dotSize: CGFloat = 6
        confidenceIndicator.wantsLayer = true
        confidenceIndicator.layer?.cornerRadius = dotSize / 2
        confidenceIndicator.translatesAutoresizingMaskIntoConstraints = false

        if confidence >= 0.8 {
            confidenceIndicator.layer?.backgroundColor = NSColor.systemGreen.cgColor
        } else if confidence >= 0.6 {
            confidenceIndicator.layer?.backgroundColor = NSColor.systemOrange.cgColor
        } else {
            confidenceIndicator.layer?.backgroundColor = NSColor.systemRed.cgColor
        }

        NSLayoutConstraint.activate([
            confidenceIndicator.widthAnchor.constraint(equalToConstant: dotSize),
            confidenceIndicator.heightAnchor.constraint(equalToConstant: dotSize)
        ])

        // Build the main content stack (text rows + confidence dot)
        let textStack = NSStackView(orientation: .vertical)
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.addArrangedSubview(sourceRow)
        textStack.addArrangedSubview(targetRow)

        let mainStack: NSStackView
        if let speakerTag = speakerTagView {
            // Layout: [SpeakerTag] [TextStack | ConfidenceDot]
            let contentWithConf = NSStackView(views: [textStack, confidenceIndicator])
            contentWithConf.orientation = .horizontal
            contentWithConf.alignment = .firstBaseline
            contentWithConf.spacing = 8

            mainStack = NSStackView(views: [speakerTag, contentWithConf])
            mainStack.orientation = .horizontal
            mainStack.alignment = .firstBaseline
            mainStack.spacing = 8
        } else {
            // Original layout without speaker tag
            mainStack = NSStackView(views: [textStack, confidenceIndicator])
            mainStack.orientation = .horizontal
            mainStack.alignment = .firstBaseline
            mainStack.spacing = 8
        }

        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])

        // Pulse animation for placeholder target language
        if isPlaceholder {
            var phase: CGFloat = 0
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                phase += 1
                let dots = phase.truncatingRemainder(dividingBy: 4)
                let text = Self.translatingPlaceholder(for: self.languagePair.target) + String(repeating: ".", count: Int(dots))
                self.targetLabel.stringValue = text
            }
        }
    }

    // MARK: - Language Helpers

    /// Returns the color associated with a language for display in segment labels.
    private func languageColor(for lang: LanguageCode) -> NSColor {
        switch lang {
        case .en:
            return NSColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)  // Light blue
        case .zh:
            return NSColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1.0)   // Orange
        case .ja:
            return NSColor(red: 0.85, green: 0.3, blue: 0.7, alpha: 1.0)  // Pink/magenta
        case .ko:
            return NSColor(red: 0.3, green: 0.7, blue: 0.6, alpha: 1.0)   // Teal
        case .ext:
            return NSColor.systemGray
        }
    }

    /// Returns the "translating..." placeholder text for the given target language.
    private static func translatingPlaceholder(for lang: LanguageCode) -> String {
        switch lang {
        case .en:  return "Translating"
        case .zh:  return "翻译中"
        case .ja:  return "翻訳中"
        case .ko:  return "번역 중"
        case .ext: return "..."
        }
    }

    deinit {
        pulseTimer?.invalidate()
    }
}
