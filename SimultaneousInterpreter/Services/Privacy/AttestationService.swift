import Foundation
import Security

// ============================================================
// MARK: - Session Attestation
// ============================================================

/// A cryptographic attestation for a single interpretation session.
/// Proves that zero bytes were sent to any external server during the session.
///
/// The attestation is:
/// - **Tamper-proof:** HMAC-SHA256 signed with a per-device key
/// - **Verifiable:** Anyone with the device key can re-verify the signature
/// - **Exportable:** Serialized to JSON for archival and PDF generation
struct SessionAttestation: Codable {
    /// Unique identifier for this session (UUID v4).
    let sessionId: String

    /// When the session started (ISO 8601).
    let sessionStartTime: String

    /// When the session ended (ISO 8601).
    let sessionEndTime: String

    /// Duration of the session in seconds.
    let sessionDurationSeconds: Double

    /// Number of transcription segments produced.
    let segmentCount: Int

    /// Whether zero bytes were sent to external servers.
    let zeroBytesSent: Bool

    /// Total outbound bytes recorded (should be 0).
    let totalOutboundBytes: UInt64

    /// Number of network events recorded during the session.
    let networkEventCount: Int

    /// Individual network activity records.
    let networkLog: [NetworkActivityRecord]

    /// Privacy verdict string.
    let verdict: String

    /// HMAC-SHA256 signature of the attestation payload (hex-encoded).
    /// Signs all fields except this one and `signatureAlgorithm`.
    let signature: String

    /// Algorithm used for signing.
    let signatureAlgorithm: String

    /// App version for audit trail.
    let appVersion: String

    /// macOS version for audit trail.
    let osVersion: String

    /// Device hardware model for audit trail.
    let hardwareModel: String
}

// ============================================================
// MARK: - Attestation Service
// ============================================================

/// Generates and manages session attestations.
///
/// Each interpretation session gets a signed attestation proving that
/// no data was sent to external servers. The attestation is stored as
/// JSON in the application support directory.
class AttestationService {

    // MARK: - Properties

    /// Directory where session attestations are stored.
    private let sessionsDirectory: URL

    /// HMAC key used for signing attestations.
    /// Generated once per device and stored in the Keychain.
    private let signingKey: Data

    /// ISO 8601 date formatter for consistent timestamp formatting.
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Initialization

    init() throws {
        // Set up sessions directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport
            .appendingPathComponent("SimultaneousInterpreter", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)

        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        // Load or generate signing key
        signingKey = try Self.loadOrCreateSigningKey()
    }

    // MARK: - Public Interface

    /// Generates a signed attestation for the completed session.
    /// - Parameters:
    ///   - sessionId: Unique identifier for the session.
    ///   - startTime: When the session started.
    ///   - endTime: When the session ended.
    ///   - segmentCount: Number of transcription segments produced.
    ///   - networkSummary: Summary of network activity during the session.
    ///   - networkLog: Detailed network activity log.
    /// - Returns: A signed `SessionAttestation` ready for export.
    func generateAttestation(
        sessionId: String,
        startTime: Date,
        endTime: Date,
        segmentCount: Int,
        networkSummary: NetworkAuditSummary,
        networkLog: [NetworkActivityRecord]
    ) -> SessionAttestation {
        // Build the attestation without signature
        var attestation = SessionAttestation(
            sessionId: sessionId,
            sessionStartTime: dateFormatter.string(from: startTime),
            sessionEndTime: dateFormatter.string(from: endTime),
            sessionDurationSeconds: endTime.timeIntervalSince(startTime),
            segmentCount: segmentCount,
            zeroBytesSent: networkSummary.isZeroBytes,
            totalOutboundBytes: networkSummary.totalBytesSent,
            networkEventCount: networkSummary.totalEvents,
            networkLog: networkLog,
            verdict: networkSummary.verdict,
            signature: "",  // Placeholder — will be computed below
            signatureAlgorithm: "HMAC-SHA256",
            appVersion: Self.getAppVersion(),
            osVersion: Self.getOSVersion(),
            hardwareModel: Self.getHardwareModel()
        )

        // Compute HMAC-SHA256 signature over the canonical JSON payload
        let canonicalJSON = Self.canonicalJSON(for: attestation)
        attestation.signature = Self.hmacSHA256(data: canonicalJSON, key: signingKey)

        return attestation
    }

