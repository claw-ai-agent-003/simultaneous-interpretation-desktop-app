import Foundation

// ============================================================
// MARK: - P2P Session & Participant Models
// ============================================================
// P4.2: 多人会议共享 — 数据模型
// 隐私策略：只传输转录+翻译文本，不传输原始音频
// ============================================================

/// P2P 会议室会话
/// 代表一个共享会议室，包含房主和所有参与者
struct P2PSession: Identifiable, Codable, Sendable {
    /// 会话唯一标识符
    let sessionId: String

    /// 房主（会议室创建者）的用户 ID
    let hostId: String

    /// 房主显示名
    let hostName: String

    /// 当前参与者列表
    var participants: [P2PParticipant]

    /// 会话创建时间
    let createdAt: Date

    /// 会话语言（源语言，BCP-47）
    let sourceLanguage: String

    /// 会话状态
    var state: P2PSessionState

    /// 预计持续时间（秒），0 表示无限制
    var durationSeconds: Int

    /// 是否为私密房间（需要密码）
    var isPrivate: Bool

    /// 房间密码（仅在 isPrivate=true 时有效，空字符串表示无密码）
    var roomPassword: String

    /// 会话名称/主题
    var topic: String

    init(
        sessionId: String,
        hostId: String,
        hostName: String,
        participants: [P2PParticipant] = [],
        createdAt: Date = Date(),
        sourceLanguage: String = "en",
        state: P2PSessionState = .waiting,
        durationSeconds: Int = 0,
        isPrivate: Bool = false,
        roomPassword: String = "",
        topic: String = ""
    ) {
        self.sessionId = sessionId
        self.hostId = hostId
        self.hostName = hostName
        self.participants = participants
        self.createdAt = createdAt
        self.sourceLanguage = sourceLanguage
        self.state = state
        self.durationSeconds = durationSeconds
        self.isPrivate = isPrivate
        self.roomPassword = roomPassword
        self.topic = topic
    }
}

/// P2P 会话状态
enum P2PSessionState: String, Codable, Sendable {
    /// 等待参与者加入
    case waiting = "waiting"

    /// 会议进行中
    case active = "active"

    /// 会议已结束
    case ended = "ended"

    /// 会议已暂停
    case paused = "paused"
}

// ============================================================
// MARK: - Participant
// ============================================================

/// P2P 会议室参与者
struct P2PParticipant: Identifiable, Codable, Sendable, Equatable {
    /// 参与者唯一标识
    let participantId: String

    /// 显示名称
    var displayName: String

    /// 首选语言（BCP-47），字幕将翻译至此语言
    var preferredLanguage: String

    /// 首选语言显示名（如 "中文"）
    var preferredLanguageName: String

    /// 加入时间
    let joinedAt: Date

    /// 角色
    var role: P2PParticipantRole

    /// 网络状态
    var networkQuality: P2PNetworkQuality

    /// 是否正在接收音频（耳机图标状态）
    var isReceivingAudio: Bool

    /// 是否为静音状态
    var isMuted: Bool

    /// 头像颜色（用于 UI 显示）
    var avatarColor: String

    init(
        participantId: String,
        displayName: String,
        preferredLanguage: String = "zh",
        preferredLanguageName: String = "中文",
        joinedAt: Date = Date(),
        role: P2PParticipantRole = .participant,
        networkQuality: P2PNetworkQuality = .good,
        isReceivingAudio: Bool = true,
        isMuted: Bool = false,
        avatarColor: String = "#4A90E2"
    ) {
        self.participantId = participantId
        self.displayName = displayName
        self.preferredLanguage = preferredLanguage
        self.preferredLanguageName = preferredLanguageName
        self.joinedAt = joinedAt
        self.role = role
        self.networkQuality = networkQuality
        self.isReceivingAudio = isReceivingAudio
        self.isMuted = isMuted
        self.avatarColor = avatarColor
    }

    static func == (lhs: P2PParticipant, rhs: P2PParticipant) -> Bool {
        lhs.participantId == rhs.participantId
    }
}

/// 参与者角色
enum P2PParticipantRole: String, Codable, Sendable {
    /// 房主/主持人
    case host = "host"

