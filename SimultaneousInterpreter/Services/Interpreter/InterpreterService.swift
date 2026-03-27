import Foundation

// MARK: - Mock Interpreter Pool

/// Mock data for the pilot interpreter pool (10 interpreters, 9-5 coverage).
enum MockInterpreterPool {
    static let interpreters: [InterpreterProfile] = [
        InterpreterProfile(id: "INT-001", name: "张明华", languages: ["en", "zh"], isOnline: true, currentSessions: 0, maxSessions: 2),
        InterpreterProfile(id: "INT-002", name: "李婷", languages: ["en", "zh"], isOnline: true, currentSessions: 1, maxSessions: 2),
        InterpreterProfile(id: "INT-003", name: "王建国", languages: ["en", "zh", "ja"], isOnline: true, currentSessions: 0, maxSessions: 1),
        InterpreterProfile(id: "INT-004", name: "陈晓芳", languages: ["en", "zh"], isOnline: true, currentSessions: 2, maxSessions: 2),
        InterpreterProfile(id: "INT-005", name: "刘洋", languages: ["en", "zh", "ko"], isOnline: true, currentSessions: 0, maxSessions: 2),
        InterpreterProfile(id: "INT-006", name: "赵雪梅", languages: ["en", "zh"], isOnline: true, currentSessions: 1, maxSessions: 2),
        InterpreterProfile(id: "INT-007", name: "孙伟", languages: ["en", "zh", "fr"], isOnline: true, currentSessions: 0, maxSessions: 1),
        InterpreterProfile(id: "INT-008", name: "周丽", languages: ["en", "zh"], isOnline: true, currentSessions: 0, maxSessions: 2),
        InterpreterProfile(id: "INT-009", name: "吴强", languages: ["en", "zh"], isOnline: true, currentSessions: 1, maxSessions: 2),
        InterpreterProfile(id: "INT-010", name: "郑美玲", languages: ["en", "zh"], isOnline: true, currentSessions: 0, maxSessions: 2),
    ]
}

// MARK: - InterpreterService

/// Manages the human interpreter fallback flow.
///
/// Responsibilities:
/// - Track interpreter online status (pilot: 10 interpreters, 9-5 coverage)
/// - WebSocket connection to the interpreter dispatch service (mocked for pilot)
/// - Session lifecycle: request → dispatch → connect → in-call → end
///
/// In pilot mode, all dispatch logic is mocked locally. The WebSocket path
/// is preserved for future production integration.
@MainActor
final class InterpreterService: ObservableObject {

    // MARK: - Published State

    /// The current session state, driving UI updates.
    @Published private(set) var sessionState: InterpreterSessionState = .idle

    /// List of available interpreters.
    @Published private(set) var availableInterpreters: [InterpreterProfile] = []

    /// Error message to display, if any.
    @Published private(set) var errorMessage: String? = nil

    // MARK: - Dependencies

    private let audioBridge: AudioBridgeService
    private let pricingService: InterpreterPricingService
    private var sessionTimer: Timer?
    private var callStartTime: Date?

    /// WebSocket URL for dispatch service.
    /// In pilot mode, this is not actually connected.
    private let dispatchWebSocketURL: URL = URL(string: "wss://dispatch.interpretation.example.com/v1")!

    // MARK: - Init

    init(
        audioBridge: AudioBridgeService? = nil,
        pricingService: InterpreterPricingService? = nil
    ) {
        self.audioBridge = audioBridge ?? AudioBridgeService()
        self.pricingService = pricingService ?? InterpreterPricingService()
        loadAvailableInterpreters()
    }

    // MARK: - Interpreter Pool Management

    /// Load the current list of available interpreters.
    /// In pilot mode, uses the mock pool. In production, fetches from dispatch service.
    func loadAvailableInterpreters() {
        // Pilot mode: use mock pool with simulated 9-5 availability
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)

        var pool = MockInterpreterPool.interpreters

        // Simulate 9-5 weekday availability (in pilot, all are online for testing)
        // In production, the dispatch service would handle this
        #if !DEBUG
        let isWeekday = (weekday >= 2 && weekday <= 6)
        let isBusinessHours = (hour >= 9 && hour < 17)

