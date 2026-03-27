import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var audioCaptureService: AudioCaptureService?
    private var overlayWindow: NSWindow?
    private var interpreterPipeline: InterpreterPipeline?
    private var pipelineBridge: InterpreterPipelineBridge?

    // Privacy audit (P3.1)
    private var networkMonitor: NetworkMonitor?
    private var attestationService: AttestationService?
    private var currentSessionId: String?

    // Human interpreter fallback (P3.3)
    private var interpreterService: InterpreterService?
    private var interpreterTimer: Timer?
    private var currentSessionStartTime: Date?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarItem()
        setupOverlayWindow()
        setupInterpreterFallback()  // P3.3: Wire up panic button
        setupAttestationService()
        requestMicrophonePermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioCaptureService?.stopCapture()
        pipelineBridge?.stop()
        interpreterPipeline?.stop()
        interpreterService?.endSession()
        interpreterTimer?.invalidate()
        networkMonitor?.stopMonitoring()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Status Bar

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Capture", action: #selector(startCapture), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop Capture", action: #selector(stopCapture), keyEquivalent: "x"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    // MARK: - Overlay Window

    private func setupOverlayWindow() {
        overlayWindow = OverlayWindow()
        overlayWindow?.onExportAuditReport = { [weak self] in
            self?.handleExportAuditReport()
        }
        overlayWindow?.orderFront(nil)
    }

    // MARK: - Interpreter Fallback (P3.3)

    private func setupInterpreterFallback() {
        interpreterService = InterpreterService()

        // Bind the panic button in the overlay to the interpreter service
        if let panicButton = overlayWindow?.getPanicButton() {
            panicButton.bind(to: interpreterService!)

            panicButton.onRequestInterpreter = { [weak self] in
                self?.handleRequestInterpreter()
            }

            panicButton.onCancelSearch = { [weak self] in
                self?.interpreterService?.cancelSearch()
            }

            panicButton.onEndCall = { [weak self] in
                self?.handleEndInterpreterCall()
            }

            panicButton.onDismissSummary = { [weak self] in
                self?.interpreterService?.dismissSummary()
            }
        }

        // Timer to update the call duration display every second
        interpreterTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let duration = self.interpreterService?.currentCallDuration {
                    self.overlayWindow?.updatePanicButtonTimer(duration)
                }
            }
        }
    }

    private func handleRequestInterpreter() {
        interpreterService?.requestInterpreter(languages: ["en", "zh"], urgency: .normal)
    }

    private func handleEndInterpreterCall() {
        interpreterService?.endSession()
    }

    /// Update the panic button timer display. Called from the interpreter timer.
    func updateInterpreterTimer() {
        guard let duration = interpreterService?.currentCallDuration else { return }
        overlayWindow?.updatePanicButtonTimer(duration)
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            print("Microphone permission granted")
            startCapture()
        case .denied:
            showPermissionDeniedAlert()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.startCapture()
                    } else {
                        self.showPermissionDeniedAlert()
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText = "This app needs microphone access to capture audio for translation. Please enable it in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Capture Control

    // MARK: - Privacy Audit

    private func setupAttestationService() {
        do {
            attestationService = try AttestationService()
            print("Attestation service initialized")
        } catch {
            print("Failed to initialize attestation service: \(error)")
        }
    }

    private func handleExportAuditReport() {
        guard let sessionId = currentSessionId,
              let attestationService = attestationService,
              let attestation = attestationService.loadAttestation(sessionId: sessionId) else {
            let alert = NSAlert()
            alert.messageText = "No Audit Report Available"
            alert.informativeText = "No attestation was generated for this session."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Verify the attestation hasn't been tampered with
        guard attestationService.verifySignature(attestation) else {
            let alert = NSAlert()
            alert.messageText = "Attestation Tampered"
            alert.informativeText = "The attestation for this session has been modified. It cannot be trusted."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Generate PDF and show save panel
        let generator = AttestationPDFGenerator()

        do {
            let pdfURL = try generator.generatePDFAndSave(attestation: attestation)

            let savePanel = NSSavePanel()
            savePanel.title = "Export Privacy Audit Report"
            savePanel.nameFieldStringValue = "privacy-audit-\(attestation.sessionId).pdf"
            savePanel.allowedContentTypes = [.pdf]
            savePanel.canCreateDirectories = true

            savePanel.begin { response in
                if response == .OK, let destinationURL = savePanel.url {
                    do {
                        try FileManager.default.copyItem(at: pdfURL, to: destinationURL)
                        print("Audit report exported to \(destinationURL.path)")

                        // Open the exported file
                        NSWorkspace.shared.open(destinationURL)
                    } catch {
                        print("Failed to export audit report: \(error)")
                    }
                }
            }
        } catch {
            print("Failed to generate audit PDF: \(error)")
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = "Failed to generate the privacy audit PDF: \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func startCapture() {
        // Start network monitoring for privacy audit
        let sessionStartTime = Date()
        currentSessionStartTime = sessionStartTime
        currentSessionId = UUID().uuidString
        networkMonitor = NetworkMonitor(sessionStartTime: sessionStartTime)
        networkMonitor?.startMonitoring()

        if audioCaptureService == nil {
            audioCaptureService = AudioCaptureService()
        }

        // Initialize the concurrent interpreter pipeline (P1.4)
        if interpreterPipeline == nil {
            // Default to Resources/Models/whisper-tiny
            let modelPath = Bundle.main.resourceURL?
                .appendingPathComponent("Models/whisper-tiny", isDirectory: true)
                ?? URL(fileURLWithPath: "Models/whisper-tiny")

            let tokenizerPath = modelPath.appendingPathComponent("tokenizer.json")

            // Transcription service: MLX Whisper (guarded)
            var transcriptionService: TranscriptionService?
            #if canImport(MLX)
            do {
                transcriptionService = try WhisperTranscriptionService(
                    modelPath: modelPath,
                    tokenizerPath: tokenizerPath
                )
            } catch {
                print("Failed to initialize Whisper transcription service: \(error)")
            }
            #endif

            // Translation service: NLLB-200 EN↔ZH (guarded)
            var translationService: TranslationService?
            #if canImport(MLX)
            do {
                translationService = try NLLBTranslationService()
            } catch {
                print("Failed to initialize NLLB translation service: \(error)")
            }
            #endif

            // Both services must be available
            guard let whisper = transcriptionService,
                  let nllb = translationService else {
                print("Interpreter pipeline requires both Whisper and NLLB services")
                return
            }

            // Configure pipeline: English source → Mandarin target
            var config = PipelineConfig()
            config.sourceLanguage = "en"
            config.targetLanguage = "zh"
            config.minAudioDurationSeconds = 1.0
            config.maxAudioDurationSeconds = 30.0

            interpreterPipeline = InterpreterPipeline(
                transcriptionService: whisper,
                translationService: nllb,
                config: config
            )

            pipelineBridge = InterpreterPipelineBridge(pipeline: interpreterPipeline!)

            // Wire English-ready for staged reveal: EN appears immediately, ZH fills in later
            // ZH finalize happens via the translationCompleted event below
            pipelineBridge?.setEnglishReadyHandler { [weak self] event in
                self?.overlayWindow?.showPartialSegment(
                    chunkIndex: event.chunkIndex,
                    english: event.english,
                    confidence: event.confidence
                )
            }

            // Handle all pipeline events: englishReady via setEnglishReadyHandler,
            // translationCompleted finalizes the partial ZH, others for logging/telemetry.
            pipelineBridge?.setEventHandler { event in
                switch event {
                case .translationCompleted(let chunkIndex, let mandarin, _):
                    // Staged reveal: finalize the partial English-only segment with ZH text
                    self?.overlayWindow?.finalizePartialSegment(chunkIndex: chunkIndex, mandarin: mandarin)
                case .segmentProduced(_, let english, let mandarin, let latency):
                    print("Segment produced (EN→ZH, \(String(format: "%.1f", latency))s): \(english.prefix(30))... → \(mandarin.prefix(20))...")
                case .transcriptionFailed(let idx, let error):
                    print("Transcription failed [\(idx)]: \(error)")
                case .translationFailed(let idx, let error):
                    print("Translation failed [\(idx)]: \(error)")
                case .pipelineStalled(let reason):
                    print("Pipeline stalled: \(reason)")
                case .codeSwitchingCompleted(let chunkIndex, let segmentsCount, let preservedCount, let latency):
                    print("Code-switching [\(chunkIndex)]: \(segmentsCount) segments, \(preservedCount) preserved (\(String(format: "%.1f", latency * 1000))ms)")
                case .codeSwitchingSkipped(let chunkIndex, let reason):
                    print("Code-switching skipped [\(chunkIndex)]: \(reason)")
                default:
                    break
                }
            }

            // Wire segment handler for code-switching visual markup.
            // When code-switching is enabled, BilingualSegment carries the CodeSwitchingResult
            // which contains protected terms and mixed-segment info for overlay highlighting.
            // The segment handler fires after translationCompleted, so the overlay view
            // already has the base mandarin text — this applies the markup on top.
            var segmentCounter = 0
            pipelineBridge?.setSegmentHandler { [weak self] segment in
                guard let self = self, let csResult = segment.codeSwitchingResult else { return }
                let protectedTerms = csResult.segments.flatMap { $0.protectedTerms }
                let chunkIndex = segmentCounter
                segmentCounter += 1
                DispatchQueue.main.async {
                    self.overlayWindow.finalizePartialSegment(
                        chunkIndex: chunkIndex,
                        mandarin: segment.mandarin,
                        protectedTerms: protectedTerms,
                        hasCodeSwitching: csResult.hasCodeSwitching
                    )
                }
            }

            // NOTE: setSegmentHandler intentionally left nil — staged reveal via
            // setEnglishReadyHandler + translationCompleted provides better UX.
            // The full BilingualSegment is still available via the pipeline's
            // onSegment callback if a future handler needs it.

            print("Interpreter pipeline initialized (Whisper + NLLB-200)")
        }

        // Start pipeline
        pipelineBridge?.start()

        // Audio level → overlay meter
        audioCaptureService?.onAudioLevelUpdate = { [weak self] level in
            self?.overlayWindow?.updateAudioLevel(level)
        }

        // Audio buffer → interpreter pipeline (thread-safe bridge)
        audioCaptureService?.onAudioBufferCapture = { [weak self] buffer in
            self?.pipelineBridge?.feedAudioBuffer(buffer)
        }

        do {
            try audioCaptureService?.startCapture()
            print("Audio capture started")
        } catch {
            print("Failed to start audio capture: \(error)")
        }
    }

    @objc private func stopCapture() {
        audioCaptureService?.stopCapture()
        pipelineBridge?.stop()
        overlayWindow?.endSession()

        // Stop network monitoring and generate attestation
        networkMonitor?.stopMonitoring()
        if let monitor = networkMonitor,
           let attestationService = attestationService,
           let sessionId = currentSessionId,
           let startTime = currentSessionStartTime {

            let summary = monitor.generateSummary()
            let attestation = attestationService.generateAttestation(
                sessionId: sessionId,
                startTime: startTime,
                endTime: Date(),
                segmentCount: 0,  // Pipeline doesn't expose segment count to AppDelegate yet
                networkSummary: summary,
                networkLog: monitor.activityLog
            )

            do {
                try attestationService.saveAttestation(attestation)
                print("Privacy audit attestation saved for session \(sessionId)")
            } catch {
                print("Failed to save attestation: \(error)")
            }
        }

        print("Audio capture stopped")
    }
}
