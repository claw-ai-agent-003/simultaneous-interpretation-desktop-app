import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var audioCaptureService: AudioCaptureService?
    private var overlayWindow: NSWindow?
    private var interpreterPipeline: InterpreterPipeline?
    private var pipelineBridge: InterpreterPipelineBridge?
    private var attestationService: AttestationService?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarItem()
        setupOverlayWindow()
        requestMicrophonePermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioCaptureService?.stopCapture()
        pipelineBridge?.stop()
        interpreterPipeline?.stop()
        // Best-effort attestation finalization on app quit
        if attestationService != nil {
            Task {
                try? await attestationService?.endSession()
            }
        }
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
        overlayWindow?.orderFront(nil)

        // Wire up the "Export Audit Report" button
        (overlayWindow as? OverlayWindow)?.onExportAuditReport = { [weak self] in
            self?.handleExportAuditReport()
        }
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

    @objc private func startCapture() {
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
                    Task { await self?.attestationService?.recordSegmentProcessed() }
                case .transcriptionFailed(let idx, let error):
                    print("Transcription failed [\(idx)]: \(error)")
                case .translationFailed(let idx, let error):
                    print("Translation failed [\(idx)]: \(error)")
                case .pipelineStalled(let reason):
                    print("Pipeline stalled: \(reason)")
                default:
                    break
                }
            }

            // NOTE: setSegmentHandler intentionally left nil — staged reveal via
            // setEnglishReadyHandler + translationCompleted provides better UX.
            // The full BilingualSegment is still available via the pipeline's
            // onSegment callback if a future handler needs it.

            print("Interpreter pipeline initialized (Whisper + NLLB-200)")
        }

        // Start attestation session
        attestationService = AttestationService()
        Task { await attestationService?.beginSession() }

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

        // Finalize attestation
        if attestationService != nil {
            Task {
                do {
                    let attestation = try await attestationService?.endSession()
                    if attestation != nil {
                        print("Attestation saved: \((attestation!.sessionID).prefix(8))...")
                    }
                } catch {
                    print("Failed to finalize attestation: \(error)")
                }
            }
        }

        print("Audio capture stopped")
    }

    // MARK: - Export Audit Report

    private func handleExportAuditReport() {
        Task { @MainActor in
            do {
                // Try to list saved attestations and use the most recent one
                let files = try await attestationService?.listSavedAttestations() ?? []
                guard let latestFile = files.last else {
                    showAlert(title: "No Audit Data", message: "No attestation records found. Start a session first.")
                    return
                }

                let attestation = try await attestationService?.loadAttestation(filename: latestFile)
                guard let attestation = attestation else {
                    showAlert(title: "Load Failed", message: "Could not load attestation file.")
                    return
                }

                let pdfURL = try AttestationPDFGenerator.generate(from: attestation)
                // Open the PDF in the default viewer
                NSWorkspace.shared.open(pdfURL)
                print("Audit PDF exported to: \(pdfURL.path)")

            } catch {
                showAlert(title: "Export Failed", message: error.localizedDescription)
                print("Export audit report failed: \(error)")
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
