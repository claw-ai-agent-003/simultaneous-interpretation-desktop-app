import SwiftUI

/// 实时翻译视图
/// 接收并显示来自 Mac 端的实时翻译字幕流
///
/// 功能：
/// - 显示当前连接状态
/// - 实时字幕双语对照展示（上方原文，下方译文）
/// - 字幕滚动区域，支持回顾历史内容
/// - 当前说话人高亮
struct LiveTranslationView: View {

    /// 环境中的 WiFi 同步服务
    @Environment(WiFiSyncService.self) private var syncService

    /// 当前连接状态
    @State private var connectionStatus: ConnectionStatus = .disconnected

    /// 当前会议名称
    @State private var currentMeetingName: String = "未连接会议"

    /// 实时翻译片段列表（按时间顺序展示）
    @State private var segments: [LiveSegmentMessage] = []

    /// 字幕滚动区域引用
    @State private var scrollProxy: ScrollViewProxy?

    /// 字幕区域透明度设置
    @State private var subtitleBackgroundOpacity: Double = 0.7

    /// 字幕字体大小（通过 Dynamic Type 控制）
    @State private var subtitleFontSize: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 顶部状态栏
                topStatusBar
                    .frame(height: 60)

                // 字幕显示区域（主区域）
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            // 空状态占位
                            if segments.isEmpty {
                                emptyStateView
                            }

                            // 字幕片段列表
                            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                                subtitleCard(for: segment, index: index)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onAppear {
                        scrollProxy = proxy
                    }
                }

                // 底部信息栏
                bottomInfoBar
                    .frame(height: 44)
            }
            .background(Color(uiColor: .systemBackground))
        }
        .onAppear {
            observeSyncService()
        }
        .onChange(of: segments.count) { _, _ in
            // 自动滚动到最新字幕
            if !segments.isEmpty {
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrollProxy?.scrollTo(segments.count - 1, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - 顶部状态栏

    private var topStatusBar: some View {
        HStack {
            // 连接状态指示
            connectionIndicator

            Spacer()

            // 会议名称
            Text(currentMeetingName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            // 设置按钮
            Button {
                // 打开字幕设置面板（暂未实现）
            } label: {
                Image(systemName: "textformat.size")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 16)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    /// 连接状态指示器
    private var connectionIndicator: some View {
        HStack(spacing: 8) {
            // 状态圆点
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            // 状态文字
            Text(connectionStatus.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(Capsule())
    }

    /// 根据连接状态返回颜色
    private var statusColor: Color {
        switch connectionStatus {
        case .connected:
            return .green
        case .connecting, .listening:
            return .yellow
        case .disconnected:
            return .gray
        }
    }

    // MARK: - 字幕卡片

    /// 生成单个字幕卡片
    /// - Parameters:
    ///   - segment: 翻译片段数据
    ///   - index: 片段索引
    /// - Returns: 字幕卡片视图
    private func subtitleCard(for segment: LiveSegmentMessage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 说话人标签（如果有）
            if let speakerName = segment.speakerName {
                HStack(spacing: 4) {
                    Image(systemName: "person.wave.2")
                        .font(.caption)
                    Text(speakerName)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
            }

            // 原文区域
            Text(segment.originalText)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // 译文区域
            Text(segment.translatedText)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }

    // MARK: - 空状态视图

    /// 无字幕时显示的空状态
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)

            Text("等待接收翻译...")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("请确保 Mac 端翻译应用已开启并连接到此 iPhone")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }

    // MARK: - 底部信息栏

    private var bottomInfoBar: some View {
        HStack {
            // 语言对信息（占位）
            Text("源语言 → 目标语言")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            // 片段计数
            Text("\(segments.count) 条字幕")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - 数据观察

    /// 观察 syncService 的数据变化
    private func observeSyncService() {
        Task { @MainActor in
            // 监听最新片段
            for await _ in Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().values {
                if let latest = await syncService.latestSegment {
                    if let lastIndex = segments.lastIndex(where: { $0.segmentIndex == latest.segmentIndex }) {
                        // 更新现有片段
                        segments[lastIndex] = latest
                    } else {
                        // 添加新片段
                        segments.append(latest)
                    }
                }

                // 同步连接状态
                connectionStatus = await syncService.connectionStatus

                // 同步会议名称
                if let peerName = await syncService.connectedPeerName {
                    currentMeetingName = "与 \(peerName) 的会议"
                } else {
                    currentMeetingName = "未连接会议"
                }
            }
        }
    }
}

// MARK: - 预览

#Preview {
    LiveTranslationView()
        .environment(WiFiSyncService())
}
