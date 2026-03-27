import Foundation

// ============================================================
// MARK: - P2P Session Manager
// ============================================================
// P4.2: P2P 会话管理
// 负责创建/加入/离开会议室，使用 WebRTC DataChannel 传输字幕数据
// 隐私策略：只广播转录文本，不广播原始音频
// ============================================================

/// P2P 会话管理服务
/// 核心功能：
/// 1. 创建和加入 P2P 会议室
/// 2. 管理 WebRTC 连接和 DataChannel
/// 3. 广播转录文本到所有参与者
final class P2PSessionManager: NSObject, @unchecked Sendable {

    // MARK: - Types

    /// P2P 模式
    enum P2PMode: Sendable {
        /// 关闭 P2P，单机模式
        case disabled

        /// 房主模式（创建会议室）
        case host(session: P2PSession)

        /// 参与者模式（加入会议室）
        case participant(session: P2PSession)
    }

    // MARK: - Properties

    /// 当前 P2P 模式
    private var mode: P2PMode = .disabled

    /// P2P 配置
    private let config: P2PConfig

    /// 本地参与者信息
    private var localParticipant: P2PParticipant?

    /// 信令服务
    private var signalingService: SignalingServiceProtocol?

    /// 参与者管理器
    let participantManager: ParticipantManager

    /// 翻译服务（用于生成各 participant 的翻译）
    private let translationService: TranslationService

    /// WebRTC PeerConnection 列表（participantId -> RTCPeerConnection）
    private var peerConnections: [String: Any] = [:]

    /// WebRTC DataChannel 列表（participantId -> RTCDataChannel）
    private var dataChannels: [String: Any] = [:]

    /// 同步队列
    private let queue = DispatchQueue(label: "com.simultaneousinterpreter.p2psessionmanager")

    /// 事件回调
    private var onSessionCreated: ((P2PSession) -> Void)?
    private var onSessionJoined: ((P2PSession) -> Void)?
    private var onSessionEnded: ((String) -> Void)?
    private var onParticipantJoined: ((P2PParticipant) -> Void)?
    private var onParticipantLeft: ((String) -> Void)?
    private var onError: ((P2PError) -> Void)?
    private var onSubtitleReceived: ((SubtitleUpdateMessage) -> Void)?

    /// 锁
    private let lock = NSLock()

    /// 是否已连接
    private(set) var isConnected: Bool = false

    // TODO: WebRTC 相关依赖（Pilot 阶段标注）
    // 在实际集成中，需要引入：
    // - GoogleWebRTC.framework (iOS/macOS)
    // - libjingle WebRTC (跨平台)
    // 以下为占位符，实际使用时替换为真实的 RTCPeerConnection 等

    /// WebRTC 配置（ICE 服务器等）
    /// TODO: 替换为真实的 RTCConfiguration
    private var webrtcConfig: [String: Any] = [:]

    // MARK: - Initialization

    init(config: P2PConfig, translationService: TranslationService) {
        self.config = config
        self.translationService = translationService
        self.participantManager = ParticipantManager(translationService: translationService)
        super.init()

        // 初始化 WebRTC 配置
        setupWebRTCConfig()
    }

    private func setupWebRTCConfig() {
        // TODO: 替换为真实的 RTCConfiguration
        webrtcConfig = [
            "iceServers": config.iceServers.map { ["urls": $0.urls] },
            "iceTransportPolicy": "all",
            "bundlePolicy": "balanced",
            "rtcpMuxPolicy": "require"
        ]
    }

    // MARK: - Public Interface

