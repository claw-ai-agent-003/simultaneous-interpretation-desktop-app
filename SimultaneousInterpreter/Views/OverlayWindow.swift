import AppKit
import AVFoundation

/// Semi-transparent overlay window that floats above all other windows.
/// Renders the live bilingual text and audio level indicator.
class OverlayWindow: NSWindow {

    private let overlayView: OverlayView

    init() {
        overlayView = OverlayView()

        // Position at bottom-center of the main screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let windowWidth: CGFloat = 700
        let windowHeight: CGFloat = 300
        let windowX = screenFrame.midX - windowWidth / 2
        let windowY = screenFrame.minY + 40

        let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.contentView = overlayView
    }

    /// Updates the displayed audio level meter.
    func updateAudioLevel(_ level: Float) {
        overlayView.updateAudioLevel(level)
    }

    /// Shows English text immediately with "翻译中..." placeholder.
    /// The Mandarin will be filled in later via finalizePartialSegment.
    func showPartialSegment(chunkIndex: Int, english: String, confidence: Float) {
        overlayView.showPartialSegment(chunkIndex: chunkIndex, english: english, confidence: confidence)
    }

    /// Fills in the Mandarin translation for a previously shown partial segment.
    func finalizePartialSegment(chunkIndex: Int, mandarin: String) {
        overlayView.finalizePartialSegment(chunkIndex: chunkIndex, mandarin: mandarin)
    }

    /// Shows a fully-resolved bilingual segment (both EN and ZH known).
    func showSegment(english: String, mandarin: String, confidence: Float) {
        overlayView.appendSegment(english: english, mandarin: mandarin, confidence: confidence)
    }

    /// Ends the session: shows "Session ended" message, freezes final segment.
    func endSession() {
        overlayView.endSession()
    }

    /// Clears the session and resets to pre-session state.
    func clearSession() {
        overlayView.clearSessionEnded()
    }
}
