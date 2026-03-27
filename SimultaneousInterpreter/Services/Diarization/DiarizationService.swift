import Foundation

// ============================================================
// MARK: - Diarization Service
// ============================================================

/// Coordinates speaker embedding extraction and clustering to identify
/// who is speaking in each audio chunk.
///
/// This service sits between Whisper transcription and NLLB translation
/// in the pipeline, operating **in parallel** with Whisper to avoid
/// adding end-to-end latency.
///
/// ## Pipeline Integration
///
/// ```
/// Audio → [Whisper (transcription)] ────→ NLLB → Overlay
///       ↘ [DiarizationService (embedding + clustering)] ↗
/// ```
///
/// Both paths start simultaneously when an audio chunk arrives.
/// The diarization result (speaker label) is attached to the
/// bilingual segment before it reaches the overlay.
///
/// ## Architecture
///
/// - `SpeakerEmbeddingService`: Extracts voice embeddings from audio
/// - `SpeakerClusterService`: Clusters embeddings into speaker identities
/// - `DiarizationService`: Coordinates the two and merges results
actor DiarizationService {

    // MARK: - Dependencies

    private let embeddingService: SpeakerEmbeddingService
    private let clusterService: SpeakerClusterService
    private let config: DiarizationConfig

    // MARK: - State

    /// Diarization tasks in flight, keyed by chunk index.
    private var diarizationTasks: [Int: Task<SpeakerLabel?, Never>] = [:]

    /// Pending diarization results waiting for their transcription to complete.
    /// chunkIndex → speaker label
    private var pendingLabels: [Int: SpeakerLabel] = [:]

    /// Whether the service is running.
    private var isRunning = false

    // MARK: - Callbacks

    /// Called when a diarized segment is ready (speaker label available).
    private var onSpeakerIdentified: (@Sendable (Int, SpeakerLabel) -> Void)?

    /// Called for diarization events (telemetry).
    private var onEvent: ((DiarizationEvent) -> Void)?

    // MARK: - Initialization

    /// Creates a new DiarizationService.
    /// - Parameter config: Configuration for diarization parameters.
    init(config: DiarizationConfig = DiarizationConfig()) {
        self.config = config
        self.embeddingService = SpeakerEmbeddingService(config: config)
        self.clusterService = SpeakerClusterService(config: config)
    }

    // MARK: - Lifecycle

    /// Starts the diarization service.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        pendingLabels.removeAll()
        diarizationTasks.removeAll()

        Task {
            await embeddingService.start()
        }
        await clusterService.reset()

        emit(.clusteringCompleted(totalSpeakers: 0))
    }

    /// Stops the diarization service and cancels all in-flight tasks.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        for task in diarizationTasks.values {
            task.cancel()
        }
        diarizationTasks.removeAll()
        pendingLabels.removeAll()

        Task {
            await embeddingService.stop()
        }
    }

    // MARK: - Event Handlers

    /// Sets callback invoked when a speaker is identified for a chunk.
    func setSpeakerIdentifiedHandler(_ handler: @escaping @Sendable (Int, SpeakerLabel) -> Void) {
        self.onSpeakerIdentified = handler
    }

    /// Sets callback for diarization events.
    func setEventHandler(_ handler: @escaping @Sendable (DiarizationEvent) -> Void) {
        self.onEvent = handler

        // Forward to sub-services
        Task {
            await embeddingService.setEventHandler(handler)
            await clusterService.setEventHandler(handler)
        }
    }

    // MARK: - Diarization (Parallel with Whisper)

    /// Processes an audio chunk for speaker diarization.
    ///
    /// This method should be called **immediately** when an audio chunk
    /// is ready, in parallel with Whisper transcription. The diarization
    /// result is stored and can be retrieved later via `getSpeakerLabel`.
    ///
    /// - Parameters:
    ///   - audioSamples: 16kHz mono PCM float samples [-1.0, 1.0]
    ///   - chunkIndex: Monotonic chunk index matching the pipeline
    func processAudioChunk(audioSamples: [Float], chunkIndex: Int) {
        guard isRunning else { return }

        // Cancel any previous diarization for this chunk (shouldn't happen)
        if let existing = diarizationTasks[chunkIndex] {
            existing.cancel()
        }

        let task = Task { [weak self] -> SpeakerLabel? in
            guard let self = self else { return nil }

            // Step 1: Extract embedding
            guard let embedding = await self.embeddingService.extractEmbedding(
                audioSamples: audioSamples,
                chunkIndex: chunkIndex
            ) else {
                self.emit(.embeddingFailed(
                    chunkIndex: chunkIndex,
                    error: "Failed to extract embedding"
                ))
                return nil
            }

            // Step 2: Classify into a speaker cluster
            guard !Task.isCancelled else { return nil }

            let speaker = await self.clusterService.classify(embedding)
            return speaker
        }

        diarizationTasks[chunkIndex] = task

        // When the task completes, store the result and notify
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let speaker = try await task.value
                await self.diarizationTasks.removeValue(forKey: chunkIndex)

                if let speaker = speaker {
                    await self.pendingLabels[chunkIndex] = speaker
                    await self.notifySpeakerIdentified(chunkIndex: chunkIndex, speaker: speaker)
                }
                // If speaker is nil (warmup phase), we simply don't label that chunk
            } catch {
                await self.diarizationTasks.removeValue(forKey: chunkIndex)
                // Task was cancelled or failed — no speaker label for this chunk
            }
        }
    }

    /// Retrieves the speaker label for a given chunk index.
    ///
    /// Returns nil if:
    /// - The chunk hasn't been diarized yet
    /// - Diarization is still in the warmup phase
    /// - The service is not running
    func getSpeakerLabel(forChunkIndex chunkIndex: Int) -> SpeakerLabel? {
        return pendingLabels[chunkIndex]
    }

    /// Returns all current speaker labels.
    func getAllSpeakers() async -> [SpeakerLabel] {
        return await clusterService.getAllSpeakers()
    }

    /// Returns the total number of detected speakers.
    func speakerCount() async -> Int {
        return await clusterService.speakerCount()
    }

    /// Returns true if the diarization result for the given chunk is ready.
    func isDiarizationReady(forChunkIndex chunkIndex: Int) -> Bool {
        return pendingLabels[chunkIndex] != nil
    }

    // MARK: - Helpers

    private func notifySpeakerIdentified(chunkIndex: Int, speaker: SpeakerLabel) {
        guard let handler = onSpeakerIdentified else { return }
        Task { @MainActor in
            handler(chunkIndex, speaker)
        }
    }

    private func emit(_ event: DiarizationEvent) {
        guard let handler = onEvent else { return }
        Task { @MainActor in
            handler(event)
        }
    }
}

// ============================================================
// MARK: - DiarizationServiceError
// ============================================================

enum DiarizationError: Error, LocalizedError {
    case serviceNotRunning
    case embeddingExtractionFailed(String)
    case clusteringFailed(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotRunning:
            return "Diarization service is not running"
        case .embeddingExtractionFailed(let reason):
            return "Embedding extraction failed: \(reason)"
        case .clusteringFailed(let reason):
            return "Speaker clustering failed: \(reason)"
        }
    }
}