    /// 当前会话（如果存在）
    var currentSession: P2PSession? {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .disabled:
            return nil
        case .host(let session), .participant(let session):
            return session
        }
    }

    /// 当前模式
    var currentMode: P2PMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    /// 是否在 P2P 模式
    var isInP2PMode: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .disabled = mode { return false }
        return true
    }

    /// 创建会议室（房主）
    /// - Parameters:
    ///   - hostName: 房主显示名
    ///   - hostPreferredLanguage: 房主首选语言
    ///   - topic: 会议主题
    ///   - isPrivate: 是否私密
    ///   - password: 密码（私密时）
    /// - Returns: 创建的会话
    func createSession(
        hostName: String,
        hostPreferredLanguage: String = "zh",
        hostPreferredLanguageName: String = "中文",
        topic: String = "",
        isPrivate: Bool = false,
        password: String = ""
    ) async throws -> P2PSession {
        // 创建房主参与者
        let hostId = String.participantId()
        let hostParticipant = P2PParticipant(
            participantId: hostId,
            displayName: hostName,
            preferredLanguage: hostPreferredLanguage,
            preferredLanguageName: hostPreferredLanguageName,
            role: .host,
            avatarColor: "#4A90E2"
        )

        // 创建会话
        let sessionId = String.p2pSessionId()
        let session = P2PSession(
            sessionId: sessionId,
            hostId: hostId,
            hostName: hostName,
            participants: [hostParticipant],
            sourceLanguage: "en",
            state: .waiting,
            isPrivate: isPrivate,
            roomPassword: password,
            topic: topic
        )

        // 设置本地参与者
        localParticipant = hostParticipant

        // 设置模式
        lock.lock()
        mode = .host(session: session)
        lock.unlock()

        // 设置参与者管理器
        participantManager.setSession(sessionId)
        participantManager.addParticipant(hostParticipant)

        // 连接信令服务
        try await connectSignaling(sessionId: sessionId, participantId: hostId)

        // 广播房间创建事件
        if let signaling = signalingService {
            _ = try? await signaling.createRoom(session: session)
        }

        // 创建 DataChannel（房主作为主动方）
        // TODO: 建立 WebRTC PeerConnection 并创建 DataChannel
        await createDataChannelsForHost()

        // 更新会话状态
        lock.lock()
        var updatedSession = session
        updatedSession.state = .active
        mode = .host(session: updatedSession)
        lock.unlock()

        // 通知回调
        onSessionCreated?(updatedSession)

        return updatedSession
    }

    /// 加入会议室（参与者）
    /// - Parameters:
    ///   - sessionId: 会话 ID
    ///   - displayName: 显示名
    ///   - preferredLanguage: 首选语言
    ///   - password: 密码（如果需要）
    /// - Returns: 是否加入成功
    func joinSession(
        sessionId: String,
        displayName: String,
        preferredLanguage: String = "zh",
        preferredLanguageName: String = "中文",
        password: String = ""
    ) async throws -> Bool {
        // 创建参与者
        let participantId = String.participantId()
        let participant = P2PParticipant(
            participantId: participantId,
            displayName: displayName,
            preferredLanguage: preferredLanguage,
            preferredLanguageName: preferredLanguageName,
            role: .participant,
            avatarColor: randomAvatarColor()
        )

        localParticipant = participant

        // 连接信令服务
        try await connectSignaling(sessionId: sessionId, participantId: participantId)

        // 发送加入请求
        guard let signaling = signalingService else {
            throw P2PError.joinFailed(reason: "信令服务未连接")
        }

        // TODO: 验证房间密码（如果需要）
        if !password.isEmpty {
            // 密码验证逻辑
            // 在实际实现中，信令服务器会验证密码
        }

        // 加入房间
        let existingParticipants = try await signaling.joinRoom(sessionId: sessionId, participantInfo: participant)

        // 设置参与者管理器
        participantManager.setSession(sessionId)
        participantManager.addParticipant(participant)

        // 添加房间中的现有参与者
        for existing in existingParticipants {
            if existing.participantId != participantId {
                participantManager.addParticipant(existing)
                // TODO: 与现有参与者建立 WebRTC 连接
                await establishConnectionWithPeer(peerId: existing.participantId)
            }
        }

        // 设置模式
        // 获取会话信息
        // TODO: 从信令服务器获取完整会话信息
        let session = P2PSession(
            sessionId: sessionId,
            hostId: existingParticipants.first?.participantId ?? "",
            hostName: existingParticipants.first?.displayName ?? "Unknown",
            participants: existingParticipants + [participant],
            sourceLanguage: "en",
            state: .active
        )

        lock.lock()
        mode = .participant(session: session)
        lock.unlock()

        isConnected = true

        // 通知回调
        onSessionJoined?(session)

        return true
    }

    /// 离开当前会话
    func leaveSession() async {
        guard let session = currentSession else { return }

        lock.lock()
        let participantId = localParticipant?.participantId ?? ""
        lock.unlock()

        // 发送离开消息
        if let signaling = signalingService {
            await signaling.leaveRoom(sessionId: session.sessionId)
            await signaling.disconnect()
        }

        // 关闭所有 DataChannel
        await closeAllDataChannels()

        // 关闭所有 PeerConnection
        await closeAllPeerConnections()

        // 清空状态
        participantManager.clearSession()
        signalingService = nil
        localParticipant = nil
        isConnected = false

        lock.lock()
        mode = .disabled
        lock.unlock()

        // 通知回调
        onSessionEnded?(session.sessionId)
    }

    /// 广播转录片段到所有参与者
    /// 由 InterpreterPipeline 调用，将 Whisper 转录结果通过 DataChannel 广播
    /// - Parameter segment: 转录片段
    func broadcastSegment(_ segment: TranscriptionMessage) async {
        guard isInP2PMode else { return }

        // 将转录消息编码为 DataChannel 消息
        let message = P2PDataMessage.transcription(segment)

        // 通过 DataChannel 广播
        await broadcastDataMessage(message)

        // 通过 ParticipantManager 分发翻译字幕
        await participantManager.distributeSubtitle(
            segment: segment,
            sourceLanguage: segment.senderId == localParticipant?.participantId ? "en" : "en",
            chunkIndex: segment.chunkIndex,
            isFinal: true,
            speakerLabel: segment.speakerLabel,
            senderId: segment.senderId
        )
    }

    /// 广播部分转录（实时上屏）
    /// - Parameters:
    ///   - text: 部分转录文本
    ///   - chunkIndex: 片段索引
    ///   - senderId: 发送者 ID
    func broadcastPartialTranscription(text: String, chunkIndex: Int, senderId: String) async {
        guard isInP2PMode else { return }

        let partialSegment = TranscriptionMessage(
            senderId: senderId,
            sessionId: currentSession?.sessionId ?? "",
            text: text,
            confidence: 0.0,
            chunkIndex: chunkIndex,
            startTimestamp: mach_absolute_time(),
            durationSeconds: 0,
            speakerLabel: nil
        )

        let message = P2PDataMessage.transcription(partialSegment)
        await broadcastDataMessage(message)
    }

    /// 发送翻译字幕到指定参与者
    /// - Parameters:
    ///   - translation: 翻译消息
    ///   - speakerLabel: 说话人标签
    func sendTranslation(to translation: TranslationMessage, speakerLabel: String?) async {
        let message = P2PDataMessage.translation(translation)
        await sendDataMessage(message, to: translation.targetId)
        participantManager.deliverTranslation(translation, speakerLabel: speakerLabel)
    }

    // MARK: - DataChannel Message Broadcasting

    /// 广播 DataChannel 消息到所有已连接的对等方
    /// - Parameter message: P2P 数据消息
    private func broadcastDataMessage(_ message: P2PDataMessage) async {
        guard let data = try? JSONEncoder().encode(message) else { return }

        lock.lock()
        let channels = dataChannels
        lock.unlock()

        for (peerId, channel) in channels {
            // TODO: 调用真实的 DataChannel send 方法
            // channel.send(data)
            print("[P2PSessionManager] 广播消息到 \(peerId): \(data.count) bytes")
        }
    }

    /// 发送 DataChannel 消息到指定对等方
    /// - Parameters:
    ///   - message: P2P 数据消息
    ///   - targetId: 目标参与者 ID
    private func sendDataMessage(_ message: P2PDataMessage, to targetId: String) async {
        guard let data = try? JSONEncoder().encode(message) else { return }

        lock.lock()
        let channel = dataChannels[targetId]
        lock.unlock()

        if channel != nil {
            // TODO: 调用真实的 DataChannel send 方法
            // channel.send(data)
            print("[P2PSessionManager] 发送消息到 \(targetId): \(data.count) bytes")
        }
    }

    // MARK: - Private: Connection Management

    private func connectSignaling(sessionId: String, participantId: String) async throws {
        let signaling = SignalingService.create(config: config)

        signaling.delegate = self
        signalingService = signaling

        try await signaling.connect(
            serverURL: config.signalingServerURL,
            sessionId: sessionId,
            participantId: participantId
        )
    }

    /// 为房主创建 DataChannel
    /// 房主模式下，所有参与者的 DataChannel 都由房主发起
    private func createDataChannelsForHost() async {
        // TODO: 创建 WebRTC PeerConnection 并打开 DataChannel
        // 这是 Pilot 架构占位，实际实现需要集成 WebRTC SDK
        print("[P2PSessionManager] TODO: 创建 WebRTC DataChannel（房主模式）")
    }

    /// 与对等方建立 WebRTC 连接
    /// - Parameter peerId: 对等方 ID
    private func establishConnectionWithPeer(peerId: String) async {
        // TODO: 建立 WebRTC PeerConnection
        // 1. 创建 RTCPeerConnection
        // 2. 创建 DataChannel
        // 3. 交换 SDP offer/answer
        // 4. 交换 ICE candidates
        print("[P2PSessionManager] TODO: 与 \(peerId) 建立 WebRTC 连接")
    }

    /// 关闭所有 DataChannel
    private func closeAllDataChannels() async {
        lock.lock()
        let channels = dataChannels
        dataChannels.removeAll()
        lock.unlock()

        for (_, channel) in channels {
            // TODO: 关闭 DataChannel
            // channel.close()
        }
    }

    /// 关闭所有 PeerConnection
    private func closeAllPeerConnections() async {
        lock.lock()
        let connections = peerConnections
        peerConnections.removeAll()
        lock.unlock()

        for (_, connection) in connections {
            // TODO: 关闭 PeerConnection
            // connection.close()
        }
    }

    // MARK: - Participant Management Helpers

    /// 处理收到的参与者加入消息
    private func handleParticipantJoined(_ participant: P2PParticipant) {
        participantManager.addParticipant(participant)
        onParticipantJoined?(participant)

        // TODO: 与新参与者建立 WebRTC 连接（仅房主）
        if case .host = currentMode {
            Task {
                await establishConnectionWithPeer(peerId: participant.participantId)
            }
        }
    }

    /// 处理收到的参与者离开消息
    private func handleParticipantLeft(_ participantId: String) {
        participantManager.removeParticipant(participantId)

        // 关闭与该参与者的连接
        lock.lock()
        dataChannels.removeValue(forKey: participantId)
        peerConnections.removeValue(forKey: participantId)
        lock.unlock()

        onParticipantLeft?(participantId)
    }

    // MARK: - Utility

    private func randomAvatarColor() -> String {
        let colors = ["#E74C3C", "#9B59B6", "#3498DB", "#1ABC9C", "#27AE60", "#F39C12", "#E91E63", "#00BCD4"]
        return colors.randomElement() ?? "#4A90E2"
    }

    // MARK: - Callbacks Setup

    func setSessionCreatedHandler(_ handler: @escaping (P2PSession) -> Void) {
        onSessionCreated = handler
    }

    func setSessionJoinedHandler(_ handler: @escaping (P2PSession) -> Void) {
        onSessionJoined = handler
    }

    func setSessionEndedHandler(_ handler: @escaping (String) -> Void) {
        onSessionEnded = handler
    }

    func setParticipantJoinedHandler(_ handler: @escaping (P2PParticipant) -> Void) {
        onParticipantJoined = handler
    }

    func setParticipantLeftHandler(_ handler: @escaping (String) -> Void) {
        onParticipantLeft = handler
    }

    func setErrorHandler(_ handler: @escaping (P2PError) -> Void) {
        onError = handler
    }

    func setSubtitleReceivedHandler(_ handler: @escaping (SubtitleUpdateMessage) -> Void) {
        onSubtitleReceived = handler
    }
}

