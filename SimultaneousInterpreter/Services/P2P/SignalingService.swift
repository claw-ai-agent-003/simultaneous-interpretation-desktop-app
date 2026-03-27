import Foundation

// ============================================================
// MARK: - P2P Signaling Service
// ============================================================
// P4.2: WebRTC 信令服务
// 负责通过 WebSocket 交换 SDP offer/answer 和 ICE candidates
// 预留 Firebase Realtime Database / Supabase Realtime 作为备选信令后端
// ============================================================

/// 信令服务协议
/// 定义 WebRTC 信令的抽象接口，支持多种信令后端实现
protocol SignalingServiceProtocol: AnyObject, Sendable {
    /// 连接到信令服务器
    /// - Parameters:
    ///   - serverURL: 信令服务器地址
    ///   - sessionId: 会话 ID
    ///   - participantId: 本地参与者 ID
    func connect(serverURL: String, sessionId: String, participantId: String) async throws

    /// 断开信令连接
    func disconnect() async

    /// 发送 SDP Offer 到目标参与者
    /// - Parameters:
    ///   - sdp: SDP offer 字符串
    ///   - targetId: 目标参与者 ID
    func sendSDPOffer(sdp: String, targetId: String) async

    /// 发送 SDP Answer 到目标参与者
    /// - Parameters:
    ///   - sdp: SDP answer 字符串
    ///   - targetId: 目标参与者 ID
    func sendSDPAnswer(sdp: String, targetId: String) async

    /// 发送 ICE Candidate 到目标参与者
    /// - Parameters:
    ///   - candidate: ICE candidate 配置
    ///   - targetId: 目标参与者 ID
    func sendICECandidate(candidate: ICECandidateMessage, targetId: String) async

    /// 加入房间
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - participantInfo: 参与者信息
    func joinRoom(sessionId: String, participantInfo: P2PParticipant) async throws -> [P2PParticipant]

    /// 离开房间
    /// - Parameter sessionId: 会话 ID
    func leaveRoom(sessionId: String) async

    /// 创建房间（房主）
    /// - Parameters:
    ///   - session: P2P 会话信息
    /// - Returns: 创建后的完整会话
    func createRoom(session: P2PSession) async throws -> P2PSession

    /// 发送房间事件（用户加入/离开等）
    /// - Parameter event: 房间事件
    func sendRoomEvent(_ event: RoomEventMessage) async
}

// MARK: - Signaling Events

/// 信令服务事件回调
protocol SignalingServiceDelegate: AnyObject {
    /// 收到 SDP Offer
    func signalingService(_ service: SignalingService, didReceiveSDPOffer offer: SDPOfferMessage)

    /// 收到 SDP Answer
    func signalingService(_ service: SignalingService, didReceiveSDPAnswer answer: SDPAnswerMessage)

    /// 收到 ICE Candidate
    func signalingService(_ service: SignalingService, didReceiveICECandidate candidate: ICECandidateMessage)

    /// 收到房间事件
    func signalingService(_ service: SignalingService, didReceiveRoomEvent event: RoomEventMessage)

    /// 连接状态变更
    func signalingService(_ service: SignalingService, didChangeState state: SignalingConnectionState)

    /// 收到错误
    func signalingService(_ service: SignalingService, didEncounterError error: Error)
}

/// 信令连接状态
enum SignalingConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)
}

// MARK: - WebSocket Signaling Service

/// 基于 WebSocket 的信令服务实现
/// TODO: 实际信令服务器集成 — 当前为 Pilot 架构设计
final class SignalingService: NSObject, SignalingServiceProtocol, @unchecked Sendable {

    // MARK: - Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var currentSessionId: String = ""
    private var currentParticipantId: String = ""
    private var serverURL: String = ""

    /// 信令服务器地址（配置化）
    private var configuredServerURL: String = ""

    /// ICE 服务器配置
    private var iceServers: [ICEServerConfig] = []

    /// 心跳定时器
    private var heartbeatTimer: Timer?

    /// 重连定时器
    private var reconnectTimer: Timer?

    /// 最大重连次数
    private var maxReconnectAttempts: Int = 5

