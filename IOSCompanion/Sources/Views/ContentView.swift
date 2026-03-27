import SwiftUI

/// 主界面视图
/// 采用 TabView 底部标签导航，包含三个主要标签：
/// 1. 实时翻译 - 默认标签，接收并显示 Mac 端推送的实时字幕
/// 2. 历史记录 - 查看过往会议的转录和摘要
/// 3. 设置 - 管理连接、语言偏好等
struct ContentView: View {

    /// 当前选中的标签索引
    @State private var selectedTab: Tab = .liveTranslation

    /// 环境中的 WiFi 同步服务
    @Environment(WiFiSyncService.self) private var syncService

    /// 当前连接状态（从 syncService 同步）
    @State private var connectionStatus: ConnectionStatus = .disconnected

    var body: some View {
        // 底部标签导航
        TabView(selection: $selectedTab) {

            // Tab 1: 实时翻译（默认）
            LiveTranslationView()
                .tabItem {
                    Label("实时翻译", systemImage: "captions.bubble")
                }
                .tag(Tab.liveTranslation)

            // Tab 2: 历史记录
            HistoryListView()
                .tabItem {
                    Label("历史记录", systemImage: "clock.arrow.circlepath")
                }
                .tag(Tab.history)

            // Tab 3: 设置
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gear")
                }
                .tag(Tab.settings)
        }
        // 支持 Dynamic Type 动态字体
        .environment(\.sizeCategory, .accessibilityMedium)
        .onAppear {
            // 监听连接状态变化
            observeConnectionStatus()
        }
    }

    /// 观察连接状态变化
    private func observeConnectionStatus() {
        Task { @MainActor in
            // 定期同步状态（简化实现）
            // 实际项目中可使用 Combine 或 Task.sleep 循环
        }
    }
}

// MARK: - Tab 枚举

/// 底部导航标签
private enum Tab: String, CaseIterable {
    case liveTranslation = "实时翻译"
    case history = "历史记录"
    case settings = "设置"
}

// MARK: - 预览

#Preview {
    ContentView()
        .environment(WiFiSyncService())
}