        if !isWeekday || !isBusinessHours {
            // Outside business hours: reduce available pool
            pool = pool.map { interp in
                var updated = interp
                updated.isOnline = Bool.random()  // Some may still be on-call
                return updated
            }
        }
        #endif

        availableInterpreters = pool.filter { $0.isAvailable }
    }

    /// Check if any interpreter is currently available.
    var hasAvailableInterpreters: Bool {
        !availableInterpreters.isEmpty
    }

    // MARK: - Session Flow

    /// Request a human interpreter. Begins the dispatch flow.
    /// - Parameters:
    ///   - languages: Language pair required (e.g., ["en", "zh"])
    ///   - urgency: How urgently the interpreter is needed
    func requestInterpreter(
        languages: [String] = ["en", "zh"],
        urgency: InterpreterUrgency = .normal
    ) async {
        guard case .idle = sessionState else {
            errorMessage = "A session is already active"
            return
        }

        errorMessage = nil
        sessionState = .searching

        // Build request
        let sessionId = String.interpreterSessionId()
        let request = InterpreterRequest(
            sessionId: sessionId,
            languages: languages,
            urgency: urgency
        )

        // Pilot mode: simulate dispatch with mock delay
        await simulateDispatch(request: request)
    }

    /// End the current interpreter session.
    func endSession(rating: Int? = nil) {
        guard case .inCall(let sessionId, let interpreterId, let startedAt) = sessionState else {
            return
        }

        let endTime = Date()
        let durationMinutes = Int(endTime.timeIntervalSince(startedAt) / 60)
        let cost = pricingService.calculateCost(durationMinutes: durationMinutes)

        sessionTimer?.invalidate()
        sessionTimer = nil
        callStartTime = nil

        // Stop audio bridge
        audioBridge.disconnect()

        // Find interpreter name
        let interpreterName = availableInterpreters.first(where: { $0.id == interpreterId })?.name ?? "Unknown"

        let summary = InterpreterSessionSummary(
            sessionId: sessionId,
            interpreterId: interpreterId,
            interpreterName: interpreterName,
            startTime: startedAt,
            endTime: endTime,
            durationMinutes: durationMinutes,
            costCNY: cost,
            currency: "CNY",
            rating: rating
        )

        sessionState = .ended(summary: summary)

        // Refresh interpreter availability
        loadAvailableInterpreters()
    }

    /// Dismiss the ended session summary and return to idle.
    func dismissSummary() {
        guard case .ended = sessionState else { return }
        sessionState = .idle
    }

    /// Cancel a search in progress.
    func cancelSearch() {
        guard case .searching = sessionState else { return }
        sessionState = .idle
    }

    // MARK: - Mock Dispatch (Pilot)

    /// Simulate the interpreter dispatch flow.
    /// In production, this would send a WebSocket message and wait for a response.
    private func simulateDispatch(request: InterpreterRequest) async {
        // Simulate network delay (1-3 seconds)
        let delay = UInt64.random(in: 1_000_000_000...3_000_000_000)
        try? await Task.sleep(nanoseconds: delay)

        // Check for cancellation
        guard case .searching = sessionState else { return }

        // Find an available interpreter matching the requested languages
        guard let interpreter = findBestInterpreter(languages: request.languages) else {
            errorMessage = "No available interpreter found. Please try again later."
            sessionState = .idle
            return
        }

        // Transition to connecting
        sessionState = .connecting(interpreterId: interpreter.id)

        // Simulate connection setup (1-2 seconds)
        let connectDelay = UInt64.random(in: 1_000_000_000...2_000_000_000)
        try? await Task.sleep(nanoseconds: connectDelay)

        // Check for cancellation again
        guard case .connecting = sessionState else { return }

        // Mark interpreter as having one more session
        updateInterpreterSessionCount(interpreterId: interpreter.id, delta: 1)

        // Transition to in-call
        callStartTime = Date()
        sessionState = .inCall(
            sessionId: request.sessionId,
            interpreterId: interpreter.id,
            startedAt: callStartTime!
        )

        // Start session timer for UI updates
        startSessionTimer()

        // Connect audio bridge (mock in pilot)
        // TODO: Replace with actual WebRTC connection using dispatch response SDP
        audioBridge.connect(
            sessionId: request.sessionId,
            interpreterId: interpreter.id
        )
    }

    /// Find the best available interpreter for the given language pair.
    private func findBestInterpreter(languages: [String]) -> InterpreterProfile? {
        availableInterpreters
            .filter { interp in
                // Check if interpreter supports all requested languages
                languages.allSatisfy { interp.languages.contains($0) }
            }
            .sorted { $0.currentSessions < $1.currentSessions }  // Prefer less busy
            .first
    }

    /// Update an interpreter's session count in the local pool.
    private func updateInterpreterSessionCount(interpreterId: String, delta: Int) {
        guard let index = availableInterpreters.firstIndex(where: { $0.id == interpreterId }) else {
            return
        }
        var updated = availableInterpreters[index]
        updated = InterpreterProfile(
            id: updated.id,
            name: updated.name,
            languages: updated.languages,
            isOnline: updated.isOnline,
            currentSessions: max(0, updated.currentSessions + delta),
            maxSessions: updated.maxSessions
        )
        availableInterpreters[index] = updated
    }

    // MARK: - Session Timer

    /// Starts a timer that fires every second to update in-call duration.
    /// The `sessionState` is `.inCall` which is `Equatable`, so we use
    /// `objectWillChange` directly.
    private func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Trigger UI update by toggling objectWillChange
                self?.objectWillChange.send()
            }
        }
    }

    /// Get the current call duration string (e.g., "5:23").
    var currentCallDuration: String {
        guard case .inCall(_, _, let startedAt) = sessionState else {
            return "0:00"
        }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    /// Get the interpreter name for the current session.
    var currentInterpreterName: String? {
        switch sessionState {
        case .connecting(let id), .inCall(_, let id, _):
            return availableInterpreters.first(where: { $0.id == id })?.name
        case .ended(let summary):
            return summary.interpreterName
        default:
            return nil
        }
    }

    /// Get the current session summary (only available in `.ended` state).
    var currentSummary: InterpreterSessionSummary? {
        if case .ended(let summary) = sessionState {
            return summary
        }
        return nil
    }
}