    /// 当前重连次数
    private var reconnectAttempts: Int = 0

    /// 重连间隔（秒）
    private var reconnectIntervalSeconds: Double = 2.0

    /// 事件回调（main actor isolated）
    weak var delegate: SignalingServiceDelegate?

    /// 连接状态
    private var connectionState: SignalingConnectionState = .disconnected {
        didSet {
            Task { @MainActor in
                self.delegate?.signalingService(self, didChangeState: self.connectionState)
            }
        }
    }

    // MARK: - Initialization

    override init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config)
        super.init()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - SignalingServiceProtocol

    func connect(serverURL: String, sessionId: String, participantId: String) async throws {
        self.configuredServerURL = serverURL
        self.currentSessionId = sessionId
        self.currentParticipantId = participantId
        self.serverURL = serverURL

        connectionState = .connecting

        // 构建 WebSocket URL
        // 格式: wss://server/ws/signaling?sessionId=xxx&participantId=xxx
        guard var components = URLComponents(string: serverURL) else {
            throw P2PError.signalingConnectionFailed(reason: "无效的服务器地址: \(serverURL)")
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "sessionId", value: sessionId))
        queryItems.append(URLQueryItem(name: "participantId", value: participantId))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw P2PError.signalingConnectionFailed(reason: "无法构建 WebSocket URL")
        }

        // 创建 WebSocket 连接
        let wsTask = urlSession.webSocketTask(with: url)
        self.webSocketTask = wsTask
        wsTask.resume()

        // 开始接收消息
        receiveMessages()

        // 启动心跳
        startHeartbeat()

        // 等待连接确认
        try await waitForConnection(timeoutSeconds: 10.0)

        connectionState = .connected
        reconnectAttempts = 0
    }

    func disconnect() async {
        stopHeartbeat()
        stopReconnectTimer()

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
    }

    func sendSDPOffer(sdp: String, targetId: String) async {
        let message = SDPOfferMessage(
            senderId: currentParticipantId,
            targetId: targetId,
            sessionId: currentSessionId,
            sdp: sdp,
            type: "offer"
        )

        await sendSignalingMessage(.sdpOffer(message))
    }

    func sendSDPAnswer(sdp: String, targetId: String) async {
        let message = SDPAnswerMessage(
            senderId: currentParticipantId,
            targetId: targetId,
            sessionId: currentSessionId,
            sdp: sdp,
            type: "answer"
        )

        await sendSignalingMessage(.sdpAnswer(message))
    }

    func sendICECandidate(candidate: ICECandidateMessage, targetId: String) async {
        var candidateMessage = candidate
        // 注意: targetId 在 candidate 中可能已有，但我们覆盖它以确保正确路由
        let message = ICECandidateMessage(
            senderId: currentParticipantId,
            targetId: targetId,
            sessionId: currentSessionId,
            type: candidate.type,
            protocol_: candidate.protocol_,
            priority: candidate.priority,
            ip: candidate.ip,
            port: candidate.port,
            candidateType: candidate.candidateType,
            relatedAddress: candidate.relatedAddress,
            relatedPort: candidate.relatedPort,
            candidateString: candidate.candidateString
        )

        await sendSignalingMessage(.iceCandidate(message))
    }

    func joinRoom(sessionId: String, participantInfo: P2PParticipant) async throws -> [P2PParticipant] {
        // 发送加入房间请求
        let joinRequest = RoomEventMessage(
            eventType: .userJoined,
            sessionId: sessionId,
            senderId: participantInfo.participantId,
            data: try? String(data: encoder.encode(participantInfo), encoding: .utf8),
            timestamp: Date()
        )

        await sendRoomEvent(joinRequest)

        // 等待房间成员列表响应
        // TODO: 实现等待逻辑（可以通过 WebSocket 响应或直接返回空列表让调用方等待事件）
        return []
    }

    func leaveRoom(sessionId: String) async {
        let leaveEvent = RoomEventMessage(
            eventType: .userLeft,
            sessionId: sessionId,
            senderId: currentParticipantId,
            timestamp: Date()
        )

        await sendRoomEvent(leaveEvent)
    }

    func createRoom(session: P2PSession) async throws -> P2PSession {
        // 发送创建房间请求
        let createEvent = RoomEventMessage(
            eventType: .sessionStarted,
            sessionId: session.sessionId,
            senderId: session.hostId,
            data: try? String(data: encoder.encode(session), encoding: .utf8),
            timestamp: Date()
        )

        await sendRoomEvent(createEvent)

        // 返回创建的会话（带房主角色）
        return session
    }

    func sendRoomEvent(_ event: RoomEventMessage) async {
        await sendSignalingMessage(.roomEvent(event))
    }

    // MARK: - Private: WebSocket Message Handling

    private func sendSignalingMessage(_ message: SignalingMessage) async {
        guard let wsTask = webSocketTask else { return }

        do {
            let data = try encoder.encode(message)
            guard let jsonString = String(data: data, encoding: .utf8) else { return }

            let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
            try await wsTask.send(wsMessage)
        } catch {
            await handleError(P2PError.signalingConnectionFailed(reason: "发送消息失败: \(error.localizedDescription)"))
        }
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleReceivedText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleReceivedText(text)
                    }
                @unknown default:
                    break
                }

                // 继续接收下一条消息
                self.receiveMessages()

            case .failure(let error):
                Task { @MainActor in
                    self.handleError(P2PError.signalingConnectionFailed(reason: error.localizedDescription))
                }
                self.handleDisconnection()
            }
        }
    }

    private func handleReceivedText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let message = try decoder.decode(SignalingMessage.self, from: data)
            Task { @MainActor in
                self.dispatchSignalingMessage(message)
            }
        } catch {
            print("[SignalingService] 解析消息失败: \(error.localizedDescription)")
        }
    }

    private func dispatchSignalingMessage(_ message: SignalingMessage) {
        switch message {
        case .sdpOffer(let offer):
            delegate?.signalingService(self, didReceiveSDPOffer: offer)

        case .sdpAnswer(let answer):
            delegate?.signalingService(self, didReceiveSDPAnswer: answer)

        case .iceCandidate(let candidate):
            delegate?.signalingService(self, didReceiveICECandidate: candidate)

        case .roomEvent(let event):
            delegate?.signalingService(self, didReceiveRoomEvent: event)

        case .error(let error):
            delegate?.signalingService(self, didEncounterError: P2PError.signalingConnectionFailed(reason: error.message))
        }
    }

    // MARK: - Private: Connection Management

    private func waitForConnection(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if case .connected = connectionState {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        throw P2PError.signalingConnectionFailed(reason: "连接超时")
    }

    private func handleDisconnection() {
        guard connectionState != .disconnected else { return }

        if reconnectAttempts < maxReconnectAttempts {
            connectionState = .reconnecting
            scheduleReconnect()
        } else {
            connectionState = .failed("最大重连次数已用完")
            handleError(P2PError.signalingConnectionFailed(reason: "WebSocket 断开且重连失败"))
        }
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = reconnectIntervalSeconds * pow(2.0, Double(reconnectAttempts - 1)) // 指数退避

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task {
                try? await self.connect(
                    serverURL: self.configuredServerURL,
                    sessionId: self.currentSessionId,
                    participantId: self.currentParticipantId
                )
            }
        }
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func handleError(_ error: Error) {
        delegate?.signalingService(self, didEncounterError: error)
    }

    // MARK: - Private: Heartbeat

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.sendHeartbeat()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func sendHeartbeat() async {
        // 发送 WebSocket ping
        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                Task { @MainActor in
                    self?.handleError(P2PError.signalingConnectionFailed(reason: "心跳失败: \(error.localizedDescription)"))
                }
            }
        }
    }
}

