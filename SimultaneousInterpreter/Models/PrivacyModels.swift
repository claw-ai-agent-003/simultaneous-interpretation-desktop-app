import Foundation

// ============================================================
// MARK: - Network Event
// ============================================================

/// A single network state-change event captured during a session.
struct NetworkEvent: Codable, Sendable {
    /// ISO-8601 timestamp of the event.
    let timestamp: Date

    /// Human-readable description of the path change.
    let interfaceType: String

    /// Whether the path was satisfied (has connectivity).
    let satisfied: Bool

    /// Optional interface name (e.g. "en0").
    let interfaceName: String?
}

// ============================================================
// MARK: - Session Attestation
// ============================================================

/// Per-session privacy attestation record proving local-only processing.
/// Serialized as JSON for persistence and later PDF generation.
struct SessionAttestation: Codable, Sendable {
    /// Unique session identifier (UUID).
    let sessionID: String

    /// When the session started.
    let sessionStart: Date

    /// When the session ended.
    let sessionEnd: Date

    /// Total session duration in seconds.
    var durationSeconds: Double {
        sessionEnd.timeIntervalSince(sessionStart)
    }

    /// Number of audio segments processed.
    let segmentsProcessed: Int

    /// All network state-change events observed during the session.
    let networkEvents: [NetworkEvent]

    /// HMAC-SHA256 signature over the attestation payload.
    let signature: String

    /// ISO-8601 formatted version of the signature timestamp.
    let signedAt: String

    /// The raw payload that was signed (canonical JSON without the signature itself).
    let signedPayload: String
}

// ============================================================
// MARK: - Attestation Summary (for PDF)
// ============================================================

/// Lightweight summary for the PDF cover page.
struct AttestationSummary {
    let sessionID: String
    let sessionStart: String
    let sessionEnd: String
    let duration: String
    let segmentsProcessed: Int
    let networkEventsCount: Int
    let signatureHex: String
    let signedAt: String
    let generatedAt: String
}
