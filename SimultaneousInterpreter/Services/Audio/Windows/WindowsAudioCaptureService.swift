import Foundation
#if canImport(CoreAudio)
import CoreAudio
#endif

/// WindowsAudioCaptureService handles system audio capture on Windows via WASAPI
///
/// This is a STUB implementation for future Windows support.
/// macOS uses AVAudioEngine (AudioCaptureService).
///
/// WASAPI loopback capture works for most applications:
/// - Zoom, Teams, Google Meet (Chrome) — Works
/// - Webex, Discord — Works
/// - Games with exclusive mode — May fail
///
/// Requirements:
/// - Windows 10/11
/// - No admin rights needed
/// - No third-party drivers required
public class WindowsAudioCaptureService {
    
    // MARK: - Properties
    
    private var isCapturing = false
    private var audioBufferHandler: ((Data) -> Void)?
    
    /// Audio format for capture
    private let sampleRate: Double = 16000
    private let channels: UInt32 = 1
    private let bitsPerChannel: UInt32 = 16
    private let bytesPerFrame: UInt32 { channels * (bitsPerChannel / 8) }
    
    // MARK: - Public API
    
    /// Start capturing system audio
    /// - Parameter handler: Called with captured audio data (16kHz PCM)
    public func startCapture(handler: @escaping (Data) -> Void) throws {
        guard !isCapturing else { return }
        
        // WASAPI loopback capture would be implemented here:
        //
        // 1. CoCreateInstance(CLSID_MMDeviceEnumerator)
        // 2. IMMDeviceEnumerator::GetDefaultAudioEndpoint(eRender, eConsole)
        // 3. IMMDevice::Activate(IID_IAudioClient)
        // 4. IAudioClient::Initialize(..., AUDCLNT_STREAMFLAGS_LOOPBACK, ...)
        // 5. IAudioClient::GetService(IID_IAudioCaptureClient)
        // 6. Capture loop: IAudioCaptureClient::GetBuffer(...) → process → ReleaseBuffer(...)
        
        self.audioBufferHandler = handler
        self.isCapturing = true
        
        // Stub: no-op for now
        print("[WindowsAudio] WASAPI loopback capture started (STUB)")
    }
    
    /// Stop capturing
    public func stopCapture() {
        guard isCapturing else { return }
        
        // Stop WASAPI capture loop
        // Release IAudioClient, IMMDevice, etc.
        
        isCapturing = false
        audioBufferHandler = nil
        
        print("[WindowsAudio] WASAPI loopback capture stopped")
    }
    
    /// Check if audio capture is available
    public static func isAvailable() -> Bool {
        // Check if running on Windows
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }
    
    /// Check WASAPI loopback support for a specific application
    /// - Parameter appName: Name of the application (e.g., "zoom.exe")
    /// - Returns: true if the app's audio can be captured
    public func canCaptureApplication(_ appName: String) -> Bool {
        // Known apps that work with WASAPI loopback:
        let compatibleApps = [
            "zoom.exe",
            "teams.exe", 
            "slack.exe",
            "chrome.exe",
            "firefox.exe",
            "msedge.exe",
            "webex.exe",
            "discord.exe"
        ]
        
        return compatibleApps.contains(appName.lowercased())
    }
    
    /// Get list of applications that may not work with WASAPI loopback
    public func incompatibleApplications() -> [String] {
        // Apps known to use exclusive mode or bypass WASAPI:
        return [
            "Some games with exclusive audio mode",
            "Certain legacy applications",
            "Applications using WASAPI exclusive mode"
        ]
    }
}

// MARK: - Audio Format

extension WindowsAudioCaptureService {
    
    /// WASAPI audio format structure
    public struct WASAPIAudioFormat {
        let sampleRate: Double
        let channels: UInt32
        let bitsPerSample: UInt32
        let validBitsPerSample: UInt32
        
        /// Default format for transcription (16kHz mono PCM)
        static var defaultFormat: WASAPIAudioFormat {
            return WASAPIAudioFormat(
                sampleRate: 16000,
                channels: 1,
                bitsPerSample: 16,
                validBitsPerSample: 16
            )
        }
    }
}

// MARK: - Error Handling

public enum WindowsAudioError: Error {
    case deviceNotFound
    case initializationFailed
    case captureNotSupported
    case exclusiveModeRequired
}

// MARK: - Cross-Platform Protocol

/// Platform-agnostic audio capture protocol
/// Implemented by AudioCaptureService (macOS) and WindowsAudioCaptureService (Windows)
public protocol PlatformAudioCaptureService {
    func startCapture(handler: @escaping (Data) -> Void) throws
    func stopCapture()
    static func isAvailable() -> Bool
}
