import AppKit

/// The main view rendered inside the overlay window.
/// Displays pre-session prompt, audio level bar, and bilingual transcription segments.
class OverlayView: NSView {

    // MARK: - UI Components

    private let blurView: NSVisualEffectView
    private let stackView: NSStackView
    private let audioLevelBar: NSProgressIndicator
    private let audioLevelLabel: NSTextField
    private let preSessionLabel: NSTextField
    private let scrollView: NSScrollView
    private let segmentsStackView: NSStackView

    /// Shown when session ends.
    private let sessionEndedLabel: NSTextField

    // MARK: - State

    private var segments: [BilingualSegment] = []
    private let maxSegments = 50

    /// Active segment views keyed by chunk index for partial updates.
    private var segmentViews: [Int: SegmentView] = [:]

    /// Whether session has ended.
    private var sessionEnded = false

    /// Timer for auto-clearing session-ended state.
    private var sessionEndTimer: Timer?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        blurView = NSVisualEffectView()
        stackView = NSStackView()
        audioLevelBar = NSProgressIndicator()
        audioLevelLabel = NSTextField(labelWithString: "🎤 Audio Level")
        preSessionLabel = NSTextField(labelWithString: "Point your mic at the speaker and speech will appear here.")
        scrollView = NSScrollView()
        segmentsStackView = NSStackView()
        sessionEndedLabel = NSTextField(labelWithString: "")

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

        // Main stack
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(preSessionLabel)
        stackView.addArrangedSubview(audioStack)
        stackView.addArrangedSubview(scrollView)
        stackView.addArrangedSubview(sessionEndedLabel)

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

