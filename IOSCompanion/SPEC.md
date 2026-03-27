# iOS Companion App - 产品规格说明书

## 1. 产品定位

**产品名称:** IOSCompanion
**产品类型:** iOS 伴侣应用
**定位:** Mac 端实时翻译 app 的 iOS 伴侣，作为第二屏幕显示实时翻译字幕和会议摘要。

**核心价值:**
- 将 iPhone/iPad 用作 Mac 翻译 app 的延伸显示器
- 在会议中通过手机展示实时翻译字幕，无需盯着 Mac 屏幕
- 离线可用，不依赖互联网，通过本地 WiFi 与 Mac 通信

---

## 2. 目标用户

- 经常参加外语会议的用户（需要实时字幕辅助理解）
- 同声传译场景下的辅助显示需求
- 多语言会议中需要双语字幕展示的场景

---

## 3. 核心功能

### 3.1 实时翻译字幕显示（Live Translation）

**描述:** 接收来自 Mac 端的实时转录和翻译文本，以字幕形式展示。

**功能点:**
- 连接状态指示（已连接 / 搜索中 / 断开）
- 实时滚动字幕显示（原生语言 + 翻译语言双语对照）
- 字幕字体大小自适应（支持 Dynamic Type）
- 当前说话段落高亮
- 历史字幕回看（上滑查看最近内容）

**数据流向:** Mac → iPhone（单向，iPhone 不控制 Mac）

### 3.2 历史会议记录（Meeting History）

**描述:** 查看过往会议的转录和翻译记录。

**功能点:**
- 会议列表（按日期降序排列）
- 每条记录显示：会议名称、日期、时长、语言对
- 点击进入会议详情
- 支持搜索历史会议

### 3.3 会议摘要查看（Meeting Brief）

**描述:** 查看会议结束后的 AI 生成摘要。

**功能点:**
- 会议关键议题列表
- 核心要点总结
- 参会人员（如有）
- 后续行动项（如有）

### 3.4 设置（Settings）

**功能点:**
- Mac 连接管理（查看已配对 Mac、手动连接/断开）
- 首选语言设置（源语言 / 目标语言）
- 字幕显示偏好（字体大小、背景透明度）
- 通知开关（会议开始提醒）

---

## 4. 技术方案

### 4.1 通信方案

**首选方案: MultipeerConnectivity**
- 使用 `MCSession` / `MCBrowserViewController` 实现点对点发现和连接
- 支持在同一个 WiFi 网络下自动发现
- 无需互联网连接

**备选方案: NWListener (Bonjour + TCP)**
- 使用 `Network.framework` 的 `NWListener`
- 通过 Bonjour 服务广告发现 Mac 端
- TCP 传输 JSON 消息

### 4.2 消息格式

所有消息采用 JSON 格式，通过 Codable 协议序列化。

```swift
// 消息类型枚举
enum SyncMessageType: String, Codable {
    case liveSegment    // 实时翻译片段
    case sessionEnd     // 会议结束
    case meetingBrief    // 会议摘要
    case heartbeat       // 心跳保活
}

// 实时翻译片段
struct LiveSegmentMessage: Codable {
    let type: SyncMessageType = .liveSegment
    let sessionId: String
    let timestamp: TimeInterval
    let originalText: String
    let translatedText: String
    let speakerName: String?
    let segmentIndex: Int
}

// 会议结束
struct SessionEndMessage: Codable {
    let type: SyncMessageType = .sessionEnd
    let sessionId: String
    let endTime: TimeInterval
}

// 会议摘要
struct MeetingBriefMessage: Codable {
    let type: SyncMessageType = .meetingBrief
    let sessionId: String
    let summary: String
    let keyTopics: [String]
    let actionItems: [String]
    let participants: [String]
}
```

### 4.3 数据同步策略

- **方向:** Mac → iPhone（单向）
- **协议:** 可靠连接（TCP / MCSession 的可靠数据传输）
- **离线支持:** 会议期间如断开连接，iPhone 端显示"连接中断"，重连后继续接收
- **历史同步:** 会议结束后，Mac 将完整记录同步给 iPhone 保存

### 4.4 本地存储

- 使用 `UserDefaults` 存储设置项
- 使用 `FileManager` + `JSON` 存储历史会议记录
- 会议数据存储在 App 的 Documents 目录下

### 4.5 技术栈

| 层级 | 技术 |
|------|------|
| UI | SwiftUI (iOS 17+) |
| 通信 | MultipeerConnectivity / Network.framework |
| 数据 | Codable / JSON |
| 本地存储 | UserDefaults + FileManager |
| 异步 | Swift Concurrency (async/await, actors) |
| 动态字体 | Dynamic Type |

---

## 5. UI/UX 设计方向

### 5.1 整体风格
- 遵循 iOS 17 Human Interface Guidelines
- 深色模式优先（会议场景通常灯光较暗）
- 支持 Dynamic Type 无障碍字体缩放

### 5.2 导航结构
- `TabView` 底部标签导航
  - Tab 1: 实时翻译（默认）
  - Tab 2: 历史记录
  - Tab 3: 设置

### 5.3 实时翻译视图
- 全屏字幕显示区域
- 顶部状态栏（连接状态、当前会议名称）
- 底部字幕区域（双语对照，上半原生，下半翻译）
- 支持横屏和竖屏

### 5.4 配色方案
- 主色: 系统蓝色（`Color.accentColor`）
- 背景: 深灰（`Color(uiColor: .systemBackground)`）
- 字幕背景: 半透明黑色（`Color.black.opacity(0.7)`）
- 原文文字: 白色
- 译文文字: 浅蓝色

---

## 6. 项目结构

```
IOSCompanion/
├── SPEC.md                    # 本规格文档
├── README.md                  # 构建与使用说明
├── project.yml                # XcodeGen 项目配置
├── Sources/
│   ├── App/
│   │   └── IOSCompanionApp.swift      # @main 入口
│   ├── Views/
│   │   ├── ContentView.swift          # TabView 主界面
│   │   ├── LiveTranslationView.swift  # 实时翻译视图
│   │   ├── MeetingBriefView.swift     # 会议摘要视图
│   │   ├── HistoryListView.swift      # 历史会议列表
│   │   └── SettingsView.swift         # 设置视图
│   ├── Services/
│   │   ├── WiFiSyncService.swift      # WiFi P2P 同步服务
│   │   └── TranscriptionService.swift # 转录服务（数据消费）
│   └── Models/
│       └── IOSModels.swift            # 数据模型
└── Resources/
    └── Assets.xcassets/               # 资源目录
```

---

## 7. 注意事项

1. **隐私:** 所有数据仅在本地 WiFi 网络内传输，不经过任何互联网服务器
2. **电池:** WiFi 监听会消耗电量，建议在设置中提供"仅连接时监听"选项
3. **兼容性:** 仅支持 iOS 17+（利用最新 SwiftUI 特性）
4. **多设备:** 支持同时连接多个 iOS 设备（Mac 端广播，所有设备均可接收）