// MARK: - WebSocket Integration (Production)

extension InterpreterService {

    /// Connect to the dispatch WebSocket service.
    /// TODO: Implement actual WebSocket connection for production.
    /// Currently only used for pilot mock dispatch.
    func connectToDispatchService() async {
        // TODO: Production implementation
        // 1. Open WebSocket connection to dispatchWebSocketURL
        // 2. Send heartbeat every 30s
        // 3. Listen for status updates
        // 4. Handle reconnection with exponential backoff
        print("[InterpreterService] WebSocket dispatch not yet implemented (pilot mode)")
    }

    /// Send a dispatch request over WebSocket.
    /// TODO: Replace simulateDispatch with actual WebSocket message.
    func sendDispatchRequest(_ request: InterpreterRequest) async throws -> InterpreterDispatchResponse {
        // TODO: Production implementation
        // 1. Serialize InterpreterWSMessage.request(request)
        // 2. Send via WebSocket
        // 3. Wait for InterpreterWSMessage.response with matching sessionId
        // 4. Timeout after 30 seconds
        throw InterpreterError.notImplemented
    }
}

// MARK: - Errors

enum InterpreterError: LocalizedError {
    case noAvailableInterpreter
    case dispatchTimeout
    case connectionFailed(String)
    case audioBridgeFailed(String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .noAvailableInterpreter:
            return "No available interpreter found"
        case .dispatchTimeout:
            return "Interpreter dispatch timed out"
        case .connectionFailed(let detail):
            return "Connection failed: \(detail)"
        case .audioBridgeFailed(let detail):
            return "Audio bridge failed: \(detail)"
        case .notImplemented:
            return "Feature not yet implemented"
        }
    }
}