// MARK: - Firebase Realtime Database Signaling (备选实现)

/// Firebase Realtime Database 信令服务（备选后端）
/// TODO: 需要配置 Firebase 项目和权限
final class FirebaseSignalingService: SignalingServiceProtocol, @unchecked Sendable {

    private let projectId: String
    private let firebaseURL: String
    private var currentSessionId: String = ""
    private var currentParticipantId: String = ""

    // Firebase REST API 相关
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(projectId: String) {
        self.projectId = projectId
        self.firebaseURL = "https://\(projectId)-default-rtdb.firebaseio.com/p2p-signaling"
        self.session = URLSession.shared
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func connect(serverURL: String, sessionId: String, participantId: String) async throws {
        self.currentSessionId = sessionId
        self.currentParticipantId = participantId
        // Firebase 信令不需要 WebSocket 连接，通过轮询或 Firebase SDK 的实时更新
        // TODO: 实现 Firebase SDK 集成
    }

    func disconnect() async {
        // 清理 Firebase 订阅
    }

    func sendSDPOffer(sdp: String, targetId: String) async {
        // 写入 Firebase: /sessions/{sessionId}/offers/{participantId}
        let path = "\(firebaseURL)/sessions/\(currentSessionId)/offers/\(currentParticipantId)"
        let data: [String: Any] = [
            "targetId": targetId,
            "sdp": sdp,
            "type": "offer",
            "timestamp": Date().timeIntervalSince1970
        ]
        await writeToFirebase(path: path, data: data)
    }

    func sendSDPAnswer(sdp: String, targetId: String) async {
        let path = "\(firebaseURL)/sessions/\(currentSessionId)/answers/\(currentParticipantId)"
        let data: [String: Any] = [
            "targetId": targetId,
            "sdp": sdp,
            "type": "answer",
            "timestamp": Date().timeIntervalSince1970
        ]
        await writeToFirebase(path: path, data: data)
    }

    func sendICECandidate(candidate: ICECandidateMessage, targetId: String) async {
        let path = "\(firebaseURL)/sessions/\(currentSessionId)/candidates/\(currentParticipantId)"
        let data: [String: Any] = [
            "targetId": targetId,
            "candidate": candidate.candidateString ?? "",
            "sdpMid": candidate.type,
            "sdpMLineIndex": candidate.priority,
            "timestamp": Date().timeIntervalSince1970
        ]
        await writeToFirebase(path: path, data: data)
    }

    func joinRoom(sessionId: String, participantInfo: P2PParticipant) async throws -> [P2PParticipant] {
        // 写入参与者信息到 Firebase
        let path = "\(firebaseURL)/sessions/\(sessionId)/participants/\(participantInfo.participantId)"
        let data = try encoder.encode(participantInfo)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        await writeToFirebase(path: path, data: dict)

        // 获取当前参与者列表
        return try await fetchParticipants(sessionId: sessionId)
    }

    func leaveRoom(sessionId: String) async {
        // 从 Firebase 移除参与者
        let path = "\(firebaseURL)/sessions/\(sessionId)/participants/\(currentParticipantId)"
        await deleteFromFirebase(path: path)
    }

    func createRoom(session: P2PSession) async throws -> P2PSession {
        let path = "\(firebaseURL)/sessions/\(session.sessionId)"
        let data = try encoder.encode(session)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        await writeToFirebase(path: path, data: dict)
        return session
    }

    func sendRoomEvent(_ event: RoomEventMessage) async {
        let path = "\(firebaseURL)/sessions/\(currentSessionId)/events/\(currentParticipantId)"
        let data = try? encoder.encode(event)
        let dict = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
        if let dict = dict {
            await writeToFirebase(path: path, data: dict)
        }
    }

    // MARK: - Private Firebase Helpers

    private func writeToFirebase(path: String, data: [String: Any]) async {
        guard let url = URL(string: "\(path).json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: data)
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                print("[FirebaseSignaling] 写入失败: \(httpResponse.statusCode)")
            }
        } catch {
            print("[FirebaseSignaling] 写入错误: \(error.localizedDescription)")
        }
    }

