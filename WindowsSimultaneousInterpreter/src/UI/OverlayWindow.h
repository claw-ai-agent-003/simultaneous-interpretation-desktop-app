// =============================================================================
// OverlayWindow.h — Win32 透明悬浮窗口
// =============================================================================
// 功能说明:
//   创建一个始终置顶的半透明悬浮窗口，用于显示双语翻译文本。
//   与 macOS 版 OverlayWindow 保持一致的用户体验。
//
// 视觉效果:
//   - 半透明毛玻璃背景 (DWM ExtendFrameIntoClientArea)
//   - 圆角边框
//   - 始终置顶 (TOPMOST)
//   - 可拖拽移动
//   - 隐藏在任务栏中 (TOOLWINDOW)
//
// 窗口位置:
//   - 默认在屏幕底部居中（与 macOS 版一致）
//   - 用户可拖拽到任意位置
// =============================================================================

#pragma once

#include <Windows.h>
#include <string>
#include <vector>
#include <mutex>
#include <memory>
#include <atomic>

#include "../Pipeline.h"

namespace SimultaneousInterpreter {

struct DisplaySegment {
    int chunkIndex;
    std::string english;
    std::string mandarin;
    float confidence;
    bool isPlaceholder;
};

class OverlayWindow {
public:
    OverlayWindow();
    ~OverlayWindow();

    OverlayWindow(const OverlayWindow&) = delete;
    OverlayWindow& operator=(const OverlayWindow&) = delete;

    bool create();
    void destroy();

    void updateAudioLevel(float level);
    void showPartialSegment(int chunkIndex, const std::string& english, float confidence);
    void finalizePartialSegment(int chunkIndex, const std::string& mandarin);
    void showSegment(const std::string& english, const std::string& mandarin, float confidence);
    void endSession();

    HWND getHWND() const { return m_hwnd; }

private:
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
    LRESULT handle_message(UINT msg, WPARAM wParam, LPARAM lParam);

    void onPaint();
    void drawBackground(HDC hdc);
    void drawSegments(HDC hdc, RECT& clientRect);
    void drawAudioLevel(HDC hdc, RECT& clientRect);
    void drawPreSessionHint(HDC hdc, RECT& clientRect);
    void drawSessionEnded(HDC hdc, RECT& clientRect);
    void drawPrivacyIndicator(HDC hdc, RECT& clientRect);

    void startDrag(POINT pt);
    void doDrag(POINT pt);
    void endDrag();

    void updateLayout();
    static RECT centerBottomRect(int width, int height, int marginFromBottom = 40);

    HWND m_hwnd{nullptr};
    static constexpr const wchar_t* WINDOW_CLASS_NAME = L"SimultaneousInterpreterOverlay";

    static constexpr int WINDOW_WIDTH = 700;
    static constexpr int WINDOW_HEIGHT = 300;
    static constexpr int WINDOW_MIN_HEIGHT = 120;
    static constexpr int WINDOW_MAX_SEGMENTS = 50;

    ULONG_PTR m_gdiplusToken{0};

    bool m_isCreated{false};
    bool m_isSessionActive{false};
    bool m_isSessionEnded{false};
    float m_audioLevel{0.0f};

    std::vector<DisplaySegment> m_segments;
    mutable std::mutex m_segmentsMutex;

    bool m_isDragging{false};
    POINT m_dragStart{0, 0};
    POINT m_windowStart{0, 0};

    int m_windowX{0};
    int m_windowY{0};
    int m_currentHeight{WINDOW_HEIGHT};
};

} // namespace SimultaneousInterpreter
