import Foundation

// ============================================================
// MARK: - Speaker Embedding Service
// ============================================================

/// Extracts speaker embeddings from audio chunks.
///
/// Uses an MLX-based speaker embedding model (e.g. SpeechBrain ECAPA-TDNN
/// or x-vector) to produce a fixed-dimension vector per audio chunk.
///
/// The embedding vector captures voice characteristics independent of
/// spoken content, enabling speaker discrimination.
///
/// ## Model Requirements
///
/// The service expects an MLX-format speaker embedding model with the
/// following interface:
///
/// - **Recommended model:** SpeechBrain ECAPA-TDNN (256-dim output)
/// - **Alternative:** PyAnnote x-vector (512-dim, will be truncated/padded)
/// - **Format:** `.safetensors` weight files in a model directory
/// - **Input:** 16kHz mono PCM audio (same as Whisper pipeline)
/// - **Output:** L2-normalized embedding vector `[Float]`
///
/// ## Placeholder Implementation
///
/// The current implementation provides a **placeholder** embedding extractor
/// that uses MFCC-based features as a proxy. This allows the diarization
/// pipeline to be fully wired and tested end-to-end while the actual
/// ECAPA-TDNN model is being converted to MLX format.
///
/// To replace with the real model:
/// 1. Convert ECAPA-TDNN weights to MLX `.safetensors`
/// 2. Implement `forwardPass(audioSamples:)` using the model weights
/// 3. The rest of the pipeline (clustering, overlay) requires no changes
actor SpeakerEmbeddingService {

    // MARK: - Properties

    /// Configuration for embedding extraction.
    private let config: DiarizationConfig

    /// Buffer of recently extracted embeddings, keyed by chunk index.
    private var embeddingBuffer: [Int: SpeakerEmbedding] = [:]

    /// All known embeddings (for clustering reference), capped at config limit.
    private var allEmbeddings: [SpeakerEmbedding] = []

    /// Whether the service is active.
    private var isRunning = false

    // MARK: - Placeholder Model State
    // TODO: Replace with actual ECAPA-TDNN model weights when available

    /// Precomputed Mel filterbank for MFCC extraction (placeholder).
    private var melFilterbank: [[Float]] = []

    /// DCT matrix for MFCC computation (placeholder).
    private var dctMatrix: [[Float]] = []

    /// Sample rate expected by the embedding model.
    private let sampleRate: Int = 16000

    /// FFT size for spectrogram computation.
    private let fftSize: Int = 512

    /// Number of mel filter banks.
    private let nMelBins: Int = 40

    /// Number of MFCC coefficients (including energy).
    private let nMFCC: Int = 20

    /// Target embedding dimension (ECAPA-TDNN outputs 256-dim).
    private var embeddingDimension: Int { config.embeddingDimension }

    // MARK: - Event Callback

    private var onEvent: (@Sendable (DiarizationEvent) -> Void)?

    // MARK: - Initialization

    init(config: DiarizationConfig = DiarizationConfig()) {
        self.config = config
        buildMelFilterbank()
        buildDCTMatrix()
    }

    // MARK: - Lifecycle

    /// Starts the embedding service and initializes model resources.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        embeddingBuffer.removeAll()
        allEmbeddings.removeAll()

        // TODO: Load ECAPA-TDNN model weights from disk
        // let modelPath = Bundle.main.resourceURL?.appendingPathComponent("Models/ecapa-tdnn")
        // model = try loadECAPATDNN(from: modelPath)

        emit(.clusteringCompleted(totalSpeakers: 0))
    }

    /// Stops the service and releases resources.
    func stop() {
        isRunning = false
        embeddingBuffer.removeAll()
        allEmbeddings.removeAll()
    }

    // MARK: - Event Handler

    func setEventHandler(_ handler: @escaping @Sendable (DiarizationEvent) -> Void) {
        self.onEvent = handler
    }

    // MARK: - Embedding Extraction

    /// Extracts a speaker embedding from the given audio chunk.
    ///
    /// - Parameters:
    ///   - audioSamples: 16kHz mono PCM float samples [-1.0, 1.0]
    ///   - chunkIndex: Monotonic index matching the pipeline chunk
    /// - Returns: A `SpeakerEmbedding` with the extracted vector, or nil if extraction failed
    func extractEmbedding(
        audioSamples: [Float],
        chunkIndex: Int
    ) async -> SpeakerEmbedding? {
        guard isRunning else { return nil }
        guard audioSamples.count >= fftSize else { return nil }

        let t0 = CFAbsoluteTimeGetCurrent()

        // Extract placeholder embedding using MFCC statistics
        let embedding = computePlaceholderEmbedding(audioSamples: audioSamples)

        let result = SpeakerEmbedding(
            chunkIndex: chunkIndex,
            vector: embedding
        )

        // Store in buffers
        embeddingBuffer[chunkIndex] = result
        allEmbeddings.append(result)

        // Prune old embeddings if buffer exceeds maximum
        if allEmbeddings.count > config.maxBufferedEmbeddings {
            let excess = allEmbeddings.count - config.maxBufferedEmbeddings
            let removed = allEmbeddings.prefix(excess)
            for emb in removed {
                embeddingBuffer.removeValue(forKey: emb.chunkIndex)
            }
            allEmbeddings.removeFirst(excess)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        emit(.embeddingExtracted(chunkIndex: chunkIndex, durationMs: elapsed))

        return result
    }

    /// Retrieves a previously computed embedding by chunk index.
    func getEmbedding(forChunkIndex chunkIndex: Int) -> SpeakerEmbedding? {
        return embeddingBuffer[chunkIndex]
    }

    /// Returns all stored embeddings.
    func getAllEmbeddings() -> [SpeakerEmbedding] {
        return allEmbeddings
    }

    /// Returns the total number of embeddings extracted so far.
    func embeddingCount() -> Int {
        return allEmbeddings.count
    }

    // MARK: - Placeholder Embedding Computation
    //
    // This extracts MFCC features from the audio and compresses them
    // into a fixed-dimension vector using statistical pooling.
    //
    // IMPORTANT: This is a placeholder. The real ECAPA-TDNN model
    // produces much more discriminative embeddings. Replace
    // `computePlaceholderEmbedding` with the actual model forward pass.

    /// Computes a placeholder embedding from audio samples using MFCC statistics.
    ///
    /// The process:
    /// 1. Compute log-mel spectrogram
    /// 2. Extract MFCCs via DCT
    /// 3. Compute statistics (mean, std, max, min) across time frames
    /// 4. Concatenate and pad/trim to target dimension
    private func computePlaceholderEmbedding(audioSamples: [Float]) -> [Float] {
        // Step 1: Compute log-mel spectrogram
        let melSpec = computeLogMelSpectrogram(samples: audioSamples)

        // Step 2: Extract MFCCs via DCT
        let mfccs = computeMFCCs(melSpectrogram: melSpec)

        // Step 3: Compute temporal statistics (like ECAPA-TDNN's attentive pooling)
        let stats = computeTemporalStatistics(mfccs: mfccs)

        // Step 4: L2-normalize the final embedding
        let normalized = l2Normalize(stats)

        return normalized
    }

    /// Computes log-mel spectrogram from raw audio samples.
    private func computeLogMelSpectrogram(samples: [Float]) -> [[Float]] {
        let hopLength = fftSize / 2  // 50% overlap
        let nFrames = max(1, (samples.count - fftSize) / hopLength + 1)
        var melSpec: [[Float]] = []

        for frameIdx in 0..<nFrames {
            let start = frameIdx * hopLength
            let end = min(start + fftSize, samples.count)
            var frame = Array(samples[start..<end])

            // Pad if last frame is short
            while frame.count < fftSize {
                frame.append(0.0)
            }

            // Apply Hann window
            let windowed = applyHannWindow(frame)

            // Compute magnitude spectrum
            let spectrum = computeMagnitudeSpectrum(windowed)

            // Apply mel filterbank
            var melEnergies: [Float] = []
            for bin in 0..<nMelBins {
                let energy = zip(melFilterbank[bin], spectrum).map { $0.0 * $0.1 }.reduce(0, +)
                melEnergies.append(max(energy, 1e-10))
            }

            // Log scale
            let logMel = melEnergies.map { log10($0) }
            melSpec.append(logMel)
        }

        return melSpec
    }

    /// Computes MFCCs from log-mel spectrogram using DCT-II.
    private func computeMFCCs(melSpectrogram: [[Float]]) -> [[Float]] {
        let nFrames = melSpectrogram.count
        var mfccs: [[Float]] = []

        for frame in 0..<nFrames {
            var coefficients: [Float] = []
            for k in 0..<nMFCC {
                var sum: Float = 0
                for n in 0..<nMelBins {
                    sum += melSpectrogram[frame][n] * dctMatrix[k][n]
                }
                coefficients.append(sum)
            }
            mfccs.append(coefficients)
        }

        return mfccs
    }

    /// Computes temporal statistics from MFCCs.
    /// Returns mean, std, skewness, max, min concatenated.
    private func computeTemporalStatistics(mfccs: [[Float]]) -> [Float] {
        guard !mfccs.isEmpty else {
            return [Float](repeating: 0, count: embeddingDimension)
        }

        let nCoeffs = mfccs[0].count
        let nFrames = mfccs.count

        var stats: [Float] = []

        for c in 0..<nCoeffs {
            let values = mfccs.map { $0[c] }

            // Mean
            let mean = values.reduce(0, +) / Float(nFrames)
            stats.append(mean)

            // Standard deviation
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(nFrames)
            let std = sqrt(variance)
            stats.append(std)

            // Max
            stats.append(values.max() ?? 0)

            // Min
            stats.append(values.min() ?? 0)
        }

        // Pad or trim to target dimension
        if stats.count < embeddingDimension {
            stats.append(contentsOf: [Float](repeating: 0, count: embeddingDimension - stats.count))
        } else if stats.count > embeddingDimension {
            stats = Array(stats.prefix(embeddingDimension))
        }

        return stats
    }

    /// L2-normalizes a vector.
    private func l2Normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.map { $0 * $0 }.reduce(0, +))
        guard norm > 1e-8 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Applies a Hann window to a frame.
    private func applyHannWindow(_ frame: [Float]) -> [Float] {
        let n = frame.count
        return frame.enumerated().map { i, sample in
            let window = 0.5 * (1.0 - cos(2.0 * .pi * Float(i) / Float(n - 1)))
            return sample * window
        }
    }

    /// Computes magnitude spectrum via naive DFT (placeholder — real impl uses FFT).
    private func computeMagnitudeSpectrum(_ frame: [Float]) -> [Float] {
        let halfSpectrum = frame.count / 2 + 1
        var magnitudes = [Float](repeating: 0, count: halfSpectrum)

        for k in 0..<halfSpectrum {
            var real: Float = 0
            var imag: Float = 0
            for n in 0..<frame.count {
                let angle = -2.0 * .pi * Float(k) * Float(n) / Float(frame.count)
                real += frame[n] * cos(angle)
                imag += frame[n] * sin(angle)
            }
            magnitudes[k] = sqrt(real * real + imag * imag) / Float(frame.count)
        }

        return magnitudes
    }

    // MARK: - Filterbank & DCT Setup

    /// Builds a triangular mel filterbank matrix.
    private func buildMelFilterbank() {
        let nFreqBins = fftSize / 2 + 1
        let lowMel = hzToMel(0)
        let highMel = hzToMel(Float(sampleRate) / 2.0)

        melFilterbank = (0..<nMelBins).map { binIdx -> [Float] in
            let centerMel = lowMel + Float(binIdx + 1) * (highMel - lowMel) / Float(nMelBins + 1)
            let centerHz = melToHz(centerMel)
            var filter = [Float](repeating: 0, count: nFreqBins)

            for k in 0..<nFreqBins {
                let freq = Float(k) * Float(sampleRate) / Float(fftSize)
                let distance = abs(freq - centerHz)
                let bandwidth = 200.0  // Hz bandwidth per filter
                if distance < bandwidth {
                    filter[k] = 1.0 - distance / bandwidth
                }
            }
            return filter
        }
    }

    /// Builds a DCT-II matrix for MFCC computation.
    private func buildDCTMatrix() {
        dctMatrix = (0..<nMFCC).map { k -> [Float] in
            (0..<nMelBins).map { n -> Float in
                cos(.pi * Float(k) * (Float(n) + 0.5) / Float(nMelBins))
            }
        }
    }

    /// Converts Hz to mel scale.
    private func hzToMel(_ hz: Float) -> Float {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }

    /// Converts mel scale to Hz.
    private func melToHz(_ mel: Float) -> Float {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    // MARK: - Event Emission

    private func emit(_ event: DiarizationEvent) {
        guard let handler = onEvent else { return }
        Task { @MainActor in
            handler(event)
        }
    }
}

// MARK: - Embedding Service Errors

enum EmbeddingError: Error, LocalizedError {
    case serviceNotRunning
    case insufficientAudio
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .serviceNotRunning:
            return "Speaker embedding service is not running"
        case .insufficientAudio:
            return "Audio chunk too short for embedding extraction"
        case .modelNotLoaded:
            return "Speaker embedding model is not loaded"
        }
    }
}

// MARK: - Cosine Similarity Utility

/// Computes cosine similarity between two vectors.
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "Vectors must have the same dimensionality")
    let dotProduct = zip(a, b).map { $0.0 * $0.1 }.reduce(0, +)
    let normA = sqrt(a.map { $0 * $0 }.reduce(0, +))
    let normB = sqrt(b.map { $0 * $0 }.reduce(0, +))
    guard normA > 1e-8 && normB > 1e-8 else { return 0 }
    return dotProduct / (normA * normB)
}