    /// 普通参与者
    case participant = "participant"

    /// 翻译员（可听音频并转写）
    case interpreter = "interpreter"

    /// 观察者（只能看字幕）
    case observer = "observer"
}

/// 网络质量等级
enum P2PNetworkQuality: String, Codable, Sendable {
    /// 优秀
    case excellent = "excellent"

    /// 良好
    case good = "good"

    /// 一般
    case fair = "fair"

    /// 较差
    case poor = "poor"

    /// 未知
    case unknown = "unknown"

    /// 颜色表示（用于 UI）
    var colorHex: String {
        switch self {
        case .excellent: return "#00C853"  // 绿色
        case .good: return "#8BC34A"        // 浅绿
        case .fair: return "#FFC107"        // 黄色
        case .poor: return "#FF5722"        // 橙色
        case .unknown: return "#9E9E9E"     // 灰色
        }
    }
}

// ============================================================
// MARK: - P2P Messages (DataChannel 传输)
// ============================================================

/// P2P DataChannel 传输的消息类型
/// 注意：只传输文本（转录+翻译），不传输原始音频
enum P2PDataMessage: Codable, Sendable {
    /// 转录片段（房主/翻译员产生）
    case transcription(TranscriptionMessage)

    /// 翻译片段（分发到各参与者）
    case translation(TranslationMessage)

    /// 字幕更新（实时推送到各 participant 的 overlay）
    case subtitleUpdate(SubtitleUpdateMessage)

    /// 参与者状态变更
    case participantUpdate(ParticipantUpdateMessage)

    /// 房主开始/停止讲话
    case speechState(SpeechStateMessage)

    /// 心跳/保活
    case heartbeat(HeartbeatMessage)

    /// 会话控制（静音、离开等）
    case sessionControl(SessionControlMessage)
}

/// 房主/翻译员的转录消息
struct TranscriptionMessage: Codable, Sendable {
    /// 发送者 participantId
    let senderId: String

    /// 会话 ID
    let sessionId: String

    /// 转录文本（英文）
    let text: String

    /// 置信度
    let confidence: Float

    /// 片段索引
    let chunkIndex: Int

    /// 片段开始时间戳
    let startTimestamp: UInt64

    /// 片段持续时间（秒）
    let durationSeconds: Double

    /// 说话人标签（如果有）
    var speakerLabel: String?

    /// 发送时间
    let sentAt: Date

    init(
        senderId: String,
        sessionId: String,
        text: String,
        confidence: Float,
        chunkIndex: Int,
        startTimestamp: UInt64,
        durationSeconds: Double,
        speakerLabel: String? = nil,
        sentAt: Date = Date()
    ) {
        self.senderId = senderId
        self.sessionId = sessionId
        self.text = text
        self.confidence = confidence
        self.chunkIndex = chunkIndex
        self.startTimestamp = startTimestamp
        self.durationSeconds = durationSeconds
        self.speakerLabel = speakerLabel
        self.sentAt = sentAt
    }
}

/// 翻译消息（房主广播给特定 participant）
struct TranslationMessage: Codable, Sendable {
    /// 发送者 participantId
    let senderId: String

    /// 目标 participantId（空字符串表示广播给所有人）
    let targetId: String

    /// 会话 ID
    let sessionId: String

    /// 翻译后的文本
    let translatedText: String

    /// 目标语言
    let targetLanguage: String

    /// 对应的原始转录文本
    let originalText: String

    /// 片段索引
    let chunkIndex: Int

    /// 发送时间
    let sentAt: Date

    init(
        senderId: String,
        targetId: String,
        sessionId: String,
        translatedText: String,
        targetLanguage: String,
        originalText: String,
        chunkIndex: Int,
        sentAt: Date = Date()
    ) {
        self.senderId = senderId
        self.targetId = targetId
        self.sessionId = sessionId
        self.translatedText = translatedText
        self.targetLanguage = targetLanguage
        self.originalText = originalText
        self.chunkIndex = chunkIndex
        self.sentAt = sentAt
    }
}

/// 字幕更新消息（实时推送到 participant overlay）
struct SubtitleUpdateMessage: Codable, Sendable {
    /// 发送者 participantId
    let senderId: String

