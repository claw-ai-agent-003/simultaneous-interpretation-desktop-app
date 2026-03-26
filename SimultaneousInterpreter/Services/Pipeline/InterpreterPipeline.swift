import Foundation

// ============================================================
// MARK: - Bilingual Segment
// ============================================================

/// A fully-translated bilingual segment ready for display.
struct BilingualSegment: Sendable {
    /// English transcription.
    let english: String

    /// Mandarin translation.
    let mandarin: String

    /// Whisper confidence score 0.0–1.0.
    let confidence: Float

    /// Duration of the source audio in seconds.
    let durationSeconds: Double

    /// Monotonic timestamp when this segment was produced.
    let producedAt: UInt64
}

// ============================================================
// MARK: - Pipeline Configuration
// ============================================================

/// Tuning parameters for the interpreter pipeline.
struct PipelineConfig: Sendable {
    /// Minimum audio duration (seconds) before triggering transcription.
    var minAudioDurationSeconds: Double = 1.0

    /// Maximum audio duration (seconds) per chunk.
    var maxAudioDurationSeconds: Double = 30.0

    /// Overlap between consecutive chunks (seconds) for VAD continuity.
    var overlapSeconds: Double = 0.5

    /// Maximum concurrent transcription tasks in flight.
    var maxConcurrentTranscriptions: Int = 2

    /// Language pair: source BCP-47 tag.
    var sourceLanguage: String = "en"

    /// Language pair: target BCP-47 tag.
    var targetLanguage: String = "zh"

    /// Audio sample rate (Hz).
    var sampleRate: Int = 16000

    /// Target end-to-end latency budget (seconds).
    var targetLatencySeconds: Double = 3.0
}

// ============================================================
// MARK: - Pipeline Events
// ============================================================

/// Events emitted by the pipeline for observability and logging.
enum PipelineEvent: Sendable {
    case audioChunked(chunkIndex: Int, durationSeconds: Double)
    case transcriptionStarted(chunkIndex: Int)
    case transcriptionCompleted(chunkIndex: Int, text: String, latencySeconds: Double)
    case transcriptionFailed(chunkIndex: Int, error: String)
    case translationStarted(chunkIndex: Int)
    case translationCompleted(chunkIndex: Int, mandarin: String, latencySeconds: Double)
    case translationFailed(chunkIndex: Int, error: String)
    case englishReady(chunkIndex: Int, english: String, confidence: Float, durationSeconds: Double)
    case segmentProduced(chunkIndex: Int, english: String, mandarin: String, endToEndLatencySeconds: Double)
    case pipelineStalled(reason: String)
}

/// A partial segment: English transcription arrived, Mandarin pending.
struct EnglishReadyEvent: Sendable {
    let chunkIndex: Int
    let english: String
    let confidence: Float
    let durationSeconds: Double
}

// ============================================================
// MARK: - Interpreter Pipeline (Actor)
// ============================================================

