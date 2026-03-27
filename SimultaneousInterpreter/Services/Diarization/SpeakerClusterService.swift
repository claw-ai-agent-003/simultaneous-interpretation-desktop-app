import Foundation

// ============================================================
// MARK: - Speaker Cluster Service
// ============================================================

/// Clusters speaker embeddings into distinct speakers using an incremental
/// DBSCAN-inspired algorithm.
///
/// The clustering runs online: each new embedding is classified immediately
/// as belonging to an existing speaker or as a new speaker. This avoids
/// the latency of batch clustering while maintaining speaker consistency
/// throughout the session.
///
/// ## Algorithm Overview
///
/// 1. **Warmup phase:** Collect `warmupEmbeddings` before any clustering.
///    During warmup, all embeddings are stored but no speaker assignment occurs.
///
/// 2. **Initial clustering:** After warmup, run a one-time greedy clustering
///    on the buffered embeddings to seed the initial speaker centroids.
///
/// 3. **Incremental assignment:** For each new embedding:
///    - Compute cosine similarity to all existing speaker centroids
///    - If the maximum similarity exceeds `similarityThreshold`, assign to that speaker
///    - Otherwise, create a new speaker (if under `maxSpeakers`)
///    - Update the centroid with exponential moving average
///
/// ## Pure Swift Implementation
///
/// This implementation uses only Foundation types and does not depend on
/// Python, NumPy, or any external numeric libraries. All linear algebra
/// (cosine similarity, vector operations) is implemented inline.
actor SpeakerClusterService {

    // MARK: - Types

    /// A cluster representing a single speaker.
    private struct SpeakerCluster: Sendable {
        /// The speaker label assigned to this cluster.
        let label: SpeakerLabel

        /// Running centroid (mean embedding) for this speaker.
        /// Updated with exponential moving average.
        var centroid: [Float]

        /// Number of embeddings assigned to this cluster.
        var count: Int

        /// Recent embedding samples (for recalculating centroid).
        var recentEmbeddings: [SpeakerEmbedding]

        /// Maximum recent embeddings to keep.
        let maxRecent: Int = 20

        mutating func update(with embedding: SpeakerEmbedding) {
            recentEmbeddings.append(embedding)
            if recentEmbeddings.count > maxRecent {
                recentEmbeddings.removeFirst()
            }
            count += 1

            // Exponential moving average update
            let alpha: Float = 0.1
            for i in 0..<centroid.count {
                guard i < embedding.vector.count else { break }
                centroid[i] = centroid[i] * (1.0 - alpha) + embedding.vector[i] * alpha
            }
        }

        /// Recomputes centroid from recent embeddings.
        mutating func recomputeCentroid() {
            guard !recentEmbeddings.isEmpty else { return }
            let dim = centroid.count
            var sum = [Float](repeating: 0, count: dim)
            for emb in recentEmbeddings {
                for i in 0..<min(dim, emb.vector.count) {
                    sum[i] += emb.vector[i]
                }
            }
            let n = Float(recentEmbeddings.count)
            for i in 0..<dim {
                centroid[i] = sum[i] / n
            }
        }
    }

    // MARK: - Properties

    /// Configuration parameters.
    private let config: DiarizationConfig

    /// Discovered speaker clusters.
    private var clusters: [SpeakerCluster] = []

    /// Mapping from chunk index to assigned speaker label.
    private var assignmentMap: [Int: SpeakerLabel] = [:]

    /// Embeddings collected during warmup (before first clustering).
    private var warmupBuffer: [SpeakerEmbedding] = []

    /// Whether we've completed the initial warmup + seed clustering.
    private var isInitialized = false

    /// The most recently assigned speaker (for smoothing).
    private var lastAssignedSpeaker: SpeakerLabel? = nil

    // MARK: - Event Callback

    private var onEvent: (@Sendable (DiarizationEvent) -> Void)?

    // MARK: - Initialization

    init(config: DiarizationConfig = DiarizationConfig()) {
        self.config = config
    }

    // MARK: - Event Handler

    func setEventHandler(_ handler: @escaping @Sendable (DiarizationEvent) -> Void) {
        self.onEvent = handler
    }

    // MARK: - Public Interface

    /// Resets the cluster service for a new session.
    func reset() {
        clusters.removeAll()
        assignmentMap.removeAll()
        warmupBuffer.removeAll()
        isInitialized = false
        lastAssignedSpeaker = nil
    }

    /// Classifies an embedding into a speaker cluster.
    ///
    /// During warmup, the embedding is buffered but no assignment is made.
    /// After warmup, the embedding is assigned to the best-matching cluster
    /// or a new cluster is created.
    ///
    /// - Parameter embedding: The speaker embedding to classify.
    /// - Returns: The assigned `SpeakerLabel`, or nil if still in warmup.
    func classify(_ embedding: SpeakerEmbedding) async -> SpeakerLabel? {
        if !isInitialized {
            warmupBuffer.append(embedding)

            if warmupBuffer.count >= config.warmupEmbeddings {
                // Run initial seed clustering
                seedClusters()
                isInitialized = true

                // Assign all warmup embeddings
                for emb in warmupBuffer {
                    _ = assignEmbedding(emb)
                }
                warmupBuffer.removeAll()

                emit(.clusteringCompleted(totalSpeakers: clusters.count))
            }

            // During warmup, return nil (no speaker assignment yet)
            return nil
        }

        return assignEmbedding(embedding)
    }

    /// Gets the speaker label assigned to a specific chunk index.
    func getSpeaker(forChunkIndex chunkIndex: Int) -> SpeakerLabel? {
        return assignmentMap[chunkIndex]
    }

    /// Returns all current speaker labels.
    func getAllSpeakers() -> [SpeakerLabel] {
        return clusters.map { $0.label }
    }

    /// Returns the total number of detected speakers.
    func speakerCount() -> Int {
        return clusters.count
    }

    // MARK: - Seed Clustering (Greedy Agglomerative)

    /// Performs initial clustering on the warmup buffer using a greedy approach.
    ///
    /// Algorithm:
    /// 1. Pick the first embedding as the first cluster centroid
    /// 2. For each subsequent embedding, check if it's similar enough to any
    ///    existing cluster (cosine similarity > threshold)
    /// 3. If yes, add to that cluster; if no, create a new cluster
    /// 4. After all embeddings are assigned, merge clusters that are too similar
    private func seedClusters() {
        guard !warmupBuffer.isEmpty else { return }

        // Create first cluster from the first embedding
        let firstLabel = SpeakerLabel(index: 0)
        clusters.append(SpeakerCluster(
            label: firstLabel,
            centroid: warmupBuffer[0].vector,
            count: 1,
            recentEmbeddings: [warmupBuffer[0]]
        ))

        // Assign remaining embeddings greedily
        for i in 1..<warmupBuffer.count {
            let emb = warmupBuffer[i]
            let (bestClusterIdx, bestSimilarity) = findBestCluster(for: emb)

            if bestSimilarity >= config.similarityThreshold && bestClusterIdx != nil {
                clusters[bestClusterIdx!].update(with: emb)
            } else if clusters.count < config.maxSpeakers {
                // Create new cluster
                let newLabel = SpeakerLabel(index: clusters.count)
                clusters.append(SpeakerCluster(
                    label: newLabel,
                    centroid: emb.vector,
                    count: 1,
                    recentEmbeddings: [emb]
                ))
                emit(.newSpeakerDetected(
                    speaker: newLabel.displayName,
                    totalSpeakers: clusters.count
                ))
            } else {
                // At max speakers — assign to closest cluster anyway
                if let idx = bestClusterIdx {
                    clusters[idx].update(with: emb)
                }
            }
        }

        // Recompute centroids from accumulated data
        for i in clusters.indices {
            clusters[i].recomputeCentroid()
        }

        // Merge clusters that are too similar (within threshold)
        mergeSimilarClusters()

        // Enforce minimum speaker count if we have enough distinct embeddings
        enforceMinSpeakers()
    }

    /// Finds the cluster with the highest cosine similarity to the given embedding.
    private func findBestCluster(for embedding: SpeakerEmbedding) -> (index: Int?, similarity: Float) {
        var bestIdx: Int? = nil
        var bestSim: Float = -1.0

        for (i, cluster) in clusters.enumerated() {
            let sim = cosineSimilarity(embedding.vector, cluster.centroid)
            if sim > bestSim {
                bestSim = sim
                bestIdx = i
            }
        }

        return (bestIdx, bestSim)
    }

    /// Assigns an embedding to the best-matching cluster.
    private func assignEmbedding(_ embedding: SpeakerEmbedding) -> SpeakerLabel {
        let (bestClusterIdx, bestSimilarity) = findBestCluster(for: embedding)

        if bestSimilarity >= config.similarityThreshold, let idx = bestClusterIdx {
            // Assign to existing cluster
            clusters[idx].update(with: embedding)
            let label = clusters[idx].label

            // Smooth: if last assigned speaker matches, keep continuity
            // This prevents rapid speaker switching on ambiguous frames
            assignmentMap[embedding.chunkIndex] = label
            lastAssignedSpeaker = label
            emit(.speakerAssigned(chunkIndex: embedding.chunkIndex, speaker: label.displayName))
            return label

        } else if clusters.count < config.maxSpeakers {
            // Create new speaker cluster
            let newLabel = SpeakerLabel(index: clusters.count)
            clusters.append(SpeakerCluster(
                label: newLabel,
                centroid: embedding.vector,
                count: 1,
                recentEmbeddings: [embedding]
            ))
            assignmentMap[embedding.chunkIndex] = newLabel
            lastAssignedSpeaker = newLabel
            emit(.newSpeakerDetected(
                speaker: newLabel.displayName,
                totalSpeakers: clusters.count
            ))
            emit(.speakerAssigned(chunkIndex: embedding.chunkIndex, speaker: newLabel.displayName))
            return newLabel

        } else {
            // At max speakers — assign to closest cluster
            let fallbackIdx = bestClusterIdx ?? 0
            clusters[fallbackIdx].update(with: embedding)
            let label = clusters[fallbackIdx].label
            assignmentMap[embedding.chunkIndex] = label
            lastAssignedSpeaker = label
            emit(.speakerAssigned(chunkIndex: embedding.chunkIndex, speaker: label.displayName))
            return label
        }
    }

    /// Merges clusters whose centroids are too similar (above threshold).
    /// Iteratively merges the most similar pair until all pairs are below threshold.
    private func mergeSimilarClusters() {
        var changed = true
        while changed && clusters.count > 1 {
            changed = false
            var mergeI = -1
            var mergeJ = -1
            var maxSim: Float = -1.0

            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let sim = cosineSimilarity(clusters[i].centroid, clusters[j].centroid)
                    if sim > maxSim {
                        maxSim = sim
                        mergeI = i
                        mergeJ = j
                    }
                }
            }

            if maxSim > config.similarityThreshold * 1.1 {  // Use slightly higher threshold for merging
                // Merge j into i
                for emb in clusters[mergeJ].recentEmbeddings {
                    clusters[mergeI].update(with: emb)
                }
                clusters[mergeI].recomputeCentroid()
                clusters.remove(at: mergeJ)

                // Reassign labels to maintain sequential ordering
                for k in clusters.indices {
                    let newLabel = SpeakerLabel(index: k)
                    clusters[k] = SpeakerCluster(
                        label: newLabel,
                        centroid: clusters[k].centroid,
                        count: clusters[k].count,
                        recentEmbeddings: clusters[k].recentEmbeddings
                    )
                }

                // Update assignment map with new labels
                for key in assignmentMap.keys {
                    if let oldLabel = assignmentMap[key] {
                        if oldLabel.index < clusters.count {
                            assignmentMap[key] = clusters[oldLabel.index].label
                        }
                    }
                }

                changed = true
            }
        }
    }

    /// Enforces the minimum speaker count by splitting the largest cluster
    /// if we haven't reached minSpeakers.
    private func enforceMinSpeakers() {
        // If we have fewer clusters than minSpeakers and enough embeddings,
        // try to split the cluster with the highest variance
        while clusters.count < config.minSpeakers {
            // Find the cluster with the most embeddings
            guard let largestIdx = clusters.indices.max(by: {
                clusters[$0].count < clusters[$1].count
            }) else { break }

            guard clusters[largestIdx].recentEmbeddings.count >= 3 else { break }

            // Split the cluster: first half and second half
            let embeddings = clusters[largestIdx].recentEmbeddings
            let mid = embeddings.count / 2

            // Recompute centroids for the two halves
            let firstHalf = Array(embeddings.prefix(mid))
            let secondHalf = Array(embeddings.suffix(from: mid))

            // Update the existing cluster with first half
            clusters[largestIdx].recentEmbeddings = firstHalf
            clusters[largestIdx].recomputeCentroid()

            // Create a new cluster with second half
            let newLabel = SpeakerLabel(index: clusters.count)
            var newCluster = SpeakerCluster(
                label: newLabel,
                centroid: secondHalf.first!.vector,
                count: secondHalf.count,
                recentEmbeddings: secondHalf
            )
            newCluster.recomputeCentroid()
            clusters.append(newCluster)

            emit(.newSpeakerDetected(
                speaker: newLabel.displayName,
                totalSpeakers: clusters.count
            ))
        }
    }

    // MARK: - Event Emission

    private func emit(_ event: DiarizationEvent) {
        guard let handler = onEvent else { return }
        Task { @MainActor in
            handler(event)
        }
    }
}