    /// 会话 ID
    let sessionId: String

    /// 原始英文
    let english: String

    /// 目标语言翻译
    let translated: String

    /// 目标语言
    let targetLanguage: String

    /// 是否为最终结果（false=partial，true=final）
    let isFinal: Bool

    /// 片段索引
    let chunkIndex: Int

    /// 说话人标签（如果有）
    var speakerLabel: String?

    /// 发送时间
    let sentAt: Date

    init(
        senderId: String,
        sessionId: String,
        english: String,
        translated: String,
        targetLanguage: String,
        isFinal: Bool,
        chunkIndex: Int,
        speakerLabel: String? = nil,
        sentAt: Date = Date()
    ) {
        self.senderId = senderId
        self.sessionId = sessionId
        self.english = english
        self.translated = translated
        self.targetLanguage = targetLanguage
        self.isFinal = isFinal
        self.chunkIndex = chunkIndex
        self.speakerLabel = speakerLabel
        self.sentAt = sentAt
    }
}

/// 参与者状态更新消息
struct ParticipantUpdateMessage: Codable, Sendable {
    /// 被更新的参与者 ID
    let participantId: String

    /// 会话 ID
    let sessionId: String

    /// 更新类型
    let updateType: ParticipantUpdateType

    /// 额外数据（JSON 字符串，灵活扩展）
    var extraData: String?

    /// 发送时间
    let sentAt: Date

    init(
        participantId: String,
        sessionId: String,
        updateType: ParticipantUpdateType,
        extraData: String? = nil,
        sentAt: Date = Date()
    ) {
        self.participantId = participantId
        self.sessionId = sessionId
        self.updateType = updateType
        self.extraData = extraData
        self.sentAt = sentAt
    }
}

/// 参与者更新类型
enum ParticipantUpdateType: String, Codable, Sendable {
    /// 加入会话
    case joined = "joined"

    /// 离开会话
    case left = "left"

    /// 语言变更
    case languageChanged = "language_changed"

    /// 网络质量变化
    case networkQualityChanged = "network_quality_changed"

    /// 静音状态变化
    case muteStateChanged = "mute_state_changed"

    /// 角色变化
    case roleChanged = "role_changed"
}

/// 讲话状态消息
struct SpeechStateMessage: Codable, Sendable {
    /// 发送者 participantId
    let senderId: String

    /// 会话 ID
    let sessionId: String

    /// 是否正在讲话
    let isSpeaking: Bool

    /// 发送时间
    let sentAt: Date

    init(senderId: String, sessionId: String, isSpeaking: Bool, sentAt: Date = Date()) {
        self.senderId = senderId
        self.sessionId = sessionId
        self.isSpeaking = isSpeaking
        self.sentAt = sentAt
    }
}

/// 心跳消息
struct HeartbeatMessage: Codable, Sendable {
    /// 发送者 participantId
    let senderId: String

    /// 会话 ID
    let sessionId: String

    /// 客户端时间戳
    let clientTimestamp: UInt64

    /// 发送时间
    let sentAt: Date

    init(senderId: String, sessionId: String, clientTimestamp: UInt64 = mach_absolute_time(), sentAt: Date = Date()) {
        self.senderId = senderId
        self.sessionId = sessionId
        self.clientTimestamp = clientTimestamp
        self.sentAt = sentAt
    }
}

/// 会话控制消息
struct SessionControlMessage: Codable, Sendable {
    /// 发送者 participantId
    let senderId: String

    /// 会话 ID
    let sessionId: String

    /// 控制类型
    let controlType: SessionControlType

    /// 额外参数（JSON 字符串）
    var params: String?

    /// 发送时间
    let sentAt: Date

    init(
        senderId: String,
        sessionId: String,
        controlType: SessionControlType,
        params: String? = nil,
        sentAt: Date = Date()
    ) {
        self.senderId = senderId
        self.sessionId = sessionId
        self.controlType = controlType
        self.params = params
        self.sentAt = sentAt
    }
}

/// 会话控制类型
enum SessionControlType: String, Codable, Sendable {
    /// 房主开始会议
    case startSession = "start_session"

    /// 房主结束会议
    case endSession = "end_session"

