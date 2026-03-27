import SwiftUI

/// 会议摘要视图
/// 展示单个会议的 AI 生成摘要信息
/// 包括：总体摘要、关键议题、行动项、参会人员
struct MeetingBriefView: View {

    /// 会议摘要数据
    let brief: MeetingBriefMessage

    /// 会议标题（可选，用于显示在导航栏）
    let meetingTitle: String?

    /// WiFi 同步服务
    let syncService: WiFiSyncService

    /// 是否已收藏此摘要
    @State private var isBookmarked = false

    /// 展示模式：详细 / 简洁
    @State private var displayMode: DisplayMode = .detailed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 总体摘要卡片
                summaryCard

                // 关键议题列表
                if !brief.keyTopics.isEmpty {
                    keyTopicsSection
                }

                // 参会人员
                if !brief.participants.isEmpty {
                    participantsSection
                }

                // 后续行动项
                if !brief.actionItems.isEmpty {
                    actionItemsSection
                }

                // 元信息
                metadataSection
            }
            .padding()
        }
        .navigationTitle(meetingTitle ?? "会议摘要")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // 切换显示模式
                    Button {
                        displayMode = displayMode == .detailed ? .compact : .detailed
                    } label: {
                        Label(
                            displayMode == .detailed ? "简洁模式" : "详细模式",
                            systemImage: displayMode == .detailed ? "list.bullet" : "paragraph"
                        )
                    }

                    // 收藏
                    Button {
                        isBookmarked.toggle()
                    } label: {
                        Label(
                            isBookmarked ? "取消收藏" : "收藏摘要",
                            systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
                        )
                    }

                    // 分享（暂未实现）
                    Divider()

                    Button {
                        // 分享功能
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: - 总体摘要卡片

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("摘要", systemImage: "doc.text.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)

                Spacer()

                if let timestamp = formattedTimestamp {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Text(brief.summary)
                .font(displayMode == .detailed ? .body : .callout)
                .lineSpacing(displayMode == .detailed ? 4 : 2)
                .foregroundStyle(.primary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.08))
        )
    }

    // MARK: - 关键议题区域

    private var keyTopicsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("关键议题", systemImage: "list.star")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Spacer()

                Text("\(brief.keyTopics.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(Capsule())
            }

            ForEach(Array(brief.keyTopics.enumerated()), id: \.offset) { index, topic in
                HStack(alignment: .top, spacing: 12) {
                    // 序号圆点
                    Text("\(index + 1)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.orange)
                        .clipShape(Circle())

                    Text(topic)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: - 参会人员区域

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("参会人员", systemImage: "person.3.fill")
                .font(.headline)
                .foregroundStyle(.purple)

            FlowLayout(spacing: 8) {
                ForEach(brief.participants, id: \.self) { participant in
                    Text(participant)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.1))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: - 行动项区域

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("后续行动项", systemImage: "checklist")
                    .font(.headline)
                    .foregroundStyle(.green)

                Spacer()

                Text("\(brief.actionItems.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
            }

            ForEach(Array(brief.actionItems.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    // 勾选框图标
                    Image(systemName: "square")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Text(item)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(index % 2 == 0 ? Color.clear : Color.green.opacity(0.05))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: - 元信息区域

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack {
                Text("摘要生成时间")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let timestamp = formattedTimestamp {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("会话 ID")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(brief.sessionId.prefix(8) + "...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 辅助属性

    /// 格式化后的时间戳
    private var formattedTimestamp: String? {
        let date = Date(timeIntervalSince1970: brief.generatedAt)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - FlowLayout（流式布局）

/// 流式布局，用于在有限宽度内自动换行展示子视图
struct FlowLayout: Layout {

    /// 子视图间距
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            spacing: spacing,
            subviews: subviews
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            spacing: spacing,
            subviews: subviews
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }

    /// 流式布局计算结果
    private struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, spacing: CGFloat, subviews: Subviews) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let viewSize = subview.sizeThatFits(.unspecified)

                if currentX + viewSize.width > maxWidth, currentX > 0 {
                    // 需要换行
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, viewSize.height)
                currentX += viewSize.width + spacing
                size.width = max(size.width, currentX)
            }

            size.height = currentY + lineHeight
        }
    }
}

// MARK: - 显示模式枚举

private enum DisplayMode {
    case detailed
    case compact
}

// MARK: - 预览

#Preview {
    NavigationStack {
        MeetingBriefView(
            brief: MeetingBriefMessage(
                sessionId: "preview-session",
                summary: "本次会议主要讨论了产品开发路线图的更新，包括 Q2 季度的关键里程碑和技术债务清理计划。会议还确定了下一阶段的设计评审时间表。",
                keyTopics: [
                    "Q2 产品路线图更新",
                    "技术债务清理优先级",
                    "设计评审时间表",
                    "团队人员调整"
                ],
                actionItems: [
                    "张三：完成技术方案文档",
                    "李四：安排设计评审会议",
                    "王五：更新项目进度表"
                ],
                participants: ["张三", "李四", "王五", "赵六"],
                generatedAt: Date().timeIntervalSince1970
            ),
            meetingTitle: "产品评审会议",
            syncService: WiFiSyncService()
        )
    }
}
