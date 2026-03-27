# IOSCompanion - iOS 翻译伴侣应用

iPhone/iPad 伴侣应用，为 Mac 端实时翻译 app 提供第二屏幕显示能力。

## 功能特性

### 核心功能

- **实时翻译字幕显示** — 通过本地 WiFi 接收 Mac 端推送的实时转录和翻译，双语对照展示
- **会议历史管理** — 自动保存所有会议记录，支持按关键词搜索
- **会议摘要查看** — 展示 Mac 端 AI 生成的关键议题、行动项等摘要信息
- **离线可用** — 完全基于本地 WiFi P2P 通信，无需互联网连接

### 用户界面

- **SwiftUI** — 采用最新 SwiftUI 框架开发
- **Dynamic Type** — 支持 iOS 动态字体大小调节
- **深色模式** — 会议场景优化的深色界面
- **TabView 导航** — 实时翻译 / 历史记录 / 设置 三标签页

## 技术架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Mac 端翻译 App                          │
│  (作为 Host，通过 MultipeerConnectivity 广告服务)            │
└──────────────────────┬──────────────────────────────────────┘
                       │ 本地 WiFi (Bonjour)
                       │ JSON/Codable over MCSession
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    iOS 伴侣 App                               │
│                                                              │
│  ┌──────────────┐   ┌─────────────────┐   ┌─────────────┐  │
│  │  Views 层     │   │  Services 层     │   │ Models 层   │  │
│  │              │   │                  │   │             │  │
│  │ ContentView  │◄──│ WiFiSyncService  │◄──│ IOSModels   │  │
│  │ LiveTrans..  │   │ (Actor)          │   │             │  │
│  │ HistoryList..│   │                  │   │             │  │
│  │ SettingsView │   │ TranscriptionSvc │   │             │  │
│  │ MeetingBrief.│   │ (Actor)          │   │             │  │
│  └──────────────┘   └─────────────────┘   └─────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 通信方案                                              │   │
│  │ • 首选: MultipeerConnectivity (MCSession)            │   │
│  │ • 备选: Network.framework (NWListener + Bonjour)     │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 消息格式

```json
// 实时翻译片段
{
  "type": "liveSegment",
  "sessionId": "uuid-string",
  "timestamp": 1234567890.123,
  "originalText": "Hello everyone",
  "translatedText": "大家好",
  "speakerName": "John",
  "segmentIndex": 1
}

// 会议结束
{
  "type": "sessionEnd",
  "sessionId": "uuid-string",
  "endTime": 1234567890.123,
  "totalDuration": 3600
}

// 会议摘要
{
  "type": "meetingBrief",
  "sessionId": "uuid-string",
  "summary": "会议讨论了产品路线图...",
  "keyTopics": ["Q2里程碑", "技术债务"],
  "actionItems": ["完成文档", "安排评审"],
  "participants": ["张三", "李四"]
}
```

## 项目结构

```
IOSCompanion/
├── SPEC.md                          # 产品规格说明书
├── README.md                         # 本文件
├── project.yml                       # XcodeGen 项目配置
├── Sources/
│   ├── App/
│   │   └── IOSCompanionApp.swift     # @main 应用入口
│   ├── Views/
│   │   ├── ContentView.swift         # TabView 主界面
│   │   ├── LiveTranslationView.swift # 实时翻译视图
│   │   ├── HistoryListView.swift    # 历史会议列表
│   │   ├── MeetingBriefView.swift    # 会议摘要视图
│   │   └── SettingsView.swift       # 设置视图
│   ├── Services/
│   │   ├── WiFiSyncService.swift    # WiFi P2P 同步服务
│   │   └── TranscriptionService.swift # 转录数据管理
│   └── Models/
│       └── IOSModels.swift           # 数据模型定义
└── Resources/
    └── Assets.xcassets/              # 资源目录
```

## 构建说明

### 环境要求

- Xcode 15.0+
- XcodeGen (`brew install xcodegen`)
- iOS 17.0+ 模拟器或真机
- macOS 13.0+ (用于 Xcode)

### 构建步骤

1. **安装 XcodeGen**

   ```bash
   brew install xcodegen
   ```

2. **生成 Xcode 项目**

   ```bash
   cd IOSCompanion
   xcodegen generate
   ```

3. **打开项目**

   ```bash
   open IOSCompanion.xcodeproj
   ```

4. **在 Xcode 中运行**

   - 选择目标设备（iPhone 模拟器或真机）
   - 按 Cmd+R 构建并运行

### 权限配置

应用需要以下权限（已在 `project.yml` 中配置）：

- **本地网络访问** — `NSLocalNetworkUsageDescription`
- **Bonjour 服务发现** — `NSBonjourServices`

## 使用说明

### 首次使用

1. 确保 Mac 和 iPhone 处于同一 WiFi 网络
2. 在 Mac 端翻译 app 中开启「广播」或「配对」模式
3. iPhone 端会自动发现 Mac，点击连接
4. 连接成功后，实时翻译字幕会自动显示

### 实时翻译

- 翻译字幕在「实时翻译」标签页显示
- 上方为原文，下方为译文
- 顶部显示连接状态和会议名称

### 历史记录

- 所有会议记录保存在「历史记录」标签页
- 支持按日期和关键词搜索
- 点击会议可查看完整内容和摘要

### 设置选项

- **连接管理** — 查看连接状态、手动断开
- **语言设置** — 选择源语言和目标语言
- **字幕显示** — 调整背景透明度和字体大小
- **通知** — 开启/关闭会议开始提醒

## 技术栈

| 类别 | 技术 |
|------|------|
| UI 框架 | SwiftUI (iOS 17+) |
| 通信 | MultipeerConnectivity / Network.framework |
| 数据序列化 | Codable / JSON |
| 本地存储 | UserDefaults + FileManager |
| 异步编程 | Swift Concurrency (async/await, actors) |
| 项目构建 | XcodeGen |

## 开发说明

### 消息流

```
Mac 端发送消息
    │
    ▼
WiFiSyncService.receiveMessage()
    │
    ├─── liveSegment ──► LiveTranslationView (实时显示)
    │
    ├─── meetingBrief ──► TranscriptionService (存储)
    │                        │
    │                        ▼
    │                   HistoryListView (列表)
    │
    └─── sessionEnd ──► TranscriptionService (保存记录)
```

### Actor 隔离

- `WiFiSyncService` 和 `TranscriptionService` 均使用 `actor` 实现线程安全
- View 层通过 `@Environment` 注入，在主线程更新 UI
- 数据流使用 Swift Concurrency 的 AsyncStream

### 扩展点

- **支持更多语言对** — 在 `IOSModels.swift` 中扩展
- **自定义字幕样式** — 修改 `LiveTranslationView` 中的字幕卡片
- **持久化方案替换** — 将 `TranscriptionService` 中的 FileManager 替换为 SQLite/CoreData

## 隐私说明

- 所有数据传输通过本地 WiFi 网络完成
- 不经过任何互联网服务器
- 会议记录仅存储在用户设备本地
- 无需创建账户或登录

## License

MIT License - 详见 LICENSE 文件