// MARK: - SignalingServiceDelegate

extension P2PSessionManager: SignalingServiceDelegate {

    func signalingService(_ service: SignalingService, didReceiveSDPOffer offer: SDPOfferMessage) {
        // TODO: 处理收到的 SDP Offer
        // 1. 创建 RTCPeerConnectionAnswer
        // 2. 设置远程 SDP
        // 3. 发送 Answer
        print("[P2PSessionManager] 收到 SDP Offer from \(offer.senderId)")
    }

    func signalingService(_ service: SignalingService, didReceiveSDPAnswer answer: SDPAnswerMessage) {
        // TODO: 处理收到的 SDP Answer
        // 设置远程 SDP
        print("[P2PSessionManager] 收到 SDP Answer from \(answer.senderId)")
    }

    func signalingService(_ service: SignalingService, didReceiveICECandidate candidate: ICECandidateMessage) {
        // TODO: 处理收到的 ICE Candidate
        // 添加到 RTCPeerConnection
        print("[P2PSessionManager] 收到 ICE Candidate from \(candidate.senderId)")
    }

    func signalingService(_ service: SignalingService, didReceiveRoomEvent event: RoomEventMessage) {
        // 处理房间事件
        switch event.eventType {
        case .userJoined:
            // 解析参与者信息
            if let data = event.data,
               let jsonData = data.data(using: .utf8),
               let participant = try? JSONDecoder().decode(P2PParticipant.self, from: jsonData) {
                handleParticipantJoined(participant)
            }

        case .userLeft:
            handleParticipantLeft(event.senderId)

        case .hostChanged:
            // 房主变更
            lock.lock()
            if case .participant(var session) = mode {
                session = P2PSession(
                    sessionId: session.sessionId,
                    hostId: event.senderId,
                    hostName: event.data ?? "Unknown",
                    participants: session.participants,
                    sourceLanguage: session.sourceLanguage,
                    state: session.state,
                    isPrivate: session.isPrivate,
                    roomPassword: session.roomPassword,
                    topic: session.topic
                )
                mode = .participant(session: session)
            }
            lock.unlock()

        case .sessionStarted:
            lock.lock()
            if case .participant(var session) = mode {
                var updated = session
                updated.state = .active
                mode = .participant(session: updated)
            }
            lock.unlock()

        case .sessionEnded:
            Task {
                await leaveSession()
            }

        case .userListUpdated:
            // 用户列表更新，重新获取
            break
        }
    }

