import AppKit
import Combine

// MARK: - InterpreterPanicButton

/// A red circular "Panic Button" for requesting human interpreter fallback.
/// Designed to be prominent but non-intrusive during normal use.
///
/// States:
/// 1. Idle: Small red pulsing circle with "求助人工翻译" tooltip
/// 2. Searching: Animated search indicator
/// 3. Connecting: Progress indicator
/// 4. In Call: Timer display with hang-up button
/// 5. Ended: Cost summary card with dismiss button
class InterpreterPanicButton: NSView {

    // MARK: - Configuration

    private let idleButtonSize: CGFloat = 52
    private let expandedWidth: CGFloat = 280
    private let expandedHeight: CGFloat = 200

    // MARK: - UI Components

    private let idleButton: NSButton
    private let idleLabel: NSTextField
    private let statusContainer: NSView
    private let statusIcon: NSView
    private let statusLabel: NSTextField
    private let timerLabel: NSTextField
    private let cancelButton: NSButton
    private let hangupButton: NSButton
    private let summaryContainer: NSView
    private let summaryTitle: NSTextField
    private let summaryDetail: NSTextField
    private let dismissButton: NSButton

    // MARK: - State

    private var state: InterpreterSessionState = .idle
    private var cancellables = Set<AnyCancellable>()
    private var pulseTimer: Timer?
    private var isExpanded = false

    // MARK: - Callbacks

    /// Called when the user taps the panic button (idle → search).
    var onRequestInterpreter: (() -> Void)?

    /// Called when the user cancels the search.
    var onCancelSearch: (() -> Void)?

    /// Called when the user ends the call.
    var onEndCall: (() -> Void)?

    /// Called when the user dismisses the summary.
    var onDismissSummary: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        idleButton = NSButton()
        idleLabel = NSTextField(labelWithString: "")
        statusContainer = NSView()
        statusIcon = NSView()
        statusLabel = NSTextField(labelWithString: "")
        timerLabel = NSTextField(labelWithString: "")
        cancelButton = NSButton()
        hangupButton = NSButton()
        summaryContainer = NSView()
        summaryTitle = NSTextField(labelWithString: "")
        summaryDetail = NSTextField(labelWithString: "")
        dismissButton = NSButton()

        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 16

        // === Idle Button ===
        idleButton.wantsLayer = true
        idleButton.layer?.cornerRadius = idleButtonSize / 2
        idleButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        idleButton.layer?.shadowColor = NSColor.black.withAlphaComponent(0.3).cgColor
        idleButton.layer?.shadowOffset = NSSize(width: 0, height: 2)
        idleButton.layer?.shadowRadius = 6
        idleButton.layer?.shadowOpacity = 1
        idleButton.isBordered = false
        idleButton.toolTip = "求助人工翻译"
        idleButton.translatesAutoresizingMaskIntoConstraints = false
        idleButton.target = self
        idleButton.action = #selector(idleButtonTapped)
        addSubview(idleButton)

        // SOS icon inside the button
        let sosLabel = NSTextField(labelWithString: "🆘")
        sosLabel.font = NSFont.systemFont(ofSize: 20)
        sosLabel.textColor = .white
        sosLabel.drawsBackground = false
        sosLabel.isBezeled = false
        sosLabel.alignment = .center
        sosLabel.translatesAutoresizingMaskIntoConstraints = false
        idleButton.addSubview(sosLabel)

        // Idle label below the button
        idleLabel.stringValue = "求助人工翻译"
        idleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        idleLabel.textColor = .white
        idleLabel.drawsBackground = false
        idleLabel.isBezeled = false
        idleLabel.alignment = .center
        idleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(idleLabel)

        // === Status Container (searching / connecting / in-call) ===
        statusContainer.wantsLayer = true
        statusContainer.layer?.cornerRadius = 12
        statusContainer.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        statusContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        statusContainer.layer?.borderWidth = 0.5
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.isHidden = true
        addSubview(statusContainer)

