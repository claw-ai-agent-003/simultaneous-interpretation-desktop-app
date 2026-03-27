import SwiftUI

/// 设置视图
/// 管理应用的各种设置选项
struct SettingsView: View {

    /// 环境中的 WiFi 同步服务
    @Environment(WiFiSyncService.self) private var syncService

    /// 当前连接状态
    @State private var connectionStatus: ConnectionStatus = .disconnected

    /// 当前连接的 Mac 名称
    @State private var connectedMacName: String?

    /// 首选语言（源语言）
    @State private var sourceLanguage: String = "自动检测"

    /// 首选语言（目标语言）
    @State private var targetLanguage: String = "中文"

    /// 字幕背景透明度
    @State private var subtitleBackgroundOpacity: Double = 0.7

    /// 字幕字体大小
    @State private var subtitleFontSize: Double = 18

    /// 会议开始通知开关
    @State private var meetingStartNotification: Bool = true

    /// 自动连接开关
    @State private var autoConnect: Bool = true

    /// 显示语言选择器
    @State private var showingLanguagePicker = false

    /// 语言选择器类型（源/目标）
    @State private var languagePickerType: LanguagePickerType = .source

    /// 通信模式
    @State private var syncMode: SyncMode = .multipeerConnectivity

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 连接管理分区
                connectionSection

                // MARK: - 语言设置分区
                languageSection

                // MARK: - 字幕显示分区
                subtitleSection

                // MARK: - 通知设置分区
                notificationSection

