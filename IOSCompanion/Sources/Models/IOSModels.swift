import Foundation

// MARK: - 消息类型枚举
/// WiFi 同步消息类型
/// 用于 Mac → iPhone 数据传输的 JSON 消息类型标识
enum SyncMessageType: String, Codable, Sendable {
    /// 实时翻译片段 - 包含一段转录和翻译文本
    case liveSegment = "liveSegment"
    /// 会议结束信号
    case sessionEnd = "sessionEnd"
    /// 会议摘要 - AI 生成的关键信息
    case meetingBrief = "meetingBrief"
    /// 心跳保活消息
    case heartbeat = "heartbeat"
}

// MARK: - 实时翻译片段消息
/// 接收自 Mac 端的实时翻译片段
/// 每次说话内容分段发送，iPhone 端按顺序拼接显示
struct LiveSegmentMessage: Codable, Sendable {
    let type: SyncMessageType
    let sessionId: String        /// 会议会话唯一标识
    let timestamp: TimeInterval  /// 片段时间戳（相对于会话开始）
    let originalText: String     /// 原文（源语言）
    let translatedText: String   /// 译文（目标语言）
    let speakerName: String?     /// 说话人名称（可选）
    let segmentIndex: Int        /// 片段序号，用于顺序拼接

    init(
        type: SyncMessageType = .liveSegment,
        sessionId: String,
        timestamp: TimeInterval,
        originalText: String,
        translatedText: String,
        speakerName: String? = nil,
        segmentIndex: Int
    ) {
        self.type = type
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.originalText = originalText
        self.translatedText = translatedText
        self.speakerName = speakerName
        self.segmentIndex = segmentIndex
    }
}

// MARK: - 会议结束消息
/// Mac 端发送的会议结束信号
/// 收到后 iPhone 端保存完整会议记录
struct SessionEndMessage: Codable, Sendable {
    let type: SyncMessageType
    let sessionId: String
    let endTime: TimeInterval    /// 会议结束绝对时间戳
    let totalDuration: TimeInterval /// 会议总时长（秒）

    init(
        type: SyncMessageType = .sessionEnd,
        sessionId: String,
        endTime: TimeInterval,
        totalDuration: TimeInterval
    ) {
        self.type = type
        self.sessionId = sessionId
        self.endTime = endTime
        self.totalDuration = totalDuration
    }
}

// MARK: - 会议摘要消息
/// Mac 端 AI 生成并发送的会议摘要
struct MeetingBriefMessage: Codable, Sendable {
    let type: SyncMessageType
    let sessionId: String
    let summary: String                  /// 会议总体摘要
    let keyTopics: [String]               /// 关键议题列表
    let actionItems: [String]             /// 后续行动项列表
    let participants: [String]            /// 参会人员列表
    let generatedAt: TimeInterval         /// 摘要生成时间

    init(
        type: SyncMessageType = .meetingBrief,
        sessionId: String,
        summary: String,
        keyTopics: [String],
        actionItems: [String],
        participants: [String],
        generatedAt: TimeInterval
    ) {
        self.type = type
        self.sessionId = sessionId
        self.summary = summary
        self.keyTopics = keyTopics
        self.actionItems = actionItems
        self.participants = participants
        self.generatedAt = generatedAt
    }
}

// MARK: - 心跳消息
/// 用于保持连接活跃的轻量消息
struct HeartbeatMessage: Codable, Sendable {
    let type: SyncMessageType
    let timestamp: TimeInterval

    init(type: SyncMessageType = .heartbeat, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.type = type
        self.timestamp = timestamp
    }
}

// MARK: - 同步消息联合类型
/// 使用 CodingKeys 实现多态解析，根据 type 字段区分具体消息类型
enum SyncMessage: Codable, Sendable {
    case liveSegment(LiveSegmentMessage)
    case sessionEnd(SessionEndMessage)
    case meetingBrief(MeetingBriefMessage)
    case heartbeat(HeartbeatMessage)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SyncMessageType.self, forKey: .type)

        switch type {
        case .liveSegment:
            self = .liveSegment(try LiveSegmentMessage(from: decoder))
        case .sessionEnd:
            self = .sessionEnd(try SessionEndMessage(from: decoder))
        case .meetingBrief:
            self = .meetingBrief(try MeetingBriefMessage(from: decoder))
        case .heartbeat:
            self = .heartbeat(try HeartbeatMessage(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .liveSegment(let msg):
            try msg.encode(to: encoder)
        case .sessionEnd(let msg):
            try msg.encode(to: encoder)
        case .meetingBrief(let msg):
            try msg.encode(to: encoder)
        case .heartbeat(let msg):
            try msg.encode(to: encoder)
        }
    }
}

// MARK: - 会议记录模型（本地存储用）
/// 存储在 iPhone 本地的完整会议记录
struct MeetingRecord: Codable, Identifiable, Sendable {
    let id: String                    /// 会议 ID (UUID)
    let sessionId: String              /// 对应服务端 sessionId
    let title: String                  /// 会议标题
    let startTime: Date                /// 开始时间
    let endTime: Date                  /// 结束时间
    let sourceLanguage: String         /// 源语言
    let targetLanguage: String         /// 目标语言
    var segments: [SegmentRecord]      /// 翻译片段列表
    var brief: MeetingBriefMessage?     /// 会议摘要

    /// 会议时长（秒）
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}

/// 单个翻译片段记录（本地存储用）
struct SegmentRecord: Codable, Identifiable, Sendable {
    let id: String                     /// 片段唯一ID
    let originalText: String           /// 原文
    let translatedText: String         /// 译文
    let speakerName: String?
    let timestamp: TimeInterval        /// 相对时间戳
    let segmentIndex: Int              /// 片段序号

    init(from message: LiveSegmentMessage) {
        self.id = UUID().uuidString
        self.originalText = message.originalText
        self.translatedText = message.translatedText
        self.speakerName = message.speakerName
        self.timestamp = message.timestamp
        self.segmentIndex = message.segmentIndex
    }
}

// MARK: - 连接状态
/// 当前与 Mac 端的连接状态
enum ConnectionStatus: String, Sendable {
    case disconnected   /// 未连接
    case connecting      /// 连接中
    case connected       /// 已连接
    case listening        /// 监听中（等待 Mac 连接）

    var description: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中..."
        case .connected: return "已连接"
        case .listening: return "等待连接..."
        }
    }
}