    private func deleteFromFirebase(path: String) async {
        guard let url = URL(string: "\(path).json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
                print("[FirebaseSignaling] 删除失败: \(httpResponse.statusCode)")
            }
        } catch {
            print("[FirebaseSignaling] 删除错误: \(error.localizedDescription)")
        }
    }

    private func fetchParticipants(sessionId: String) async throws -> [P2PParticipant] {
        let path = "\(firebaseURL)/sessions/\(sessionId)/participants.json"
        guard let url = URL(string: path) else { return [] }

        let (data, _) = try await session.data(from: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return []
        }

        var participants: [P2PParticipant] = []
        for (_, value) in dict {
            if let jsonData = try? JSONSerialization.data(withJSONObject: value),
               let participant = try? decoder.decode(P2PParticipant.self, from: jsonData) {
                participants.append(participant)
            }
        }
        return participants
    }
}

// MARK: - Supabase Realtime Signaling (备选实现)

/// Supabase Realtime 信令服务（备选后端）
/// TODO: 需要配置 Supabase 项目和 anon key
final class SupabaseSignalingService: SignalingServiceProtocol, @unchecked Sendable {

    private let supabaseURL: String
    private let anonKey: String
    private var currentSessionId: String = ""
    private var currentParticipantId: String = ""

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(supabaseURL: String, anonKey: String) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.session = URLSession.shared
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func connect(serverURL: String, sessionId: String, participantId: String) async throws {
        self.currentSessionId = sessionId
        self.currentParticipantId = participantId
        // Supabase Realtime 使用 WebSocket 连接到 Supabase 服务器
        // TODO: 实现 Supabase JS SDK 或原生 WebSocket 连接
    }

