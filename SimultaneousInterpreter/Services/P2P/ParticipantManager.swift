import Foundation

// ============================================================
// MARK: - Participant Manager
// ============================================================
// P4.2: 参与者管理与字幕分发
// 负责管理 participant 列表、首选语言，以及转录文本到各语言的翻译分发
// ============================================================

/// 参与者管理服务
/// 管理会议室中的参与者列表，负责任务：
/// 1. 维护参与者信息和首选语言
/// 2. 转录文本 → NLLB 翻译成各 participant 语言
/// 3. 分发字幕到各 participant 的 overlay
final class ParticipantManager: @unchecked Sendable {

    // MARK: - Properties

    /// 当前会话 ID
    private var sessionId: String = ""

    /// 参与者列表（线程安全访问）
    private var participants: [String: P2PParticipant] = [:]

    /// 同步队列
    private let queue = DispatchQueue(label: "com.simultaneousinterpreter.participantmanager", attributes: .concurrent)

    /// 翻译服务（用于生成各 participant 的翻译）
    private let translationService: TranslationService

    /// 字幕更新回调（participantId → 回调函数）
    /// 通知各 participant 的 overlay 更新字幕
    private var subtitleUpdateHandlers: [String: @Sendable (SubtitleUpdateMessage) -> Void] = [:]

    /// 参与者状态变更回调
    private var onParticipantChanged: (@Sendable ([P2PParticipant]) -> Void)?

    /// 参与者加入/离开回调
    private var onParticipantJoined: ((P2PParticipant) -> Void)?
    private var onParticipantLeft: ((String) -> Void)?

    /// 锁
    private let lock = NSLock()

    // MARK: - Initialization

    init(translationService: TranslationService) {
        self.translationService = translationService
    }

    // MARK: - Session Management

    /// 设置当前会话 ID
    /// - Parameter sessionId: 会话 ID
    func setSession(_ sessionId: String) {
        lock.lock()
        self.sessionId = sessionId
        participants.removeAll()
        lock.unlock()
    }

    /// 清空会话数据
    func clearSession() {
        lock.lock()
        sessionId = ""
        participants.removeAll()
        subtitleUpdateHandlers.removeAll()
        lock.unlock()
    }

    // MARK: - Participant Management

    /// 添加参与者
    /// - Parameter participant: 参与者信息
    func addParticipant(_ participant: P2PParticipant) {
        lock.lock()
        participants[participant.participantId] = participant
        let participantList = Array(participants.values)
        lock.unlock()

        onParticipantJoined?(participant)
        notifyParticipantChanged(participantList)
    }

    /// 移除参与者
    /// - Parameter participantId: 参与者 ID
    func removeParticipant(_ participantId: String) {
        lock.lock()
        let removed = participants.removeValue(forKey: participantId)
        let participantList = Array(participants.values)
        lock.unlock()

        if removed != nil {
            subtitleUpdateHandlers.removeValue(forKey: participantId)
            onParticipantLeft?(participantId)
            notifyParticipantChanged(participantList)
        }
    }

    /// 更新参与者信息
    /// - Parameters:
    ///   - participantId: 参与者 ID
    ///   - updates: 更新内容
    func updateParticipant(_ participantId: String, updates: Partial<P2PParticipant>) {
        lock.lock()
        guard var participant = participants[participantId] else {
            lock.unlock()
            return
        }

        // 应用更新
        if let name = updates.displayName { participant.displayName = name }
        if let lang = updates.preferredLanguage { participant.preferredLanguage = lang }
        if let langName = updates.preferredLanguageName { participant.preferredLanguageName = langName }
        if let quality = updates.networkQuality { participant.networkQuality = quality }
        if let receiving = updates.isReceivingAudio { participant.isReceivingAudio = receiving }
        if let muted = updates.isMuted { participant.isMuted = muted }
        if let role = updates.role { participant.role = role }

        participants[participantId] = participant
        let participantList = Array(participants.values)
        lock.unlock()

        notifyParticipantChanged(participantList)
    }

    /// 获取所有参与者
    /// - Returns: 参与者列表
    func getAllParticipants() -> [P2PParticipant] {
        lock.lock()
        let list = Array(participants.values)
        lock.unlock()
        return list
    }

    /// 获取参与者
    /// - Parameter participantId: 参与者 ID
    /// - Returns: 参与者信息
    func getParticipant(_ participantId: String) -> P2PParticipant? {
        lock.lock()
        let p = participants[participantId]
        lock.unlock()
        return p
    }