    func signalingService(_ service: SignalingService, didChangeState state: SignalingConnectionState) {
        switch state {
        case .connected:
            isConnected = true
        case .disconnected, .reconnecting:
            isConnected = false
        case .failed(let reason):
            onError?(P2PError.signalingConnectionFailed(reason: reason))
        case .connecting:
            break
        }
    }

    func signalingService(_ service: SignalingService, didEncounterError error: Error) {
        if let p2pError = error as? P2PError {
            onError?(p2pError)
        } else {
            onError?(P2PError.signalingConnectionFailed(reason: error.localizedDescription))
        }
    }
}

// MARK: - DataChannel 消息处理扩展

extension P2PSessionManager {
    /// 处理收到的 DataChannel 消息
    /// - Parameters:
    ///   - data: 消息数据
    ///   - senderId: 发送者 ID
    private func handleDataChannelMessage(_ data: Data, from senderId: String) {
        guard let message = try? JSONDecoder().decode(P2PDataMessage.self, from: data) else {
            print("[P2PSessionManager] 无法解析 DataChannel 消息")
            return
        }

        Task { @MainActor in
            switch message {
            case .transcription(let segment):
                // 收到转录，翻译并分发
                await participantManager.distributeSubtitle(
                    segment: segment,
                    chunkIndex: segment.chunkIndex,
                    isFinal: true,
                    speakerLabel: segment.speakerLabel,
                    senderId: senderId
                )

            case .translation(let translation):
                // 收到翻译，直接发送给目标 participant
                participantManager.deliverTranslation(translation, speakerLabel: nil)

            case .subtitleUpdate(let update):
                // 收到字幕更新，转发给对应 participant
                onSubtitleReceived?(update)

            case .participantUpdate(let update):
                handleParticipantUpdate(update)

            case .speechState(let state):
                // 处理讲话状态变化
                print("[P2PSessionManager] \(state.senderId) 讲话状态: \(state.isSpeaking)")

            case .heartbeat(let heartbeat):
                // 处理心跳
                print("[P2PSessionManager] 收到心跳 from \(heartbeat.senderId)")

            case .sessionControl(let control):
                handleSessionControl(control)
            }
        }
    }

