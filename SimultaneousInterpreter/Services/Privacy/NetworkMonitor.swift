import Foundation
import Network

/// Monitors network state changes using NWPathMonitor.
/// Records all path-change events (timestamp, interface type, satisfaction)
/// without intercepting or modifying traffic.
///
/// Usage:
///   let monitor = NetworkMonitor()
///   monitor.start()
///   // ... session runs ...
///   let events = monitor.stop()
actor NetworkMonitor {

    // MARK: - State

    private var pathMonitor: NWPathMonitor?
    private var monitorQueue: DispatchQueue?
    private var events: [NetworkEvent] = []
    private var isRunning = false

    // MARK: - Public Interface

    /// Starts monitoring network path changes.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        events = []

        let queue = DispatchQueue(label: "com.interpretation.networkmonitor", qos: .utility)
        monitorQueue = queue

        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.recordPathChange(path)
            }
        }

        monitor.start(queue: queue)

        // Record initial state
        let initialPath = monitor.currentPath
        recordPathChange(initialPath)
    }

    /// Stops monitoring and returns all recorded events.
    func stop() -> [NetworkEvent] {
        guard isRunning else { return [] }
        isRunning = false
        pathMonitor?.cancel()
        pathMonitor = nil
        monitorQueue = nil
        return events
    }

    /// Returns a snapshot of currently recorded events without stopping.
    func currentEvents() -> [NetworkEvent] {
        return events
    }

    // MARK: - Private

    private func recordPathChange(_ path: NWPath) {
        guard isRunning else { return }

        // Build human-readable interface description
        let interfaceType = describeInterfaceTypes(path)

        // Extract primary interface name if available
        let interfaceName = path.availableInterfaces.first?.name

        let event = NetworkEvent(
            timestamp: Date(),
            interfaceType: interfaceType,
            satisfied: path.status == .satisfied,
            interfaceName: interfaceName
        )

        events.append(event)
    }

    /// Describes the active interface types on the current path.
    private func describeInterfaceTypes(_ path: NWPath) -> String {
        guard path.availableInterfaces.isEmpty == false else {
            return path.status == .satisfied ? "Unknown" : "No Interface"
        }

        var types: [String] = []
        if path.usesInterfaceType(.wifi) {
            types.append("Wi-Fi")
        }
        if path.usesInterfaceType(.cellular) {
            types.append("Cellular")
        }
        if path.usesInterfaceType(.wiredEthernet) {
            types.append("Ethernet")
        }
        if path.usesInterfaceType(.loopback) {
            types.append("Loopback")
        }
        if path.usesInterfaceType(.other) {
            types.append("Other")
        }

        return types.isEmpty ? "Unknown" : types.joined(separator: ", ")
    }
}
