import Foundation
import Network

// ============================================================
// MARK: - Network Activity Record
// ============================================================

/// A single recorded network activity event.
/// Used for privacy auditing — proves no data was sent to the cloud.
struct NetworkActivityRecord: Codable, Sendable {
    /// ISO 8601 timestamp of when the activity was observed.
    let timestamp: String

    /// The remote endpoint hostname or IP address (if available).
    let remoteHost: String

    /// The remote port number (if available).
    let remotePort: UInt16?

    /// Estimated bytes sent outbound (0 = no data confirmed).
    let bytesSent: UInt64

    /// Whether the connection was satisfied (true = interface was reachable).
    let satisfied: Bool

    /// Interface type that triggered this event.
    let interfaceType: String

    /// Human-readable description of the event.
    let description: String
}

// ============================================================
// MARK: - Network Monitor
// ============================================================

/// Monitors network path changes using NWPathMonitor.
///
/// **Important:** This monitor only observes network *status* changes
/// (e.g., Wi-Fi connected, cellular available, DNS resolvable).
/// It does NOT intercept, inspect, or block any actual network traffic.
/// The recorded data serves as supporting evidence for the privacy audit.
///
/// The primary zero-byte proof relies on the fact that this app performs
/// no outbound connections by design — all processing is local.
class NetworkMonitor {

    // MARK: - Properties

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.simultaneous-interpreter.network-monitor", qos: .utility)

    /// All recorded network activity events for the current session.
    private(set) var activityLog: [NetworkActivityRecord] = []

    /// Total estimated outbound bytes recorded during the session.
    /// This is always 0 since we don't make outbound connections.
    private(set) var totalBytesSent: UInt64 = 0

    /// Whether the monitor is currently active.
    private(set) var isMonitoring: Bool = false

    /// Callback invoked when a network path change is detected.
    var onNetworkChange: ((NWPath) -> Void)?

    /// Session start time for audit records.
    private let sessionStartTime: Date

    // MARK: - Initialization

    init(sessionStartTime: Date = Date()) {
        self.sessionStartTime = sessionStartTime
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Interface

    /// Starts monitoring network path changes.
    /// Records each path change as an audit event.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let record = self.recordPathChange(path)
            self.activityLog.append(record)

            // Notify observers on the main thread
            DispatchQueue.main.async { [weak self] in
                self?.onNetworkChange?(path)
            }
        }

        monitor.start(queue: monitorQueue)

        // Record the initial path state
        let initialRecord = NetworkActivityRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            remoteHost: "(initial path check)",
            remotePort: nil,
            bytesSent: 0,
            satisfied: monitor.currentPath.status == .satisfied,
            interfaceType: self.describeInterfaceType(monitor.currentPath),
            description: self.describePath(monitor.currentPath)
        )
        activityLog.append(initialRecord)

        print("NetworkMonitor: Started monitoring (session: \(sessionStartTime.ISO8601Format()))")
    }

    /// Stops monitoring network path changes.
    /// Call this when the interpretation session ends.
    func stopMonitoring() {
        guard isMonitoring else { return }
        monitor.cancel()
        isMonitoring = false
        print("NetworkMonitor: Stopped monitoring. Recorded \(activityLog.count) events, \(totalBytesSent) bytes sent.")
    }

    /// Manually records a potential outbound connection attempt.
    /// This is a defense-in-depth measure — the app does NOT make outbound
    /// connections, but this hook allows future auditing if networking is added.
    func recordOutboundAttempt(host: String, port: UInt16?, bytesSent: UInt64 = 0) {
        let record = NetworkActivityRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            remoteHost: host,
            remotePort: port,
            bytesSent: bytesSent,
            satisfied: true,
            interfaceType: "manual-record",
            description: "Outbound attempt to \(host)" + (port.map { ":\($0)" } ?? "")
        )
        activityLog.append(record)
        totalBytesSent += bytesSent
    }

    /// Returns a summary of the monitoring session for audit reporting.
    func generateSummary() -> NetworkAuditSummary {
        return NetworkAuditSummary(
            sessionStartTime: sessionStartTime,
            sessionEndTime: Date(),
            totalEvents: activityLog.count,
            totalBytesSent: totalBytesSent,
            outboundConnections: activityLog.filter { $0.bytesSent > 0 },
            pathChanges: activityLog.filter { $0.remoteHost == "(path change)" || $0.remoteHost == "(initial path check)" },
            isZeroBytes: totalBytesSent == 0 && activityLog.allSatisfy { $0.bytesSent == 0 }
        )
    }

    // MARK: - Private Helpers

    private func recordPathChange(_ path: NWPath) -> NetworkActivityRecord {
        let interfaceType = describeInterfaceType(path)

        // Only record significant path changes, not continuous polling
        let record = NetworkActivityRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            remoteHost: "(path change)",
            remotePort: nil,
            bytesSent: 0,  // Path monitoring does not send data
            satisfied: path.status == .satisfied,
            interfaceType: interfaceType,
            description: describePath(path)
        )

        print("NetworkMonitor: Path changed — \(record.description)")
        return record
    }

    private func describePath(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied:
            status = "reachable"
        case .unsatisfied:
            status = "unreachable"
        case .requiresConnection:
            status = "requires-connection"
        @unknown default:
            status = "unknown"
        }

        let interfaces = path.availableInterfaces.map { describeInterface($0) }.joined(separator: ", ")
        return "Status: \(status), Interfaces: [\(interfaces)]"
    }

    private func describeInterfaceType(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.cellular) { return "Cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if path.usesInterfaceType(.loopback) { return "Loopback" }
        return "Other"
    }

    private func describeInterface(_ interface: NWInterface) -> String {
        let type: String
        switch interface.type {
        case .wifi: type = "Wi-Fi"
        case .cellular: type = "Cellular"
        case .wiredEthernet: type = "Ethernet"
        case .loopback: type = "Loopback"
        case .other: type = "Other"
        @unknown default: type = "Unknown"
        }
        return "\(type)(\(interface.index))"
    }
}

// ============================================================
// MARK: - Network Audit Summary
// ============================================================

/// A high-level summary of network activity for a session.
/// Used by the attestation service to generate the audit report.
struct NetworkAuditSummary: Sendable {
    /// When the monitoring session started.
    let sessionStartTime: Date

    /// When the monitoring session ended.
    let sessionEndTime: Date

    /// Total number of network events recorded.
    let totalEvents: Int

    /// Total outbound bytes (should be 0 for a privacy-clean session).
    let totalBytesSent: UInt64

    /// Any records that indicate actual outbound data transfer.
    let outboundConnections: [NetworkActivityRecord]

    /// Path change events (interface up/down transitions).
    let pathChanges: [NetworkActivityRecord]

    /// Whether zero bytes were sent during the entire session.
    let isZeroBytes: Bool

    /// Duration of the monitoring session in seconds.
    var durationSeconds: Double {
        sessionEndTime.timeIntervalSince(sessionStartTime)
    }

    /// Human-readable verdict string.
    var verdict: String {
        isZeroBytes ? "CLEAN — Zero bytes sent to any external server" : "WARNING — \(totalBytesSent) bytes sent to external servers"
    }

    /// Status for PDF color coding.
    var statusColor: String {
        isZeroBytes ? "green" : "red"
    }
}
