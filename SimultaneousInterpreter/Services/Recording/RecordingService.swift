import AVFoundation
import Foundation

/// Service responsible for recording microphone audio to a file.
/// Records in M4A format (AAC codec) at 16kHz mono.
/// Only records microphone audio — not overlay/system sounds.
class RecordingService {

    // MARK: - Properties

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private let audioFormat: AVAudioFormat
    private let sampleRate: Double = 16000.0

    private(set) var isRecording = false
    private(set) var currentSession: RecordingSession?
    private var recordingStartTime: Date?

    /// Directory where recordings are stored.
    private let recordingsDirectory: URL

    // MARK: - Errors

    enum RecordingError: LocalizedError {
        case alreadyRecording
        case notRecording
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "Recording is already in progress."
            case .notRecording:
                return "No recording is currently in progress."
            case .engineStartFailed(let error):
                return "Failed to start audio engine: \(error.localizedDescription)"
            case .fileCreationFailed(let error):
                return "Failed to create audio file: \(error.localizedDescription)"
            case .permissionDenied:
                return "Microphone permission was denied."
            }
        }
    }

    // MARK: - Initialization

    init() {
        // Ensure recordings directory exists
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        recordingsDirectory = appSupport
            .appendingPathComponent("SimultaneousInterpreter", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Configure format for M4A/AAC output at 16kHz mono
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Public Interface

    /// Starts recording audio from the microphone.
    /// - Parameter sessionId: The session ID to associate with this recording.
    /// - Throws: RecordingError if already recording or if the audio engine fails to start.
    func startRecording(sessionId: String) async throws {
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }

        // Check microphone permission
        let hasPermission = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard hasPermission else {
            throw RecordingError.permissionDenied
        }

        // Create audio file for this session
        let timestamp = Int(Date().timeIntervalSince1970)
        let fileName = "\(sessionId)_\(timestamp).m4a"
        let fileURL = recordingsDirectory.appendingPathComponent(fileName)

        do {
            audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
            )
        } catch {
            throw RecordingError.fileCreationFailed(error)
        }

        // Set up audio engine
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw RecordingError.engineStartFailed(NSError(domain: "RecordingService", code: -1))
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap to write audio to file
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.writeBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw RecordingError.engineStartFailed(error)
        }

        recordingStartTime = Date()
        currentSession = RecordingSession(
            sessionId: sessionId,
            startTime: recordingStartTime!,
            audioFileURL: fileURL
        )
        isRecording = true
    }

    /// Stops the current recording and returns the session metadata.
    /// - Returns: RecordingSession with end time populated.
    /// - Throws: RecordingError if not currently recording.
    func stopRecording() async throws -> RecordingSession {
        guard isRecording, var session = currentSession else {
            throw RecordingError.notRecording
        }

        let endTime = Date()

        // Stop engine and remove tap
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Close audio file
        audioFile = nil

        // Update session
        session.endTime = endTime
        currentSession = nil
        isRecording = false
        recordingStartTime = nil

        return session
    }

    /// Returns the URL for a recording file given its session ID.
    /// Does not verify the file exists.
    static func recordingURL(for sessionId: String, timestamp: Int) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport
            .appendingPathComponent("SimultaneousInterpreter", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        return recordingsDir.appendingPathComponent("\(sessionId)_\(timestamp).m4a")
    }

    /// Lists all recording files in the recordings directory.
    func listRecordings() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return files.filter { $0.pathExtension == "m4a" }
    }

    /// Deletes a recording file.
    func deleteRecording(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let file = audioFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            print("RecordingService: Failed to write audio buffer: \(error)")
        }
    }
}