        // Hide scroll view initially (pre-session state)
        scrollView.isHidden = true
    }

    // MARK: - Public Interface

    /// Updates the audio level meter. Called from the audio capture thread.
    func updateAudioLevel(_ level: Float) {
        DispatchQueue.main.async {
            self.audioLevelBar.doubleValue = Double(level)
        }
    }

    /// Shows a partial segment: English text with "翻译中..." placeholder.
    /// The Mandarin will be filled in later via finalizePartialSegment.
    func showPartialSegment(chunkIndex: Int, english: String, confidence: Float) {
        DispatchQueue.main.async {
            guard !self.sessionEnded else { return }
            self.showLiveSession()

            // Remove any existing segment with the same chunkIndex (shouldn't happen)
            if let existing = self.segmentViews[chunkIndex] {
                self.segmentsStackView.removeArrangedSubview(existing)
                existing.removeFromSuperview()
            }

            let segmentView = SegmentView(
                english: english,
                mandarin: "翻译中...",   // "Translating..." in Chinese
                confidence: confidence,
                isPlaceholder: true   // pulsing animation enabled
            )
            self.segmentViews[chunkIndex] = segmentView
            self.segmentsStackView.addArrangedSubview(segmentView)
            self.segments.append(BilingualSegment(english: english, mandarin: "", confidence: confidence))

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

    /// Fills in the Mandarin translation for a previously shown partial segment.
    func finalizePartialSegment(chunkIndex: Int, mandarin: String) {
        DispatchQueue.main.async {
            guard let segmentView = self.segmentViews[chunkIndex] else { return }
            segmentView.setMandarin(mandarin)
            // Update the segments data
            if let idx = self.segments.firstIndex(where: { $0.english == segmentView.englishText }) {
                self.segments[idx] = BilingualSegment(
                    english: self.segments[idx].english,
                    mandarin: mandarin,
                    confidence: self.segments[idx].confidence
                )
            }
        }
    }

    /// Appends a fully-resolved bilingual segment (both EN and ZH known).
    func appendSegment(english: String, mandarin: String, confidence: Float) {
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

            let segmentView = SegmentView(english: english, mandarin: mandarin, confidence: confidence, isPlaceholder: false)
            self.segmentViews[chunkIndex] = segmentView
            self.segmentsStackView.addArrangedSubview(segmentView)
            self.segments.append(BilingualSegment(english: english, mandarin: mandarin, confidence: confidence))

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
            self.scrollView.isHidden = true
            self.sessionEndedLabel.stringValue = "Session ended"
            self.sessionEndedLabel.isHidden = false

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

            // Remove all segments
            for (_, view) in self.segmentViews {
                self.segmentsStackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            self.segmentViews.removeAll()
            self.segments.removeAll()

            // Return to pre-session state
            self.preSessionLabel.isHidden = false
            self.scrollView.isHidden = true
        }
    }

    // MARK: - State Transitions

    private func showLiveSession() {
        preSessionLabel.isHidden = true
        scrollView.isHidden = false
    }

    private func scrollToBottom() {
        if let docView = self.scrollView.documentView {
            let scrollHeight = docView.frame.height
            docView.scroll(to: NSPoint(x: 0, y: scrollHeight))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }
}

// MARK: - BilingualSegment

struct BilingualSegment {
    let english: String
    let mandarin: String
    let confidence: Float
}

// MARK: - SegmentView

/// Renders a single bilingual segment: two lines, English above Mandarin.
/// Supports placeholder mode (Mandarin "翻译中..." with pulse animation).
class SegmentView: NSView {

    private let englishLabel: NSTextField
    private let mandarinLabel: NSTextField
    private let confidenceIndicator: NSView
    private var pulseTimer: Timer?

    /// The English text of this segment (stored for update matching).
    private(set) var englishText: String = ""

    init(english: String, mandarin: String, confidence: Float, isPlaceholder: Bool = false) {
        englishLabel = NSTextField(labelWithString: "")
        mandarinLabel = NSTextField(labelWithString: "")
        confidenceIndicator = NSView()

        super.init(frame: .zero)

        setupView(english: english, mandarin: mandarin, confidence: confidence, isPlaceholder: isPlaceholder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the Mandarin label text with the final translation.
    func setMandarin(_ mandarin: String) {
        pulseTimer?.invalidate()
        pulseTimer = nil
        mandarinLabel.stringValue = mandarin
        mandarinLabel.textColor = .white
    }

    private func setupView(english: String, mandarin: String, confidence: Float, isPlaceholder: Bool) {
        englishText = english

        // English line: "EN  <text>"
        let enTag = NSTextField(labelWithString: "EN ")
        enTag.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        enTag.textColor = NSColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0) // Light blue

        englishLabel.stringValue = english
        englishLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        englishLabel.textColor = .white
        englishLabel.lineBreakMode = .byWordWrapping
        englishLabel.maximumNumberOfLines = 2
        englishLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let enRow = NSStackView(views: [enTag, englishLabel])
        enRow.orientation = .horizontal
        enRow.alignment = .firstBaseline
        enRow.spacing = 6

        // Mandarin line: "中  <text>"
        let zhTag = NSTextField(labelWithString: "中 ")
        zhTag.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        zhTag.textColor = NSColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1.0) // Orange

        mandarinLabel.stringValue = mandarin
        mandarinLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        mandarinLabel.textColor = isPlaceholder ? NSColor.secondaryLabelColor : .white
        mandarinLabel.lineBreakMode = .byWordWrapping
        mandarinLabel.maximumNumberOfLines = 2
        mandarinLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let zhRow = NSStackView(views: [zhTag, mandarinLabel])
        zhRow.orientation = .horizontal
        zhRow.alignment = .firstBaseline
        zhRow.spacing = 6

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

        let mainStack = NSStackView(views: [enRow, zhRow, confidenceIndicator])
        mainStack.orientation = .horizontal
        mainStack.alignment = .firstBaseline
        mainStack.spacing = 8
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])

        // Pulse animation for placeholder Mandarin
        if isPlaceholder {
            var phase: CGFloat = 0
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                phase += 1
                let dots = phase.truncatingRemainder(dividingBy: 4)
                let text = "翻译中" + String(repeating: ".", count: Int(dots))
                self.mandarinLabel.stringValue = text
            }
        }
    }

    deinit {
        pulseTimer?.invalidate()
    }
}
