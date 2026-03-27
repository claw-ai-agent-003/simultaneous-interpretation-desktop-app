import Foundation

// MARK: - Interpreter Session States

/// The overall state of a human interpreter fallback session.
enum InterpreterSessionState: Equatable {
    /// No session active; panic button visible.
    case idle
    /// Searching for an available interpreter.
    case searching
    /// Interpreter found, establishing audio connection.
    case connecting(interpreterId: String)
    /// Live call in progress.
    case inCall(sessionId: String, interpreterId: String, startedAt: Date)
    /// Call ended, showing cost summary.
    case ended(summary: InterpreterSessionSummary)
}

// MARK: - Interpreter Request

/// Request payload sent to the interpreter dispatch service via WebSocket.
struct InterpreterRequest: Codable {
    let sessionId: String
    let languages: [String]
    let urgency: InterpreterUrgency

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case languages
        case urgency
    }
}

/// Urgency level for interpreter requests.
enum InterpreterUrgency: String, Codable, CaseIterable {
    case normal
    case high
    case urgent
}

// MARK: - Interpreter Response

/// Response from the dispatch service indicating an interpreter has accepted the request.
struct InterpreterDispatchResponse: Codable {
    let success: Bool
    let interpreterId: String
    let interpreterName: String
    let sessionId: String
    let estimatedWaitSeconds: Int?
    let webrtcOffer: String?   // SDP offer for WebRTC connection
    let iceServers: [ICEServer]?

    enum CodingKeys: String, CodingKey {
        case success
        case interpreterId = "interpreter_id"
        case interpreterName = "interpreter_name"
        case sessionId = "session_id"
        case estimatedWaitSeconds = "estimated_wait_seconds"
        case webrtcOffer = "webrtc_offer"
        case iceServers = "ice_servers"
    }
}

// MARK: - ICE Server

/// WebRTC ICE server configuration.
struct ICEServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

// MARK: - Interpreter Profile

/// Represents a human interpreter in the pilot pool.
struct InterpreterProfile: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let languages: [String]
    let isOnline: Bool
    let currentSessions: Int
    let maxSessions: Int

    var isAvailable: Bool {
        isOnline && currentSessions < maxSessions
    }
}

// MARK: - Session Summary

/// Cost and duration summary generated after an interpreter session ends.
struct InterpreterSessionSummary: Codable {
    let sessionId: String
    let interpreterId: String
    let interpreterName: String
    let startTime: Date
    let endTime: Date
    let durationMinutes: Int
    let costCNY: Decimal
    let currency: String
    let rating: Int?   // 1-5 stars, nil if not yet rated

    var formattedDuration: String {
        let minutes = durationMinutes
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }

    var formattedCost: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: costCNY as NSDecimalNumber) ?? "¥\(costCNY)"
    }
}

// MARK: - Pricing Configuration

/// Pricing rules for interpreter sessions.
struct InterpreterPricingConfig {
    /// Cost per minute in CNY.
    let ratePerMinute: Decimal = 10
    /// Minimum charge in CNY.
    let minimumCharge: Decimal = 100
    /// Minimum session duration in minutes (billed even for shorter calls).
    let minimumMinutes: Int = 10
    /// Pilot discount percentage (0-100).
    let pilotDiscountPercent: Int = 0

    /// Calculate the cost for a session of the given duration.
    func calculateCost(durationMinutes: Int) -> Decimal {
        let billableMinutes = max(durationMinutes, minimumMinutes)
        var cost = Decimal(billableMinutes) * ratePerMinute
        cost = max(cost, minimumCharge)
        if pilotDiscountPercent > 0 {
            let discount = cost * Decimal(pilotDiscountPercent) / 100
            cost -= discount
        }
        return cost
    }
}

// MARK: - WebSocket Messages

/// Envelope for all WebSocket messages to/from the dispatch service.
enum InterpreterWSMessage: Codable {
    case request(InterpreterRequest)
    case response(InterpreterDispatchResponse)
    case heartbeat
    case error(code: Int, message: String)
    case statusUpdate(interpreterId: String, status: String)

    enum CodingKeys: String, CodingKey {
        case type, payload
    }

    enum MessageType: String, Codable {
        case request, response, heartbeat, error, statusUpdate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .request(let req):
            try container.encode(MessageType.request, forKey: .type)
            try container.encode(req, forKey: .payload)
        case .response(let resp):
            try container.encode(MessageType.response, forKey: .type)
            try container.encode(resp, forKey: .payload)
        case .heartbeat:
            try container.encode(MessageType.heartbeat, forKey: .type)
        case .error(let code, let message):
            var payload = encoder.container(keyedBy: PayloadKeys.self)
            try container.encode(MessageType.error, forKey: .type)
            try payload.encode(code, forKey: .code)
            try payload.encode(message, forKey: .message)
        case .statusUpdate(let id, let status):
            var payload = encoder.container(keyedBy: PayloadKeys.self)
            try container.encode(MessageType.statusUpdate, forKey: .type)
            try payload.encode(id, forKey: .interpreterId)
            try payload.encode(status, forKey: .status)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .request:
            self = .request(try container.decode(InterpreterRequest.self, forKey: .payload))
        case .response:
            self = .response(try container.decode(InterpreterDispatchResponse.self, forKey: .payload))
        case .heartbeat:
            self = .heartbeat
        case .error:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .error(
                code: try payload.decode(Int.self, forKey: .code),
                message: try payload.decode(String.self, forKey: .message)
            )
        case .statusUpdate:
            let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
            self = .statusUpdate(
                interpreterId: try payload.decode(String.self, forKey: .interpreterId),
                status: try payload.decode(String.self, forKey: .status)
            )
        }
    }

    enum PayloadKeys: String, CodingKey {
        case code, message, interpreterId = "interpreter_id", status
    }
}

// MARK: - Audio Bridge Events

/// Events emitted by the AudioBridgeService.
enum AudioBridgeEvent {
    /// Local audio stream connected to interpreter.
    case localStreamConnected
    /// Interpreter's audio stream received and playing.
    case remoteStreamConnected
    /// Real-time caption received from interpreter.
    case captionReceived(text: String, language: String)
    /// Audio bridge encountered an error.
    case error(String)
    /// Audio bridge disconnected.
    case disconnected
}

// MARK: - Helper: Session ID Generator

extension String {
    /// Generate a unique interpreter session ID.
    static func interpreterSessionId() -> String {
        "interp-\(UUID().uuidString.prefix(8))"
    }
}
