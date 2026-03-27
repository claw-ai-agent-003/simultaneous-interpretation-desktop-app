import Foundation

// MARK: - 转录服务
/// 负责消费 WiFiSyncService 接收到的数据
/// 提供会议记录管理和摘要存储能力
@Observable
final class TranscriptionService {

    // MARK: - 私有属性

    /// 当前进行中的会议记录
    private(set) var currentSession: MeetingRecord?

    /// 片段缓冲区（按序号排序）
    private var segmentBuffer: [Int: LiveSegmentMessage] = [:]

    /// 历史会议记录列表
    private(set) var meetingHistory: [MeetingRecord] = []

    /// 本地存储路径
    private let storageURL: URL

    // MARK: - 初始化

    init() {
        // 初始化存储路径
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.storageURL = documentsPath.appendingPathComponent("MeetingRecords", isDirectory: true)

        // 确保存储目录存在
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        // 加载历史记录
        loadHistory()
    }

    // MARK: - 公开方法

    /// 开始一个新的会议会话
    /// - Parameters:
    ///   - sessionId: 会话唯一标识
    ///   - title: 会议标题
    ///   - sourceLanguage: 源语言
    ///   - targetLanguage: 目标语言
    func startSession(sessionId: String, title: String, sourceLanguage: String, targetLanguage: String) {
        currentSession = MeetingRecord(
            id: UUID().uuidString,
            sessionId: sessionId,
            title: title,
            startTime: Date(),
            endTime: Date(),
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            segments: [],
            brief: nil
        )
        segmentBuffer.removeAll()
    }

    /// 处理接收到的实时翻译片段
    /// - Parameter message: 翻译片段消息
    func handleSegment(_ message: LiveSegmentMessage) {
        // 如果是新会话的第一个片段，启动会话
        if currentSession == nil || currentSession?.sessionId != message.sessionId {
            startSession(
                sessionId: message.sessionId,
                title: "会议 \(formattedDate(Date()))",
                sourceLanguage: "auto",
                targetLanguage: "auto"
            )
        }

        // 缓冲区存储（处理乱序到达）
        segmentBuffer[message.segmentIndex] = message

        // 按顺序消费缓冲区
        flushSegments()
    }

    /// 处理会议结束信号
    /// - Parameter message: 会议结束消息
    func handleSessionEnd(_ message: SessionEndMessage) {
        // 刷新所有剩余片段
        flushSegments(force: true)

        // 更新会议结束时间
        if var session = currentSession, session.sessionId == message.sessionId {
            session.endTime = Date(timeIntervalSince1970: message.endTime)
            self.currentSession = session

            // 保存到历史记录
            saveMeeting(session)

            // 清空当前会话
            currentSession = nil
            segmentBuffer.removeAll()
        }
    }

    /// 处理会议摘要
    /// - Parameter message: 会议摘要消息
    func handleMeetingBrief(_ message: MeetingBriefMessage) {
        if var session = currentSession, session.sessionId == message.sessionId {
            session.brief = message
            self.currentSession = session

            // 更新历史记录中的摘要
            if let index = meetingHistory.firstIndex(where: { $0.sessionId == message.sessionId }) {
                meetingHistory[index].brief = message
                saveMeetingToDisk(meetingHistory[index])
            }
        }
    }

    /// 获取所有历史会议记录
    /// - Returns: 历史记录列表（按日期降序）
    func getHistory() -> [MeetingRecord] {
        return meetingHistory
    }

    /// 根据 sessionId 获取单个会议记录
    /// - Parameter sessionId: 会话ID
    /// - Returns: 会议记录（不存在则 nil）
    func getMeeting(by sessionId: String) -> MeetingRecord? {
        return meetingHistory.first { $0.sessionId == sessionId }
    }

    /// 删除指定会议记录
    /// - Parameter sessionId: 要删除的会议 sessionId
    func deleteMeeting(sessionId: String) {
        meetingHistory.removeAll { $0.sessionId == sessionId }

        // 删除本地文件
        let fileURL = storageURL.appendingPathComponent("\(sessionId).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 搜索历史会议
    /// - Parameter keyword: 搜索关键词
    /// - Returns: 匹配的历史记录
    func searchMeetings(keyword: String) -> [MeetingRecord] {
        let lowercased = keyword.lowercased()
        return meetingHistory.filter { record in
            record.title.lowercased().contains(lowercased) ||
            record.segments.contains { $0.originalText.lowercased().contains(lowercased) ||
                                      $0.translatedText.lowercased().contains(lowercased) }
        }
    }

    // MARK: - 私有方法

    /// 刷新缓冲区中的片段到当前会话
    /// - Parameter force: 是否强制刷新所有片段（会议结束时为 true）
    private func flushSegments(force: Bool = false) {
        guard var session = currentSession else { return }

        // 按序号顺序处理
        let sortedKeys = segmentBuffer.keys.sorted()
        for key in sortedKeys {
            if let segment = segmentBuffer[key] {
                let record = SegmentRecord(from: segment)
                session.segments.append(record)
                segmentBuffer.removeValue(forKey: key)
            }
        }

        self.currentSession = session

        // 强制刷新时清空缓冲区
        if force {
            segmentBuffer.removeAll()
        }
    }

    /// 保存会议到历史记录
    /// - Parameter record: 会议记录
    private func saveMeeting(_ record: MeetingRecord) {
        // 添加到列表
        meetingHistory.insert(record, at: 0)

        // 持久化到磁盘
        saveMeetingToDisk(record)
    }

    /// 将单个会议记录持久化到磁盘
    /// - Parameter record: 会议记录
    private func saveMeetingToDisk(_ record: MeetingRecord) {
        let fileURL = storageURL.appendingPathComponent("\(record.sessionId).json")

        do {
            let data = try JSONEncoder().encode(record)
            try data.write(to: fileURL)
        } catch {
            print("[TranscriptionService] 保存会议失败: \(error)")
        }
    }

    /// 从磁盘加载所有历史记录
    private func loadHistory() {
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: storageURL,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
            )

            // 仅加载 JSON 文件
            let jsonFiles = fileURLs.filter { $0.pathExtension == "json" }

            meetingHistory = jsonFiles.compactMap { url -> MeetingRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(MeetingRecord.self, from: data)
            }

            // 按日期降序排列
            meetingHistory.sort { $0.startTime > $1.startTime }

        } catch {
            print("[TranscriptionService] 加载历史记录失败: \(error)")
            meetingHistory = []
        }
    }

    /// 格式化日期为字符串
    /// - Parameter date: 日期
    /// - Returns: 格式化后的字符串 "MM-dd HH:mm"
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 日期格式化扩展

extension MeetingRecord {
    /// 格式化的日期字符串
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startTime)
    }

    /// 格式化的时长字符串
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes)分\(seconds)秒"
        } else {
            return "\(seconds)秒"
        }
    }
}