    /// 参与者请求加入
    case joinRequest = "join_request"

    /// 房主批准加入
    case joinApproved = "join_approved"

    /// 房主拒绝加入
    case joinRejected = "join_rejected"

    /// 参与者离开
    case leaveSession = "leave_session"

    /// 全部静音（房主操作）
    case muteAll = "mute_all"

    /// 取消全部静音
    case unmuteAll = "unmute_all"

    /// 踢出参与者
    case kickParticipant = "kick_participant"
}

// ============================================================
// MARK: - WebRTC Signaling Models
// ============================================================

/// WebRTC 信令消息（通过 WebSocket 传输）
enum SignalingMessage: Codable, Sendable {
    /// SDP Offer
    case sdpOffer(SDPOfferMessage)

    /// SDP Answer
    case sdpAnswer(SDPAnswerMessage)

    /// ICE Candidate
    case iceCandidate(ICECandidateMessage)

    /// 房间事件
    case roomEvent(RoomEventMessage)

    /// 错误
    case error(SignalingErrorMessage)
}

/// SDP Offer 消息
struct SDPOfferMessage: Codable, Sendable {
    /// 发送者 ID
    let senderId: String

    /// 目标 ID
    let targetId: String

    /// 会话 ID
    let sessionId: String

    /// SDP offer 字符串
    let sdp: String

    /// SDP 类型（通常为 "offer"）
    let type: String

    init(senderId: String, targetId: String, sessionId: String, sdp: String, type: String = "offer") {
        self.senderId = senderId
        self.targetId = targetId
        self.sessionId = sessionId
        self.sdp = sdp
        self.type = type
    }
}

/// SDP Answer 消息
struct SDPAnswerMessage: Codable, Sendable {
    /// 发送者 ID
    let senderId: String

    /// 目标 ID
    let targetId: String

    /// 会话 ID
    let sessionId: String

    /// SDP answer 字符串
    let sdp: String

    /// SDP 类型（通常为 "answer"）
    let type: String

    init(senderId: String, targetId: String, sessionId: String, sdp: String, type: String = "answer") {
        self.senderId = senderId
        self.targetId = targetId
        self.sessionId = sessionId
        self.sdp = sdp
        self.type = type
    }
}

/// ICE Candidate 消息
struct ICECandidateMessage: Codable, Sendable {
    /// 发送者 ID
    let senderId: String

    /// 目标 ID
    let targetId: String

    /// 会话 ID
    let sessionId: String

    /// ICE candidate 类型（"candidate"）
    let type: String

    /// 候选协议（"udp" / "tcp"）
    let protocol_: String

    /// 优先级
    let priority: Int

    /// 候选 IP 地址
    let ip: String

    /// 候选端口
    let port: Int

    /// 候选类型（"host" / "srflx" / "relay"）
    let candidateType: String

    /// 相关地址（对于 srflx/relay 类型）
    var relatedAddress: String?

    /// 相关端口
    var relatedPort: Int?

    /// 完整 candidate 字符串（用于调试）
    var candidateString: String?

    enum CodingKeys: String, CodingKey {
        case senderId, targetId, sessionId, type, protocol_ = "protocol"
        case priority, ip, port, candidateType
        case relatedAddress, relatedPort, candidateString
    }
}

/// 房间事件消息
struct RoomEventMessage: Codable, Sendable {
    /// 事件类型
    let eventType: RoomEventType

    /// 会话 ID
    let sessionId: String

    /// 发送者 ID
    let senderId: String

    /// 事件数据（JSON 字符串）
    var data: String?

    /// 时间戳
    let timestamp: Date
}

/// 房间事件类型
enum RoomEventType: String, Codable, Sendable {
    /// 用户加入
    case userJoined = "user_joined"

    /// 用户离开
    case userLeft = "user_left"

    /// 房主变更
    case hostChanged = "host_changed"

    /// 会话开始
    case sessionStarted = "session_started"

    /// 会话结束
    case sessionEnded = "session_ended"

    /// 用户列表更新
    case userListUpdated = "user_list_updated"
}

/// 信令错误消息
struct SignalingErrorMessage: Codable, Sendable {
    /// 错误码
    let code: Int

