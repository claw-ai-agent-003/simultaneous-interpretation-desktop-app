import SwiftUI

/// 历史会议列表视图
/// 展示过往所有会议的记录列表，支持搜索和删除
struct HistoryListView: View {

    /// 环境中的 WiFi 同步服务
    @Environment(WiFiSyncService.self) private var syncService

    /// 搜索关键词
    @State private var searchText: String = ""

    /// 历史会议列表
    @State private var meetings: [MeetingRecord] = []

    /// 是否显示删除确认对话框
    @State private var showingDeleteConfirmation = false

    /// 要删除的会议
    @State private var meetingToDelete: MeetingRecord?

    var body: some View {
        NavigationStack {
            Group {
                if filteredMeetings.isEmpty {
                    emptyStateView
                } else {
                    meetingList
                }
            }
            .navigationTitle("历史记录")
            .searchable(text: $searchText, prompt: "搜索会议内容")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !meetings.isEmpty {
                        Text("\(meetings.count) 个会议")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            loadHistory()
        }
        .onChange(of: searchText) { _, _ in
            // 搜索过滤（实际由 filteredMeetings computed property 处理）
        }
    }

    // MARK: - 会议列表

    /// 过滤后的会议列表
    private var filteredMeetings: [MeetingRecord] {
        if searchText.isEmpty {
            return meetings
        }
        let keyword = searchText.lowercased()
        return meetings.filter { record in
            record.title.lowercased().contains(keyword) ||
            record.segments.contains { $0.originalText.lowercased().contains(keyword) ||
                                      $0.translatedText.lowercased().contains(keyword) }
        }
    }

    /// 会议列表视图
    private var meetingList: some View {
        List {
            ForEach(filteredMeetings) { meeting in
                NavigationLink {
                    // 跳转到会议详情
                    MeetingDetailView(meeting: meeting)
                } label: {
                    MeetingRowView(meeting: meeting)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        meetingToDelete = meeting
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            "删除会议",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let meeting = meetingToDelete {
                    deleteMeeting(meeting)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(meetingToDelete?.title ?? "")」吗？此操作不可撤销。")
        }
    }

    // MARK: - 空状态视图

    /// 无历史记录时显示
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)

            Text(searchText.isEmpty ? "暂无历史记录" : "未找到匹配的会议")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(searchText.isEmpty ?
                 "在 Mac 端结束会议后，记录会自动保存在此处" :
                 "尝试其他关键词搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - 数据操作

    /// 加载历史记录
    private func loadHistory() {
        // TODO: 从 TranscriptionService 获取历史记录
        // 暂时使用占位数据
        meetings = []
    }

    /// 删除会议
    /// - Parameter meeting: 要删除的会议
    private func deleteMeeting(_ meeting: MeetingRecord) {
        meetings.removeAll { $0.id == meeting.id }
        // TODO: 调用 TranscriptionService.deleteMeeting(meeting.sessionId)
    }
}

// MARK: - 会议行视图

/// 单个会议列表行的展示视图
struct MeetingRowView: View {

    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 会议标题
            Text(meeting.title)
                .font(.headline)
                .lineLimit(1)

            // 日期和时长
            HStack(spacing: 12) {
                Label(meeting.formattedDate, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(meeting.formattedDuration, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 语言对
            HStack(spacing: 4) {
                Text(meeting.sourceLanguage)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(meeting.targetLanguage)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
            }

            // 是否有摘要
            if meeting.brief != nil {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                    Text("已生成摘要")
                        .font(.caption)
                }
                .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 会议详情视图

/// 会议详情页面，展示完整会议内容和摘要
struct MeetingDetailView: View {

    let meeting: MeetingRecord

    /// 当前选中的分段索引（用于字幕回看）
    @State private var selectedSegmentIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 会议信息头
                headerSection

                // 会议摘要（如果有）
                if let brief = meeting.brief {
                    briefSection(brief)
                }

                // 字幕回看
                transcriptSection
            }
            .padding()
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 会议信息头

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 日期和时长
            HStack(spacing: 16) {
                Label(meeting.formattedDate, systemImage: "calendar")
                Label(meeting.formattedDuration, systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            // 语言对
            HStack(spacing: 8) {
                Text(meeting.sourceLanguage)
                    .fontWeight(.medium)
                Image(systemName: "arrow.right")
                Text(meeting.targetLanguage)
                    .fontWeight(.medium)
            }
            .font(.subheadline)

            // 参会人员
            if let participants = meeting.brief?.participants, !participants.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.3")
                        .font(.caption)
                    Text(participants.joined(separator: ", "))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 摘要区域

    private func briefSection(_ brief: MeetingBriefMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 摘要标题
            Label("会议摘要", systemImage: "doc.text")
                .font(.headline)

            // 总体摘要
            Text(brief.summary)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // 关键议题
            if !brief.keyTopics.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("关键议题")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(brief.keyTopics, id: \.self) { topic in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .padding(.top, 6)
                            Text(topic)
                                .font(.subheadline)
                        }
                    }
                }
            }

            // 行动项
            if !brief.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("后续行动项")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(brief.actionItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(item)
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 字幕回看区域

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("字幕回看", systemImage: "captions.bubble")
                    .font(.headline)

                Spacer()

                Text("\(meeting.segments.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if meeting.segments.isEmpty {
                Text("暂无字幕记录")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                ForEach(meeting.segments) { segment in
                    VStack(alignment: .leading, spacing: 4) {
                        if let speakerName = segment.speakerName {
                            Text(speakerName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(segment.originalText)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Text(segment.translatedText)
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedSegmentIndex == segment.segmentIndex ?
                                  Color.blue.opacity(0.1) : Color.clear)
                    )
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 预览

#Preview {
    HistoryListView()
        .environment(WiFiSyncService())
}