    /// Saves an attestation to the sessions directory as JSON.
    /// - Parameter attestation: The attestation to save.
    /// - Returns: The file URL where the attestation was saved.
    func saveAttestation(_ attestation: SessionAttestation) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(attestation)

        let fileName = "\(attestation.sessionId).json"
        let fileURL = sessionsDirectory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)

        print("AttestationService: Saved attestation to \(fileURL.path)")
        return fileURL
    }

    /// Loads an attestation from the sessions directory.
    /// - Parameter sessionId: The session ID to load.
    /// - Returns: The loaded attestation, or nil if not found.
    func loadAttestation(sessionId: String) -> SessionAttestation? {
        let fileURL = sessionsDirectory.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionAttestation.self, from: data)
    }

    /// Lists all saved attestation session IDs.
    func listAttestations() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Verifies the HMAC signature of an attestation.
    /// - Parameter attestation: The attestation to verify.
    /// - Returns: `true` if the signature is valid (attestation has not been tampered with).
    func verifySignature(_ attestation: SessionAttestation) -> Bool {
        let canonicalJSON = Self.canonicalJSON(for: attestation)
        let expectedSignature = Self.hmacSHA256(data: canonicalJSON, key: signingKey)
        return expectedSignature == attestation.signature
    }

    // MARK: - Private — Cryptography

    /// Computes HMAC-SHA256 of the given data with the given key.
    private static func hmacSHA256(data: Data, key: Data) -> String {
        var context = CCHmacContext()
        CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA256), (key as NSData).bytes, key.count)
        CCHmacUpdate(&context, (data as NSData).bytes, data.count)

        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmacFinal(&context, &mac)

        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Generates the canonical JSON representation of an attestation (excluding signature).
    /// This is what gets signed — any tampering with the JSON will invalidate the signature.
    private static func canonicalJSON(for attestation: SessionAttestation) -> Data {
        // Create a temporary copy with empty signature for canonical form
        let canonical = SessionAttestation(
            sessionId: attestation.sessionId,
            sessionStartTime: attestation.sessionStartTime,
            sessionEndTime: attestation.sessionEndTime,
            sessionDurationSeconds: attestation.sessionDurationSeconds,
            segmentCount: attestation.segmentCount,
            zeroBytesSent: attestation.zeroBytesSent,
            totalOutboundBytes: attestation.totalOutboundBytes,
            networkEventCount: attestation.networkEventCount,
            networkLog: attestation.networkLog,
            verdict: attestation.verdict,
            signature: "",
            signatureAlgorithm: attestation.signatureAlgorithm,
            appVersion: attestation.appVersion,
            osVersion: attestation.osVersion,
            hardwareModel: attestation.hardwareModel
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(canonical)) ?? Data()
    }

    // MARK: - Private — Key Management

    /// Loads the device signing key from Keychain, or generates and stores a new one.
    private static func loadOrCreateSigningKey() throws -> Data {
        let serviceName = "com.simultaneous-interpreter.attestation"
        let accountName = "device-signing-key"

        // Try to load existing key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let keyData = result as? Data {
            print("AttestationService: Loaded existing signing key from Keychain")
            return keyData
        }

        // Generate a new 256-bit (32-byte) random key
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let resultStatus = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        guard resultStatus == errSecSuccess else {
            throw AttestationError.keyGenerationFailed
        }

        let newKey = Data(keyBytes)

        // Store in Keychain
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: newKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw AttestationError.keyStorageFailed
        }

        print("AttestationService: Generated and stored new signing key in Keychain")
        return newKey
    }

    // MARK: - Private — System Info

    private static func getAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private static func getOSVersion() -> String {
        let processInfo = ProcessInfo.processInfo
        return "macOS \(processInfo.operatingSystemVersion.majorVersion).\(processInfo.operatingSystemVersion.minorVersion).\(processInfo.operatingSystemVersion.patchVersion)"
    }

    private static func getHardwareModel() -> String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

// ============================================================
// MARK: - Errors
// ============================================================

enum AttestationError: LocalizedError {
    case keyGenerationFailed
    case keyStorageFailed
    case signingFailed
    case invalidAttestation

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed: return "Failed to generate device signing key"
        case .keyStorageFailed: return "Failed to store signing key in Keychain"
        case .signingFailed: return "Failed to sign attestation payload"
        case .invalidAttestation: return "Attestation signature verification failed"
        }
    }
}