    /// 错误描述
    let message: String

    /// 会话 ID
    let sessionId: String?

    /// 发送时间
    let timestamp: Date
}

// ============================================================
// MARK: - P2P Configuration
// ============================================================

/// P2P 功能配置
struct P2PConfig: Sendable {
    /// 信令服务器地址
    /// TODO: 实际部署时替换为真实服务器地址
    /// 支持格式: "wss://your-signaling-server.com" 或 "ws://localhost:8080"
    var signalingServerURL: String = "wss://signaling.example.com"

    /// 是否使用 Firebase Realtime Database 作为信令后端（备选）
    var useFirebaseSignaling: Bool = false

    /// Firebase 项目 ID（当 useFirebaseSignaling=true 时）
    var firebaseProjectId: String = ""

    /// 是否使用 Supabase Realtime 作为信令后端（备选）
    var useSupabaseSignaling: Bool = false

    /// Supabase 项目 URL（当 useSupabaseSignaling=true 时）
    var supabaseURL: String = ""

    /// Supabase anon key
    var supabaseAnonKey: String = ""

    /// ICE 服务器列表
    var iceServers: [ICEServerConfig] = [
        ICEServerConfig(urls: ["stun:stun.l.google.com:19302"]),
        ICEServerConfig(urls: ["stun:stun1.l.google.com:19302"])
    ]

    /// DataChannel 标签
    var dataChannelLabel: String = "simultaneous-interpreter-p2p"

    /// 心跳间隔（秒）
    var heartbeatIntervalSeconds: Double = 30.0

    /// 心跳超时（秒）
    var heartbeatTimeoutSeconds: Double = 90.0

    /// 最大参与者数量
    var maxParticipants: Int = 10

    /// 允许观察者模式（不发送音频，只看字幕）
    var allowObserverMode: Bool = true

    /// 是否启用音频传输（默认关闭，隐私优先）
    var audioTranscriptionModeOnly: Bool = true

    init() {}
}

/// ICE 服务器配置
struct ICEServerConfig: Sendable, Codable {
    let urls: [String]
    var username: String?
    var credential: String?
}

// ============================================================
// MARK: - P2P Session Error
// ============================================================

/// P2P 相关错误
enum P2PError: Error, LocalizedError, Sendable {
    /// 会话不存在
    case sessionNotFound(sessionId: String)

    /// 会话已满
    case sessionFull(maxParticipants: Int)

    /// 无权操作（非房主尝试房主操作）
    case notAuthorized

    /// 加入失败
    case joinFailed(reason: String)

    /// 离开失败
    case leaveFailed(reason: String)

    /// 信令连接失败
    case signalingConnectionFailed(reason: String)

    /// WebRTC 连接失败
    case webrtcConnectionFailed(reason: String)

    /// DataChannel 错误
    case dataChannelError(reason: String)

    /// 密码错误
    case invalidPassword

    /// 参与者不在线
    case participantNotOnline(participantId: String)

    /// 翻译失败
    case translationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "会话不存在: \(id)"
        case .sessionFull(let max):
            return "会话已满，最多 \(max) 人"
        case .notAuthorized:
            return "无权执行此操作"
        case .joinFailed(let reason):
            return "加入失败: \(reason)"
        case .leaveFailed(let reason):
            return "离开失败: \(reason)"
        case .signalingConnectionFailed(let reason):
            return "信令连接失败: \(reason)"
        case .webrtcConnectionFailed(let reason):
            return "WebRTC 连接失败: \(reason)"
        case .dataChannelError(let reason):
            return "DataChannel 错误: \(reason)"
        case .invalidPassword:
            return "密码错误"
        case .participantNotOnline(let id):
            return "参与者不在线: \(id)"
        case .translationFailed(let reason):
            return "翻译失败: \(reason)"
        }
    }
}

// ============================================================
// MARK: - Helper
// ============================================================

/// 生成唯一会话 ID
extension String {
    static func p2pSessionId() -> String {
        "p2p-\(UUID().uuidString.prefix(12))"
    }

    /// 生成唯一参与者 ID
    static func participantId() -> String {
        "p-\(UUID().uuidString.prefix(8))"
    }
}
