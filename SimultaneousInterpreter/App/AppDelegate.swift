import AppKit
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var audioCaptureService: AudioCaptureService?
    private var overlayWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureAudioSession()
        setupStatusBarItem()
        setupOverlayWindow()
        requestMicrophonePermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioCaptureService?.stopCapture()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Audio Session Configuration

    /// On macOS, AVAudioEngine handles audio configuration automatically.
    /// No explicit audio session setup is needed (unlike iOS which uses AVAudioSession).
    private func configureAudioSession() {
        // macOS: AVAudioEngine configures itself automatically when started.
        // The input node's format is queried directly from CoreAudio.
        print("AudioCaptureService will use default macOS audio configuration")
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

        audioCaptureService?.onAudioLevelUpdate = { [weak self] level in
            self?.overlayWindow?.updateAudioLevel(level)
        }

        audioCaptureService?.onAudioBufferCapture = { [weak self] buffer in
            self?.overlayWindow?.appendAudioBuffer(buffer)
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
        print("Audio capture stopped")
    }
}