/// Actor that orchestrates concurrent Whisper → NLLB processing.
/// Audio buffers are queued, transcribed by Whisper, then translated by NLLB.
/// The pipeline produces bilingual segments in order with minimum latency.
actor InterpreterPipeline {

    // MARK: - Dependencies

    private let transcriptionService: TranscriptionService
    private let translationService: TranslationService
    private let config: PipelineConfig

    // MARK: - State

    private var audioBuffer: [Float] = []
    private var chunkIndex: Int = 0
    private var isRunning: Bool = false

    /// Completed transcriptions awaiting translation (chunkIndex → result).
    private var pendingTranscriptions: [Int: TranscriptionResult] = [:]

    /// Translation tasks in flight (chunkIndex → task).
    private var translationTasks: [Int: Task<TranslationResult, Error>] = [:]

    /// Transcription tasks in flight (chunkIndex → task) for cancellability.
    private var transcriptionTasks: [Int: Task<Void, Never>] = [:]

    /// Monotonic clock reference at pipeline start.
    private var startTime: UInt64 = 0

    // MARK: - Callbacks (main-actor isolated)

    private var onSegment: (@Sendable (BilingualSegment) -> Void)?
    private var onEnglishReady: (@Sendable (EnglishReadyEvent) -> Void)?
    private var onEvent: ((PipelineEvent) -> Void)?

    // MARK: - Init

    init(
        transcriptionService: TranscriptionService,
        translationService: TranslationService,
        config: PipelineConfig = PipelineConfig()
    ) {
        self.transcriptionService = transcriptionService
        self.translationService = translationService
        self.config = config
    }

    // MARK: - Public Interface

    /// Sets the segment callback (main-thread dispatched).
    func setSegmentHandler(_ handler: @escaping @Sendable (BilingualSegment) -> Void) {
        self.onSegment = handler
    }

    /// Sets the event callback for telemetry (main-thread dispatched).
    func setEventHandler(_ handler: @escaping @Sendable (PipelineEvent) -> Void) {
        self.onEvent = handler
    }

    /// Sets the English-ready callback for staged reveal (main-thread dispatched).
    /// Called immediately when Whisper transcription completes, before NLLB translation.
    func setEnglishReadyHandler(_ handler: @escaping @Sendable (EnglishReadyEvent) -> Void) {
        self.onEnglishReady = handler
    }

    /// Starts the pipeline.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        audioBuffer = []
        chunkIndex = 0
        startTime = mach_absolute_time()
        pendingTranscriptions = [:]
        translationTasks = [:]
        transcriptionTasks = [:]
    }

    /// Stops the pipeline and cancels all in-flight tasks.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        for task in transcriptionTasks.values {
            task.cancel()
        }
        transcriptionTasks.removeAll()

        for task in translationTasks.values {
            task.cancel()
        }
        translationTasks.removeAll()
        audioBuffer = []
    }

    /// Feeds raw 16kHz mono PCM audio data into the pipeline.
    /// Can be called from any thread — the actor handles synchronization.
    nonisolated func feedAudioBuffer(_ buffer: Data) {
        let floatSamples = buffer.withUnsafeBytes { rawBuffer -> [Float] in
            let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
            return int16Ptr.map { Float($0) / Float(Int16.max) }
        }

        Task {
            await enqueueAudio(floatSamples)
        }
    }

    // MARK: - Private — Audio Queue

    private func enqueueAudio(_ samples: [Float]) {
        guard isRunning else { return }
        audioBuffer.append(contentsOf: samples)

        let minSamples = Int(config.minAudioDurationSeconds * Double(config.sampleRate))
        let maxSamples = Int(config.maxAudioDurationSeconds * Double(config.sampleRate))

        if audioBuffer.count >= minSamples {
            processNextChunk(maxSamples: maxSamples)
        }
    }

    // MARK: - Private — Chunk Processing

    private func processNextChunk(maxSamples: Int) {
        guard isRunning else { return }

        let overlapSamples = Int(config.overlapSeconds * Double(config.sampleRate))
        let samplesToProcess = min(audioBuffer.count, maxSamples)

        let chunk = Array(audioBuffer.prefix(samplesToProcess))
        let keep = Array(audioBuffer.suffix(max(audioBuffer.count - samplesToProcess + overlapSamples, 0)))
        audioBuffer = keep

        let ci = chunkIndex
        chunkIndex += 1

        let chunkDuration = Double(samplesToProcess) / Double(config.sampleRate)
        await emit(.audioChunked(chunkIndex: ci, durationSeconds: chunkDuration))

        // Launch transcription immediately
        await emit(.transcriptionStarted(chunkIndex: ci))

        let transcriptionTask = Task {
            await runTranscription(chunkIndex: ci, audioSamples: chunk)
        }
        transcriptionTasks[ci] = transcriptionTask
    }

    private func runTranscription(chunkIndex: Int, audioSamples: [Float]) async {
        let pcmData = floatSamplesToPCMData(audioSamples)

        do {
            // Check if pipeline was stopped before we started transcription
            guard !Task.isCancelled else {
                transcriptionTasks.removeValue(forKey: chunkIndex)
                return
            }

            let t0 = mach_absolute_time()
            let result = try await transcriptionService.transcribe(audioData: pcmData)
            let latency = elapsedToSeconds(mach_absolute_time() - t0)

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty {
                transcriptionTasks.removeValue(forKey: chunkIndex)
                await emit(.transcriptionFailed(chunkIndex: chunkIndex, error: "Empty transcription"))
                return
            }

            transcriptionTasks.removeValue(forKey: chunkIndex)
            await emit(.transcriptionCompleted(chunkIndex: chunkIndex, text: text, latencySeconds: latency))

            // Emit English-ready for staged reveal — before translation completes
            await emitEnglishReady(EnglishReadyEvent(
                chunkIndex: chunkIndex,
                english: text,
                confidence: result.confidence,
                durationSeconds: result.durationSeconds
            ))

            // Store and chain to translation
            pendingTranscriptions[chunkIndex] = result
            await emit(.translationStarted(chunkIndex: chunkIndex))

            let transTask = Task { [weak self] () -> TranslationResult in
                guard let self = self else { throw CancellationError() }
                return try await self.translationService.translate(
                    text: text,
                    from: self.config.sourceLanguage,
                    to: self.config.targetLanguage
                )
            }

            translationTasks[chunkIndex] = transTask

            Task { [weak self] in
                guard let self = self else { return }
                do {
                    let tResult = try await transTask.value
                    await self.handleTranslationResult(chunkIndex: chunkIndex, translation: tResult)
                } catch {
                    await self.translationTasks.removeValue(forKey: chunkIndex)
                    await self.emit(.translationFailed(chunkIndex: chunkIndex, error: String(describing: error)))
                }
            }

        } catch {
            transcriptionTasks.removeValue(forKey: chunkIndex)
            await emit(.transcriptionFailed(chunkIndex: chunkIndex, error: String(describing: error)))
        }
    }

    private func handleTranslationResult(chunkIndex: Int, translation: TranslationResult) async {
        translationTasks.removeValue(forKey: chunkIndex)

        guard !Task.isCancelled else { return }

        let mandarin = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tLatency = elapsedToSeconds(mach_absolute_time() - startTime)

        await emit(.translationCompleted(chunkIndex: chunkIndex, mandarin: mandarin, latencySeconds: tLatency))

        // Retrieve stored transcription for English text and confidence
        guard let transcription = pendingTranscriptions.removeValue(forKey: chunkIndex) else {
            await emit(.translationFailed(chunkIndex: chunkIndex, error: "Transcription result not found"))
            return
        }

        let english = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let segment = BilingualSegment(
            english: english,
            mandarin: mandarin,
            confidence: transcription.confidence,
            durationSeconds: transcription.durationSeconds,
            producedAt: mach_absolute_time()
        )

        await emit(.segmentProduced(
            chunkIndex: chunkIndex,
            english: english,
            mandarin: mandarin,
            endToEndLatencySeconds: tLatency
        ))

        await deliverSegment(segment)
    }

    // MARK: - Helpers

    private func floatSamplesToPCMData(_ samples: [Float]) -> Data {
        var int16Samples = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            int16Samples[i] = Int16(clamping: Int32(s * Float(Int16.max)))
        }
        return int16Samples.withUnsafeBytes { Data($0) }
    }

    private func deliverSegment(_ segment: BilingualSegment) {
        guard let handler = onSegment else { return }
        Task { @MainActor in
            handler(segment)
        }
    }

    private func emitEnglishReady(_ event: EnglishReadyEvent) {
        guard let handler = onEnglishReady else { return }
        Task { @MainActor in
            handler(event)
        }
    }

    private func emit(_ event: PipelineEvent) {
        guard let handler = onEvent else { return }
        Task { @MainActor in
            handler(event)
        }
    }

    private func elapsedToSeconds(_ elapsed: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(elapsed) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}