    /// 获取所有需要字幕的参与者（即非静音且非 observer 角色的）
    /// - Returns: 需要接收字幕的参与者列表
    func getActiveParticipants() -> [P2PParticipant] {
        lock.lock()
        let active = participants.values.filter { $0.isReceivingAudio && $0.role != .observer }
        let list = Array(active)
        lock.unlock()
        return list
    }

    /// 参与者在会话中的数量
    var participantCount: Int {
        lock.lock()
        let count = participants.count
        lock.unlock()
        return count
    }

    // MARK: - Language Management

    /// 更新参与者的首选语言
    /// - Parameters:
    ///   - participantId: 参与者 ID
    ///   - language: BCP-47 语言标签
    ///   - languageName: 语言显示名
    func updateParticipantLanguage(_ participantId: String, language: String, languageName: String) {
        updateParticipant(participantId, updates: Partial(
            P2PParticipant(
                participantId: participantId,
                displayName: "",
                preferredLanguage: language,
                preferredLanguageName: languageName
            )
        ))
    }

    /// 获取指定语言的所有参与者
    /// - Parameter language: BCP-47 语言标签
    /// - Returns: 使用该语言的参与者列表
    func getParticipantsByLanguage(_ language: String) -> [P2PParticipant] {
        lock.lock()
        let filtered = participants.values.filter { $0.preferredLanguage == language }
        let list = Array(filtered)
        lock.unlock()
        return list
    }

    /// 获取所有需要的语言列表
    /// - Returns: 不重复的 BCP-47 语言标签数组
    func getRequiredLanguages() -> [String] {
        lock.lock()
        let languages = Set(participants.values.map { $0.preferredLanguage })
        let list = Array(languages)
        lock.unlock()
        return list
    }

    // MARK: - Subtitle Distribution

    /// 注册字幕更新回调
    /// - Parameters:
    ///   - participantId: 参与者 ID
    ///   - handler: 回调闭包
    func registerSubtitleHandler(for participantId: String, handler: @escaping @Sendable (SubtitleUpdateMessage) -> Void) {
        lock.lock()
        subtitleUpdateHandlers[participantId] = handler
        lock.unlock()
    }

    /// 注销字幕更新回调
    /// - Parameter participantId: 参与者 ID
    func unregisterSubtitleHandler(for participantId: String) {
        lock.lock()
        subtitleUpdateHandlers.removeValue(forKey: participantId)
        lock.unlock()
    }

    /// 分发字幕到所有相关参与者
    /// 转录文本 → NLLB 翻译成各 participant 语言 → 各 participant 的 overlay
    ///
    /// - Parameters:
    ///   - segment: 原始转录片段（英文）
    ///   - sourceLanguage: 源语言（默认 en）
    ///   - chunkIndex: 片段索引
    ///   - isFinal: 是否为最终结果
    ///   - speakerLabel: 说话人标签
    ///   - senderId: 发送者 ID（房主/翻译员）
    func distributeSubtitle(
        segment: TranscriptionMessage,
        sourceLanguage: String = "en",
        chunkIndex: Int,
        isFinal: Bool,
        speakerLabel: String?,
        senderId: String
    ) async {
        let activeParticipants = getActiveParticipants()

        // 按语言分组，减少重复翻译
        // 同一语言的多个 participant 共享一次翻译结果
        var languageGroups: [String: [P2PParticipant]] = [:]
        for participant in activeParticipants {
            languageGroups[participant.preferredLanguage, default: []].append(participant)
        }

        // 并行翻译到各语言
        await withTaskGroup(of: Void.self) { group in
            for (targetLanguage, groupParticipants) in languageGroups {
                // 跳过源语言相同的情况（不需要翻译）
                if targetLanguage == sourceLanguage {
                    // 直接发送原文（无翻译）
                    let update = SubtitleUpdateMessage(
                        senderId: senderId,
                        sessionId: sessionId,
                        english: segment.text,
                        translated: segment.text,  // 无翻译，直接用原文
                        targetLanguage: targetLanguage,
                        isFinal: isFinal,
                        chunkIndex: chunkIndex,
                        speakerLabel: speakerLabel
                    )
                    deliverSubtitle(update, to: groupParticipants)
                    continue
                }

                group.addTask { [weak self] in
                    guard let self = self else { return }

                    do {
                        let translation = try await self.translationService.translate(
                            text: segment.text,
                            from: sourceLanguage,
                            to: targetLanguage
                        )

                        let update = SubtitleUpdateMessage(
                            senderId: senderId,
                            sessionId: self.sessionId,
                            english: segment.text,
                            translated: translation.text,
                            targetLanguage: targetLanguage,
                            isFinal: isFinal,
                            chunkIndex: chunkIndex,
                            speakerLabel: speakerLabel
                        )

                        await MainActor.run {
                            self.deliverSubtitle(update, to: groupParticipants)
                        }
                    } catch {
                        // 翻译失败，发送原文作为 fallback
                        let update = SubtitleUpdateMessage(
                            senderId: senderId,
                            sessionId: self.sessionId,
                            english: segment.text,
                            translated: segment.text,
                            targetLanguage: targetLanguage,
                            isFinal: isFinal,
                            chunkIndex: chunkIndex,
                            speakerLabel: speakerLabel
                        )
                        await MainActor.run {
                            self.deliverSubtitle(update, to: groupParticipants)
                        }
                    }
                }
            }
        }
    }