                // MARK: - 关于分区
                aboutSection
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showingLanguagePicker) {
                LanguagePickerView(
                    selectedLanguage: languagePickerType == .source ? $sourceLanguage : $targetLanguage,
                    title: languagePickerType == .source ? "选择源语言" : "选择目标语言"
                )
            }
        }
    }

    // MARK: - 连接管理分区

    private var connectionSection: some View {
        Section {
            // 当前连接状态
            HStack {
                Label("连接状态", systemImage: "wifi")

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(connectionStatus.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // 已连接的 Mac
            if let macName = connectedMacName {
                HStack {
                    Label("已连接 Mac", systemImage: "desktopcomputer")

                    Spacer()

                    Text(macName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // 断开连接按钮
                Button(role: .destructive) {
                    disconnectFromMac()
                } label: {
                    Label("断开连接", systemImage: "xmark.circle")
                }
            } else {
                // 搜索 Mac 按钮
                Button {
                    searchForMac()
                } label: {
                    Label("搜索 Mac", systemImage: "magnifyingglass")
                }
                .disabled(connectionStatus == .connecting)
            }

            // 通信模式选择
            Picker("通信模式", selection: $syncMode) {
                ForEach(SyncMode.allCases, id: \.self) { mode in
                    Text(mode.description).tag(mode)
                }
            }

            // 自动连接开关
            Toggle("自动连接", isOn: $autoConnect)

        } header: {
            Text("连接")
        } footer: {
            Text("MultipeerConnectivity 模式下，Mac 和 iPhone 需在同一 WiFi 网络下。")
        }
    }

    /// 根据连接状态返回颜色
    private var statusColor: Color {
        switch connectionStatus {
        case .connected: return .green
        case .connecting, .listening: return .yellow
        case .disconnected: return .gray
        }
    }

    // MARK: - 语言设置分区

    private var languageSection: some View {
        Section {
            // 源语言选择
            Button {
                languagePickerType = .source
                showingLanguagePicker = true
            } label: {
                HStack {
                    Label("源语言", systemImage: "text.bubble")

                    Spacer()

                    Text(sourceLanguage)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

            // 目标语言选择
            Button {
                languagePickerType = .target
                showingLanguagePicker = true
            } label: {
                HStack {
                    Label("目标语言", systemImage: "captions.bubble")

                    Spacer()

                    Text(targetLanguage)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

        } header: {
            Text("语言")
        } footer: {
            Text("设置您期望的翻译目标语言。源语言通常由 Mac 端自动检测。")
        }
    }

    // MARK: - 字幕显示分区

    private var subtitleSection: some View {
        Section {
            // 背景透明度
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("背景透明度", systemImage: "circle.lefthalf.filled")
                    Spacer()
                    Text("\(Int(subtitleBackgroundOpacity * 100))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $subtitleBackgroundOpacity, in: 0.3...1.0, step: 0.1)
                    .tint(.blue)
            }

            // 字体大小
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("字体大小", systemImage: "textformat.size")
                    Spacer()
                    Text("\(Int(subtitleFontSize))pt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $subtitleFontSize, in: 14...28, step: 1)
                    .tint(.blue)
            }

            // 动态类型提示
            HStack {
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(.secondary)
                Text("支持 Dynamic Type，可通过 iOS 设置调整全局字体大小")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        } header: {
            Text("字幕显示")
        }
    }

    // MARK: - 通知设置分区

    private var notificationSection: some View {
        Section {
            Toggle("会议开始提醒", isOn: $meetingStartNotification)

        } header: {
            Text("通知")
        } footer: {
            Text("开启后，当 Mac 端开始新会议时会收到通知提醒。")
        }
    }

    // MARK: - 关于分区

    private var aboutSection: some View {
        Section {
            // 版本信息
            HStack {
                Label("版本", systemImage: "info.circle")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }

            // 许可证
            NavigationLink {
                LicenseView()
            } label: {
                Label("开源许可证", systemImage: "doc.text")
            }

            // 帮助
            NavigationLink {
                HelpView()
            } label: {
                Label("使用帮助", systemImage: "questionmark.circle")
            }

        } header: {
            Text("关于")
        }
    }

    // MARK: - 操作方法

    /// 搜索并连接 Mac
    private func searchForMac() {
        Task {
            await syncService.startListening()
        }
    }

    /// 断开与 Mac 的连接
    private func disconnectFromMac() {
        Task {
            await syncService.stopListening()
            connectedMacName = nil
        }
    }
}

// MARK: - 语言选择器类型

private enum LanguagePickerType {
    case source
    case target
}

// MARK: - 语言选择视图

/// 语言选择器视图
struct LanguagePickerView: View {

    @Binding var selectedLanguage: String
    let title: String

    @Environment(\.dismiss) private var dismiss

    /// 支持的语言列表
    private let languages = [
        "自动检测",
        "中文",
        "English",
        "日本語",
        "한국어",
        "Français",
        "Deutsch",
        "Español",
        "Português",
        "Русский"
    ]

    var body: some View {
        NavigationStack {
            List(languages, id: \.self) { language in
                Button {
                    selectedLanguage = language
                    dismiss()
                } label: {
                    HStack {
                        Text(language)
                            .foregroundStyle(.primary)

                        Spacer()

                        if language == selectedLanguage {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 许可证视图

struct LicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MIT License")
                    .font(.headline)

                Text("""
                Copyright (c) 2024 Simultaneous Interpretation App

                Permission is hereby granted, free of charge, to any person obtaining a copy
                of this software and associated documentation files (the "Software"), to deal
                in the Software without restriction, including without limitation the rights
                to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
                copies of the Software, and to permit persons to whom the Software is
                furnished to do so, subject to the following conditions:

                The above copyright notice and this permission notice shall be included in all
                copies or substantial portions of the Software.

                THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
                IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
                FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
                AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
                LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
                OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
                SOFTWARE.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("开源许可证")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 帮助视图

struct HelpView: View {
    var body: some View {
        List {
            Section("快速开始") {
                HelpItem(
                    icon: "1.circle.fill",
                    title: "确保在同一网络",
                    description: "Mac 和 iPhone 需要连接到同一个 WiFi 网络"
                )

                HelpItem(
                    icon: "2.circle.fill",
                    title: "在 Mac 端开启配对",
                    description: "在 Mac 端翻译应用中选择「开始广播」"
                )

                HelpItem(
                    icon: "3.circle.fill",
                    title: "iPhone 自动连接",
                    description: "iPhone 会自动发现并连接到 Mac"
                )
            }

            Section("常见问题") {
                HelpItem(
                    icon: "questionmark.circle",
                    title: "无法连接？",
                    description: "检查 WiFi 网络是否一致，尝试重新启动两端的应用程序"
                )

                HelpItem(
                    icon: "questionmark.circle",
                    title: "字幕不显示？",
                    description: "确保 Mac 端已开始翻译，实时翻译会自动推送到 iPhone"
                )
            }
        }
        .navigationTitle("使用帮助")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 帮助项视图
struct HelpItem: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 预览

#Preview {
    SettingsView()
        .environment(WiFiSyncService())
}