// ============================================================
// MARK: - Bridge for Audio Thread
// ============================================================

/// Thread-safe, non-isolated bridge for feeding audio into the pipeline.
/// Allows calling feedAudioBuffer from any thread without actor isolation overhead.
final class InterpreterPipelineBridge: @unchecked Sendable {
    private let pipeline: InterpreterPipeline

    init(pipeline: InterpreterPipeline) {
        self.pipeline = pipeline
    }

    func start() {
        Task { await pipeline.start() }
    }

    func stop() {
        Task { await pipeline.stop() }
    }

    /// Feed audio buffer from any thread — Data is immutable andSendable.
    nonisolated func feedAudioBuffer(_ buffer: Data) {
        pipeline.feedAudioBuffer(buffer)
    }

    func setSegmentHandler(_ handler: @escaping @Sendable (BilingualSegment) -> Void) {
        Task { await pipeline.setSegmentHandler(handler) }
    }

    func setEventHandler(_ handler: @escaping @Sendable (PipelineEvent) -> Void) {
        Task { await pipeline.setEventHandler(handler) }
    }

    func setEnglishReadyHandler(_ handler: @escaping @Sendable (EnglishReadyEvent) -> Void) {
        Task { await pipeline.setEnglishReadyHandler(handler) }
    }
}