    func disconnect() async {
        // 断开 Supabase Realtime 订阅
    }

    func sendSDPOffer(sdp: String, targetId: String) async {
        await sendRealtimeMessage(channel: "signaling-\(currentSessionId)", event: "sdp_offer", payload: [
            "sender_id": currentParticipantId,
            "target_id": targetId,
            "sdp": sdp,
            "type": "offer"
        ])
    }

    func sendSDPAnswer(sdp: String, targetId: String) async {
        await sendRealtimeMessage(channel: "signaling-\(currentSessionId)", event: "sdp_answer", payload: [
            "sender_id": currentParticipantId,
            "target_id": targetId,
            "sdp": sdp,
            "type": "answer"
        ])
    }

    func sendICECandidate(candidate: ICECandidateMessage, targetId: String) async {
        await sendRealtimeMessage(channel: "signaling-\(currentSessionId)", event: "ice_candidate", payload: [
            "sender_id": currentParticipantId,
            "target_id": targetId,
            "candidate": candidate.candidateString ?? "",
            "candidate_type": candidate.candidateType
        ])
    }

    func joinRoom(sessionId: String, participantInfo: P2PParticipant) async throws -> [P2PParticipant] {
        return []
    }

    func leaveRoom(sessionId: String) async {
        await sendRealtimeMessage(channel: "signaling-\(sessionId)", event: "user_left", payload: [
            "participant_id": currentParticipantId
        ])
    }

    func createRoom(session: P2PSession) async throws -> P2PSession {
        return session
    }

    func sendRoomEvent(_ event: RoomEventMessage) async {
        await sendRealtimeMessage(channel: "signaling-\(currentSessionId)", event: "room_event", payload: [
            "event_type": event.eventType.rawValue,
            "sender_id": event.senderId,
            "data": event.data ?? ""
        ])
    }

    // MARK: - Private

    private func sendRealtimeMessage(channel: String, event: String, payload: [String: Any]) async {
        // TODO: 实现 Supabase Realtime WebSocket 消息发送
        // 格式参考 Supabase Realtime broadcast API
    }
}

// MARK: - Factory

extension SignalingService {
    /// 创建信令服务实例
    /// - Parameters:
    ///   - config: P2P 配置
    ///   - backend: 信令后端类型
    /// - Returns: 信令服务实例
    static func create(config: P2PConfig, backend: SignalingBackend = .websocket) -> SignalingServiceProtocol {
        switch backend {
        case .websocket:
            return SignalingService()
        case .firebase:
            return FirebaseSignalingService(projectId: config.firebaseProjectId)
        case .supabase:
            return SupabaseSignalingService(supabaseURL: config.supabaseURL, anonKey: config.supabaseAnonKey)
        }
    }
}

/// 信令后端类型
enum SignalingBackend: String, Sendable {
    case websocket = "websocket"
    case firebase = "firebase"
    case supabase = "supabase"
}