    /// 直接分发翻译文本到指定参与者（用于已翻译好的文本）
    /// - Parameters:
    ///   - translationMessage: 翻译消息
    ///   - speakerLabel: 说话人标签
    func deliverTranslation(_ translationMessage: TranslationMessage, speakerLabel: String?) {
        lock.lock()
        guard let participant = participants[translationMessage.targetId] else {
            lock.unlock()
            return
        }
        let targetLanguage = participant.preferredLanguage
        lock.unlock()

        let update = SubtitleUpdateMessage(
            senderId: translationMessage.senderId,
            sessionId: sessionId,
            english: translationMessage.originalText,
            translated: translationMessage.translatedText,
            targetLanguage: targetLanguage,
            isFinal: true,
            chunkIndex: translationMessage.chunkIndex,
            speakerLabel: speakerLabel
        )

        lock.lock()
        let handler = subtitleUpdateHandlers[translationMessage.targetId]
        lock.unlock()

        handler?(update)
    }

    /// 广播翻译结果到所有参与者（房主视角）
    /// - Parameters:
    ///   - originalText: 原文
    ///   - translations: 目标语言 → 翻译文本
    ///   - chunkIndex: 片段索引
    ///   - senderId: 发送者 ID
    ///   - speakerLabel: 说话人标签
    func broadcastTranslations(
        originalText: String,
        translations: [String: String],  // language -> translated text
        chunkIndex: Int,
        senderId: String,
        speakerLabel: String?
    ) async {
        let activeParticipants = getActiveParticipants()

        await withTaskGroup(of: Void.self) { group in
            for participant in activeParticipants {
                group.addTask { [weak self] in
                    guard let self = self else { return }

                    let translatedText = translations[participant.preferredLanguage] ?? originalText
                    let isFinal = translations[participant.preferredLanguage] != nil

                    let update = SubtitleUpdateMessage(
                        senderId: senderId,
                        sessionId: self.sessionId,
                        english: originalText,
                        translated: translatedText,
                        targetLanguage: participant.preferredLanguage,
                        isFinal: isFinal,
                        chunkIndex: chunkIndex,
                        speakerLabel: speakerLabel
                    )

                    await MainActor.run {
                        self.deliverSubtitle(update, to: [participant])
                    }
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// 发送字幕更新到一组参与者
    /// - Parameters:
    ///   - update: 字幕更新消息
    ///   - participants: 目标参与者列表
    private func deliverSubtitle(_ update: SubtitleUpdateMessage, to participants: [P2PParticipant]) {
        for participant in participants {
            lock.lock()
            let handler = subtitleUpdateHandlers[participant.participantId]
            lock.unlock()

            handler?(update)
        }
    }

    /// 通知参与者列表变更
    /// - Parameter list: 新的参与者列表
    private func notifyParticipantChanged(_ list: [P2PParticipant]) {
        onParticipantChanged?(list)
    }

    // MARK: - Callbacks Setup

    /// 设置参与者变更回调
    /// - Parameter handler: 回调闭包
    func setParticipantChangedHandler(_ handler: @escaping @Sendable ([P2PParticipant]) -> Void) {
        lock.lock()
        onParticipantChanged = handler
        lock.unlock()
    }

    /// 设置参与者加入回调
    /// - Parameter handler: 回调闭包
    func setParticipantJoinedHandler(_ handler: @escaping (P2PParticipant) -> Void) {
        lock.lock()
        onParticipantJoined = handler
        lock.unlock()
    }

    /// 设置参与者离开回调
    /// - Parameter handler: 回调闭包
    func setParticipantLeftHandler(_ handler: @escaping (String) -> Void) {
        lock.lock()
        onParticipantLeft = handler
        lock.unlock()
    }
}

// ============================================================
// MARK: - Partial Participant Update Helper
// ============================================================

/// 用于部分更新参与者的临时结构
struct Partial<P: Sendable>: Sendable {
    let displayName: String?
    let preferredLanguage: String?
    let preferredLanguageName: String?
    let networkQuality: P2PNetworkQuality?
    let isReceivingAudio: Bool?
    let isMuted: Bool?
    let role: P2PParticipantRole?

    init(
        participantId: String,
        displayName: String = "",
        preferredLanguage: String = "",
        preferredLanguageName: String = "",
        role: P2PParticipantRole = .participant
    ) {
        self.displayName = nil
        self.preferredLanguage = nil
        self.preferredLanguageName = nil
        self.networkQuality = nil
        self.isReceivingAudio = nil
        self.isMuted = nil
        self.role = nil
    }
}

// ============================================================
// MARK: - Language Name Helper
// ============================================================

/// BCP-47 语言标签到显示名的映射
enum LanguageDisplayName {
    private static let names: [String: String] = [
        "en": "English",
        "zh": "中文",
        "es": "Español",
        "fr": "Français",
        "de": "Deutsch",
        "ja": "日本語",
        "ko": "한국어",
        "ru": "Русский",
        "ar": "العربية",
        "pt": "Português",
        "it": "Italiano",
        "nl": "Nederlands",
        "pl": "Polski",
        "tr": "Türkçe",
        "vi": "Tiếng Việt",
        "th": "ไทย",
        "id": "Bahasa Indonesia",
        "ms": "Bahasa Melayu",
        "hi": "हिन्दी",
        "bn": "বাংলা",
        "ur": "اردو",
        "fa": "فارسی",
        "uk": "Українська",
        "cs": "Čeština",
        "sv": "Svenska",
        "da": "Dansk",
        "fi": "Suomi",
        "no": "Norsk",
        "el": "Ελληνικά",
        "he": "עברית",
        "ro": "Română",
        "hu": "Magyar",
        "bg": "Български"
    ]

    /// 根据 BCP-47 标签获取显示名
    /// - Parameter languageTag: BCP-47 语言标签
    /// - Returns: 显示名，如果未知则返回原始标签
    static func getName(for languageTag: String) -> String {
        // 处理如 "en-US" -> "en" 的情况
        let baseTag = languageTag.prefix(2).lowercased()
        return names[String(baseTag)] ?? languageTag
    }

    /// 获取语言标签对应的国旗 emoji
    /// - Parameter languageTag: BCP-47 语言标签
    /// - Returns: 国旗 emoji
    static func getFlag(for languageTag: String) -> String {
        let flags: [String: String] = [
            "en": "🇺🇸",
            "zh": "🇨🇳",
            "es": "🇪🇸",
            "fr": "🇫🇷",
            "de": "🇩🇪",
            "ja": "🇯🇵",
            "ko": "🇰🇷",
            "ru": "🇷🇺",
            "ar": "🇸🇦",
            "pt": "🇧🇷",
            "it": "🇮🇹",
            "nl": "🇳🇱",
            "pl": "🇵🇱",
            "tr": "🇹🇷",
            "vi": "🇻🇳",
            "th": "🇹🇭",
            "id": "🇮🇩",
            "ms": "🇲🇾",
            "hi": "🇮🇳",
            "bn": "🇧🇩",
            "ur": "🇵🇰",
            "fa": "🇮🇷",
            "uk": "🇺🇦",
            "cs": "🇨🇿",
            "sv": "🇸🇪",
            "da": "🇩🇰",
            "fi": "🇫🇮",
            "no": "🇳🇴",
            "el": "🇬🇷",
            "he": "🇮🇱",
            "ro": "🇷🇴",
            "hu": "🇭🇺",
            "bg": "🇧🇬"
        ]
        let baseTag = languageTag.prefix(2).lowercased()
        return flags[String(baseTag)] ?? "🌐"
    }
}