        // Status icon (colored circle)
        statusIcon.wantsLayer = true
        statusIcon.layer?.cornerRadius = 6
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusIcon)

        // Status label
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.drawsBackground = false
        statusLabel.isBezeled = false
        statusLabel.alignment = .left
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusLabel)

        // Timer label (in-call)
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        timerLabel.textColor = .systemRed
        timerLabel.drawsBackground = false
        timerLabel.isBezeled = false
        timerLabel.alignment = .center
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.isHidden = true
        statusContainer.addSubview(timerLabel)

        // Interpreter name label
        let interpreterNameLabel = NSTextField(labelWithString: "")
        interpreterNameLabel.tag = 100  // tag for later access
        interpreterNameLabel.font = NSFont.systemFont(ofSize: 11)
        interpreterNameLabel.textColor = .secondaryLabelColor
        interpreterNameLabel.drawsBackground = false
        interpreterNameLabel.isBezeled = false
        interpreterNameLabel.alignment = .center
        interpreterNameLabel.translatesAutoresizingMaskIntoConstraints = false
        interpreterNameLabel.isHidden = true
        statusContainer.addSubview(interpreterNameLabel)

        // Cancel button (searching state)
        cancelButton.title = "取消"
        cancelButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = 8
        cancelButton.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isHidden = true
        statusContainer.addSubview(cancelButton)

        // Hangup button (in-call state)
        hangupButton.title = "结束通话"
        hangupButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        hangupButton.isBordered = false
        hangupButton.wantsLayer = true
        hangupButton.layer?.cornerRadius = 10
        hangupButton.layer?.backgroundColor = NSColor.systemRed.cgColor
        hangupButton.target = self
        hangupButton.action = #selector(hangupTapped)
        hangupButton.translatesAutoresizingMaskIntoConstraints = false
        hangupButton.isHidden = true
        statusContainer.addSubview(hangupButton)

        // === Summary Container ===
        summaryContainer.wantsLayer = true
        summaryContainer.layer?.cornerRadius = 12
        summaryContainer.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        summaryContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        summaryContainer.layer?.borderWidth = 0.5
        summaryContainer.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.isHidden = true
        addSubview(summaryContainer)

        summaryTitle.stringValue = "通话结束"
        summaryTitle.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        summaryTitle.textColor = .white
        summaryTitle.drawsBackground = false
        summaryTitle.isBezeled = false
        summaryTitle.alignment = .center
        summaryTitle.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(summaryTitle)

        summaryDetail.font = NSFont.systemFont(ofSize: 12)
        summaryDetail.textColor = .secondaryLabelColor
        summaryDetail.drawsBackground = false
        summaryDetail.isBezeled = false
        summaryDetail.alignment = .center
        summaryDetail.lineBreakMode = .byWordWrapping
        summaryDetail.maximumNumberOfLines = 8
        summaryDetail.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(summaryDetail)

        dismissButton.title = "确认"
        dismissButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        dismissButton.isBordered = false
        dismissButton.wantsLayer = true
        dismissButton.layer?.cornerRadius = 10
        dismissButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        summaryContainer.addSubview(dismissButton)

        // Layout constraints
        setupLayout()
    }

    private func setupLayout() {
        // Idle button: fixed size in top-right corner of this view
        NSLayoutConstraint.activate([
            idleButton.widthAnchor.constraint(equalToConstant: idleButtonSize),
            idleButton.heightAnchor.constraint(equalToConstant: idleButtonSize),
            idleButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            idleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            sosLabel.centerXAnchor.constraint(equalTo: idleButton.centerXAnchor),
            sosLabel.centerYAnchor.constraint(equalTo: idleButton.centerYAnchor),

            idleLabel.topAnchor.constraint(equalTo: idleButton.bottomAnchor, constant: 4),
            idleLabel.centerXAnchor.constraint(equalTo: idleButton.centerXAnchor),
        ])

        // Status container: expand to fill when active
        NSLayoutConstraint.activate([
            statusContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            statusContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            statusContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            statusIcon.widthAnchor.constraint(equalToConstant: 12),
            statusIcon.heightAnchor.constraint(equalToConstant: 12),
            statusIcon.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 12),
            statusIcon.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 16),

            statusLabel.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -16),

            timerLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            timerLabel.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 16),
            timerLabel.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -16),

            // Interpreter name label (tag 100)
            statusContainer.subviews.first(where: { $0.tag == 100 })?.topAnchor.constraint(equalTo: timerLabel.bottomAnchor, constant: 2),
            statusContainer.subviews.first(where: { $0.tag == 100 })?.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),

            cancelButton.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -12),
            cancelButton.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 16),
            cancelButton.widthAnchor.constraint(equalToConstant: 60),
            cancelButton.heightAnchor.constraint(equalToConstant: 28),

            hangupButton.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -12),
            hangupButton.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
            hangupButton.widthAnchor.constraint(equalToConstant: 100),
            hangupButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        // Interpreter name label
        if let nameTag = statusContainer.subviews.first(where: { $0.tag == 100 }) {
            NSLayoutConstraint.activate([
                nameTag.topAnchor.constraint(equalTo: timerLabel.bottomAnchor, constant: 2),
                nameTag.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
            ])
        }

        // Summary container
        NSLayoutConstraint.activate([
            summaryContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            summaryContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            summaryContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            summaryContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            summaryTitle.topAnchor.constraint(equalTo: summaryContainer.topAnchor, constant: 12),
            summaryTitle.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),

            summaryDetail.topAnchor.constraint(equalTo: summaryTitle.bottomAnchor, constant: 8),
            summaryDetail.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 16),
            summaryDetail.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor, constant: -16),

            dismissButton.bottomAnchor.constraint(equalTo: summaryContainer.bottomAnchor, constant: -12),
            dismissButton.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 80),
            dismissButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        // Initial size: just the button + label
        updateIntrinsicSize()
    }

    // MARK: - Public Interface

    /// Bind to an InterpreterService to automatically track state changes.
    func bind(to service: InterpreterService) {
        service.$sessionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.updateState(newState)
            }
            .store(in: &cancellables)
    }

    /// Update the displayed state.
    func updateState(_ newState: InterpreterSessionState) {
        DispatchQueue.main.async {
            self.state = newState
            self.applyState(newState)
        }
    }

    /// Update the call timer display.
    func updateTimer(_ duration: String) {
        DispatchQueue.main.async {
            if case .inCall = self.state {
                self.timerLabel.stringValue = duration
            }
        }
    }

    // MARK: - State Application

    private func applyState(_ newState: InterpreterSessionState) {
        switch newState {
        case .idle:
            showIdle()
        case .searching:
            showSearching()
        case .connecting:
            showConnecting()
        case .inCall:
            showInCall()
        case .ended(let summary):
            showSummary(summary)
        }
    }

    private func showIdle() {
        stopPulse()
        isExpanded = false
        updateIntrinsicSize()

        idleButton.isHidden = false
        idleLabel.isHidden = false
        statusContainer.isHidden = true
        summaryContainer.isHidden = true
        startPulse()
    }

    private func showSearching() {
        stopPulse()
        expand()

        idleButton.isHidden = true
        idleLabel.isHidden = true
        statusContainer.isHidden = false
        summaryContainer.isHidden = true

        statusIcon.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusLabel.stringValue = "正在搜索翻译员..."
        statusLabel.textColor = .systemOrange

        timerLabel.isHidden = true
        if let nameLabel = statusContainer.subviews.first(where: { $0.tag == 100 }) {
            nameLabel.isHidden = true
        }
        cancelButton.isHidden = false
        hangupButton.isHidden = true
    }

    private func showConnecting() {
        expand()

        idleButton.isHidden = true
        idleLabel.isHidden = true
        statusContainer.isHidden = false
        summaryContainer.isHidden = true

        statusIcon.layer?.backgroundColor = NSColor.systemYellow.cgColor
        statusLabel.stringValue = "翻译员已接单，正在建立连接..."
        statusLabel.textColor = .systemYellow

        timerLabel.isHidden = true
        cancelButton.isHidden = false
        hangupButton.isHidden = true
    }

    private func showInCall() {
        expand()

        idleButton.isHidden = true
        idleLabel.isHidden = true
        statusContainer.isHidden = false
        summaryContainer.isHidden = true

        statusIcon.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusLabel.stringValue = "已连接 · 通话中"
        statusLabel.textColor = .systemGreen

        timerLabel.isHidden = false
        timerLabel.stringValue = "0:00"

        cancelButton.isHidden = true
        hangupButton.isHidden = false
    }

    private func showSummary(_ summary: InterpreterSessionSummary) {
        expand()

        idleButton.isHidden = true
        idleLabel.isHidden = true
        statusContainer.isHidden = true
        summaryContainer.isHidden = false

        summaryTitle.stringValue = "通话结束"
        summaryDetail.stringValue = """
        翻译员: \(summary.interpreterName)
        通话时长: \(summary.formattedDuration)
        费用: \(summary.formattedCost)

        💡 试点期间通话免费，感谢使用！
        """
    }

    // MARK: - Animations

    private func startPulse() {
        pulseTimer?.invalidate()
        var phase: Float = 0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.05
            let scale = 1.0 + 0.05 * sin(phase * 2)
            let alpha: Float = 0.85 + 0.15 * sin(phase * 2)
            self.idleButton.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
            self.idleButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(CGFloat(alpha)).cgColor
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        idleButton.layer?.transform = CATransform3DIdentity
        idleButton.layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    private func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        updateIntrinsicSize()
    }

    private func updateIntrinsicSize() {
        if isExpanded {
            frame.size = CGSize(width: expandedWidth, height: expandedHeight)
        } else {
            frame.size = CGSize(width: idleButtonSize + 16, height: idleButtonSize + 30)
        }
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    // MARK: - Actions

    @objc private func idleButtonTapped() {
        onRequestInterpreter?()
    }

    @objc private func cancelTapped() {
        onCancelSearch?()
    }

    @objc private func hangupTapped() {
        onEndCall?()
    }

    @objc private func dismissTapped() {
        onDismissSummary?()
    }

    override var intrinsicContentSize: NSSize {
        if isExpanded {
            return NSSize(width: expandedWidth, height: expandedHeight)
        }
        return NSSize(width: idleButtonSize + 16, height: idleButtonSize + 30)
    }
}

// MARK: - Pulse Access Helpers

extension InterpreterPanicButton {
    /// Expose pulse start for OverlayView integration.
    func startPulse_private() {
        var phase: Float = 0
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.05
            let scale = 1.0 + 0.05 * sin(phase * 2)
            let alpha: Float = 0.85 + 0.15 * sin(phase * 2)
            self.idleButton.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
            self.idleButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(CGFloat(alpha)).cgColor
        }
    }

    /// Expose pulse stop for OverlayView integration.
    func stopPulse_private() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        idleButton.layer?.transform = CATransform3DIdentity
        idleButton.layer?.backgroundColor = NSColor.systemRed.cgColor
    }
}
