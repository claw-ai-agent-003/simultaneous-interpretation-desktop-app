import SwiftUI

/// IOSCompanion App 入口文件
/// @main 标记表示这是 iOS 应用的程序入口
@main
struct IOSCompanionApp: App {

    /// WiFi 同步服务单例（actor）
    /// 使用 @State 包装以支持 SwiftUI 绑定
    @State private var syncService = WiFiSyncService()

    var body: some Scene {
        WindowGroup {
            // 根视图使用 ContentView
            // 注入 syncService 以便子视图访问
            ContentView()
                .environment(syncService)
                .task {
                    // App 启动时自动开始监听
                    await syncService.startListening()
                }
                .onDisappear {
                    // App 退出时停止监听
                    Task {
                        await syncService.stopListening()
                    }
                }
        }
    }
}
