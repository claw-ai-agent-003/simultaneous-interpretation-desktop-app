import SwiftUI

/// 主界面视图
/// 采用 TabView 底部标签导航，包含三个主要标签：
/// 1. 实时翻译 - 默认标签，接收并显示 Mac 端推送的实时字幕
/// 2. 历史记录 - 查看过往会议的转录和摘要
/// 3. 设置 - 管理连接、语言偏好等
struct ContentView {

    /// WiFi 同步服务
    let syncService: WiFiSyncService

    /// 转录服务
    let transcriptionService: TranscriptionService

    /// 当前选中的标签索引
    @State private var selectedTab: Tab = .liveTranslation

    init(syncService: WiFiSyncService, transcriptionService: TranscriptionService) {
        self.syncService = syncService
        self.transcriptionService = transcriptionService
    }
}

extension ContentView: View {
    var body: some View {
        // 底部标签导航
        TabView(selection: $selectedTab) {

            // Tab 1: 实时翻译（默认）
            LiveTranslationView(
                syncService: syncService,
                transcriptionService: transcriptionService
            )
            .tabItem {
                Label("实时翻译", systemImage: "captions.bubble")
            }
            .tag(Tab.liveTranslation)

            // Tab 2: 历史记录
            HistoryListView(
                transcriptionService: transcriptionService
            )
            .tabItem {
                Label("历史记录", systemImage: "clock.arrow.circlepath")
            }
            .tag(Tab.history)

            // Tab 3: 设置
            SettingsView(syncService: syncService)
            .tabItem {
                Label("设置", systemImage: "gear")
            }
            .tag(Tab.settings)
        }
        // 支持 Dynamic Type 动态字体
        .environment(\.sizeCategory, .accessibilityMedium)
    }
}

// MARK: - Tab 枚举

private enum Tab: String, CaseIterable {
    case liveTranslation = "实时翻译"
    case history = "历史记录"
    case settings = "设置"
}

// MARK: - 预览

#Preview {
    ContentView(
        syncService: WiFiSyncService(),
        transcriptionService: TranscriptionService()
    )
}
