import AVFoundation
import Foundation

/// Service responsible for capturing audio from the microphone using AVAudioEngine.
/// Audio is captured in real-time chunks and passed to the transcription pipeline.
class AudioCaptureService {

    // MARK: - Properties

    private let audioEngine = AVAudioEngine()
    private let audioFormat: AVAudioFormat
    private let sampleRate: Double = 16000.0
    private let bufferSize: AVAudioFrameCount = 4096

    private var isCapturing = false

    /// Callback invoked with normalized audio level (0.0 - 1.0) for UI display
    var onAudioLevelUpdate: ((Float) -> Void)?

    /// Callback invoked when a audio buffer is captured and ready for processing.
    /// The Data contains 16-bit PCM audio at 16kHz mono.
    var onAudioBufferCapture: ((Data) -> Void)?

    // MARK: - Initialization

    init() {
        // Configure for 16kHz mono PCM — optimal for Whisper speech recognition
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    // MARK: - Public Interface

    /// Starts capturing audio from the microphone input.
    /// - Throws: AudioConfigurationError if the audio engine cannot be started.
    func startCapture() throws {
        guard !isCapturing else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on the input node to receive audio samples
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true
    }

    /// Stops capturing audio from the microphone.
    func stopCapture() {
        guard isCapturing else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
    }

    // MARK: - Audio Processing

    /// Converts the audio buffer to the target format (16kHz mono PCM) and computes
    /// the normalized audio level for the UI meter.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)

        // Compute RMS audio level across all channels
        var sum: Float = 0.0
        for frame in 0..<frameLength {
            for channel in 0..<channelCount {
                let sample = channelData[channel][frame]
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Float(frameLength * channelCount))
        let level = min(1.0, max(0.0, rms * 10.0)) // Amplify and clamp

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevelUpdate?(level)
        }

        // Convert to 16kHz mono PCM for Whisper
        guard let convertedBuffer = convertToTargetFormat(buffer) else { return }

        // Extract PCM data as Data
        guard let pcmData = extractPCMData(from: convertedBuffer) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onAudioBufferCapture?(pcmData)
        }
    }

    /// Converts the input audio buffer to 16kHz mono Int16 PCM.
    private func convertToTargetFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: audioFormat) else {
            print("AudioCaptureService: Failed to create converter from \(buffer.format) to \(audioFormat)")
            return nil
        }

        let ratio = sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error {
            if let err = error {
                print("AudioCaptureService: Conversion error: \(err)")
            }
            return nil
        }

        return outputBuffer
    }

    /// Extracts raw PCM data bytes from an interleaved Int16 buffer.
    private func extractPCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format.isInterleaved,
              buffer.format.commonFormat == .pcmFormatInt16 else {
            return nil
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let totalBytes = frameLength * channelCount * MemoryLayout<Int16>.size

        guard let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        return Data(bytes: data, count: totalBytes)
    }
}