    private func handleParticipantUpdate(_ update: ParticipantUpdateMessage) {
        switch update.updateType {
        case .languageChanged:
            if let data = update.extraData?.data(using: .utf8),
               let info = try? JSONDecoder().decode([String: String].self, from: data),
               let lang = info["language"],
               let name = info["languageName"] {
                participantManager.updateParticipantLanguage(
                    update.participantId,
                    language: lang,
                    languageName: name
                )
            }

        case .networkQualityChanged:
            if let data = update.extraData?.data(using: .utf8),
               let qualityRaw = try? JSONDecoder().decode(String.self, from: data),
               let quality = P2PNetworkQuality(rawValue: qualityRaw) {
                participantManager.updateParticipant(
                    update.participantId,
                    updates: Partial(
                        P2PParticipant(
                            participantId: update.participantId,
                            displayName: ""
                        )
                    )
                )
            }

        default:
            break
        }
    }

    private func handleSessionControl(_ control: SessionControlMessage) {
        switch control.controlType {
        case .endSession:
            Task {
                await leaveSession()
            }

        case .muteAll:
            // 通知所有参与者静音
            participantManager.updateParticipant(
                localParticipant?.participantId ?? "",
                updates: Partial(
                    P2PParticipant(
                        participantId: localParticipant?.participantId ?? "",
                        displayName: ""
                    )
                )
            )

        case .kickParticipant:
            if let params = control.params?.data(using: .utf8),
               let kickId = try? JSONDecoder().decode(String.self, from: params),
               kickId == localParticipant?.participantId {
                Task {
                    await leaveSession()
                }
            }

        default:
            break
        }
    }
}
