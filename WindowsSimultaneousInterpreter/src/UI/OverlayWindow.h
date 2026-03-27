// =============================================================================
// OverlayWindow.h — Win32 透明悬浮窗口
// =============================================================================
// 功能说明:
//   创建一个始终置顶的半透明悬浮窗口，用于显示双语翻译文本。
//   与 macOS 版 OverlayWindow 保持一致的用户体验。
//
// 视觉效果:
//   - 半透明毛玻璃背景 (DWM Acrylic/Mica 效果)
//   - 圆角边框
//   - 始终置顶 (TOPMOST)
//   - 可拖拽移动
//   - 隐藏在任务栏中 (TOOLWINDOW)
//
// 窗口位置:
//   - 默认在屏幕底部居中（与 macOS 版一致）
//   - 用户可拖拽到任意位置
//   - 记住最后位置（通过注册表）
//
// 线程模型:
//   UI 更新通过 Windows 消息机制序列化到主线程
//   所有绘制操作在 WM_PAINT 中执行
// =============================================================================

#pragma once

#include <Windows.h>
#include <string>
#include <vector>
#include <mutex>
#include <memory>

#include "../Pipeline.h"

namespace SimultaneousInterpreter {

// =============================================================================
// 段段显示数据（对应 BilingualSegment）
// =============================================================================
struct DisplaySegment {
    int chunkIndex;             // 片段索引
    std::string english;        // 英文文本
    std::string mandarin;       // 中文文本
    float confidence;           // 置信度
    bool isPlaceholder;         // 是否为占位符（"翻译中..."）
};

// =============================================================================
// OverlayWindow — 透明悬浮窗口
// =============================================================================
class OverlayWindow {
public:
    OverlayWindow();
    ~OverlayWindow();

    // 禁止拷贝
    OverlayWindow(const OverlayWindow&) = delete;
    OverlayWindow& operator=(const OverlayWindow&) = delete;

    /// 创建并显示窗口
    bool create();

    /// 销毁窗口
    void destroy();

    /// 更新音频电平
    void updateAudioLevel(float level);

    /// 显示部分段落（英文先出现，中文 "翻译中..."）
    void showPartialSegment(int chunkIndex, const std::string& english, float confidence);

    /// 完成部分段落（填充中文翻译）
    void finalizePartialSegment(int chunkIndex, const std::string& mandarin);

    /// 显示完整双语段落
    void showSegment(const std::string& english, const std::string& mandarin, float confidence);

    /// 结束会话
    void endSession();

    /// 获取窗口句柄
    HWND getHWND() const { return m_hwnd; }

private:
    // ---- 窗口过程 ----
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT handle_message(UINT msg, WPARAM wParam, LPARAM lParam);

    // ---- 绘制 ----
    void onPaint();
    void drawBackground(HDC hdc);
    void drawSegments(HDC hdc, RECT& clientRect);
    void drawAudioLevel(HDC hdc, RECT& clientRect);
    void drawPreSessionHint(HDC hdc, RECT& clientRect);
    void drawSessionEnded(HDC hdc, RECT& clientRect);
    void drawPrivacyIndicator(HDC hdc, RECT& clientRect);

    // ---- 拖拽 ----
    void startDrag(POINT pt);
    void doDrag(POINT pt);
    void endDrag();

    // ---- 布局 ----
    void updateLayout();
    RECT getWindowRect() const;

    // ---- 辅助 ----
    static RECT centerBottomRect(int width, int height, int marginFromBottom = 40);

    // 窗口句柄
    HWND m_hwnd{nullptr};

    // 窗口类名
    static constexpr const wchar_t* WINDOW_CLASS_NAME = L"SimultaneousInterpreterOverlay";

    // 窗口尺寸
    static constexpr int WINDOW_WIDTH = 700;
    static constexpr int WINDOW_HEIGHT = 300;
    static constexpr int WINDOW_MIN_HEIGHT = 120;
    static constexpr int WINDOW_MAX_SEGMENTS = 50;

    // GDI+ Token（在 create/destroy 中管理生命周期）
    ULONG_PTR m_gdiplusToken{0};

    // 状态
    bool m_isCreated{false};
    bool m_isSessionActive{false};
    bool m_isSessionEnded{false};
    float m_audioLevel{0.0f};

    // 显示的段落列表
    std::vector<DisplaySegment> m_segments;
    mutable std::mutex m_segmentsMutex;

    // 拖拽状态
    bool m_isDragging{false};
    POINT m_dragStart{0, 0};
    POINT m_windowStart{0, 0};

    // 窗口位置
    int m_windowX{0};
    int m_windowY{0};

    // 当前窗口高度（根据内容动态调整）
    int m_currentHeight{WINDOW_HEIGHT};
};

} // namespace SimultaneousInterpreter
