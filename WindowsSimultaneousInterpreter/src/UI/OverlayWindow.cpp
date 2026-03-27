// =============================================================================
// OverlayWindow.cpp — Win32 透明悬浮窗口实现
// =============================================================================
// 使用 Win32 API + GDI+ 实现透明悬浮窗口
// 通过 DWM (Desktop Window Manager) API 实现毛玻璃效果
// =============================================================================

#include "OverlayWindow.h"
#include "TextRenderer.h"
#include <iostream>
#include <algorithm>

#include <gdiplus.h>
#include <dwmapi.h>

// 链接 GDI+ 和 DWM 库
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "dwmapi.lib")

namespace SimultaneousInterpreter {

// =============================================================================
// 构造函数
// =============================================================================
OverlayWindow::OverlayWindow() {
    // 初始化 GDI+
    Gdiplus::GdiplusStartupInput gdiplusStartupInput;
    Gdiplus::GdiplusStartup(&m_gdiplusToken, &gdiplusStartupInput, nullptr);
}

// =============================================================================
// 析构函数
// =============================================================================
OverlayWindow::~OverlayWindow() {
    destroy();

    // 关闭 GDI+
    if (m_gdiplusToken) {
        Gdiplus::GdiplusShutdown(m_gdiplusToken);
        m_gdiplusToken = 0;
    }
}

// =============================================================================
// 创建窗口
// =============================================================================
bool OverlayWindow::create() {
    if (m_isCreated) return true;

    // 注册窗口类
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;  // 无背景刷（透明窗口）
    wc.lpszClassName = WINDOW_CLASS_NAME;

    if (!RegisterClassExW(&wc)) {
        DWORD err = GetLastError();
        if (err != ERROR_CLASS_ALREADY_EXISTS) {
            std::cerr << "[OverlayWindow] 注册窗口类失败: " << err << std::endl;
            return false;
        }
    }

    // 计算窗口位置（屏幕底部居中）
    RECT rect = centerBottomRect(WINDOW_WIDTH, WINDOW_HEIGHT);
    m_windowX = rect.left;
    m_windowY = rect.top;

    // 创建无边框窗口
    // WS_EX_TOOLWINDOW: 不在任务栏显示
    // WS_EX_TOPMOST: 始终置顶
    // WS_EX_LAYERED: 支持分层/透明
    m_hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_NOACTIVATE,
        WINDOW_CLASS_NAME,
        L"Simultaneous Interpreter",
        WS_POPUP,
        m_windowX, m_windowY,
        WINDOW_WIDTH, WINDOW_HEIGHT,
        nullptr, nullptr,
        GetModuleHandleW(nullptr),
        this  // 传递 this 指针
    );

    if (!m_hwnd) {
        std::cerr << "[OverlayWindow] 创建窗口失败: " << GetLastError() << std::endl;
        return false;
    }

    // 设置 DWM 毛玻璃效果
    // Windows 11: DWMWA_SYSTEMBACKDROP_TYPE = DWM_SYSTEMBACKDROP_TYPE::DWMSBT_TRANSIENTWINDOW
    // Windows 10: 使用 DwmExtendFrameIntoClientArea
    MARGINS margins = { -1, -1, -1, -1 }; // 扩展到整个窗口
    DwmExtendFrameIntoClientArea(m_hwnd, &margins);

    // 设置窗口半透明
    SetLayeredWindowAttributes(m_hwnd, 0, 230, LWA_ALPHA); // 90% 不透明度

    // 显示窗口
    ShowWindow(m_hwnd, SW_SHOWNOACTIVATE);
    UpdateWindow(m_hwnd);

    m_isCreated = true;
    std::cout << "[OverlayWindow] 悬浮窗口已创建" << std::endl;
    return true;
}

// =============================================================================
// 销毁窗口
// =============================================================================
void OverlayWindow::destroy() {
    if (m_hwnd) {
        DestroyWindow(m_hwnd);
        m_hwnd = nullptr;
    }

    // 注销窗口类
    UnregisterClassW(WINDOW_CLASS_NAME, GetModuleHandleW(nullptr));
    m_isCreated = false;
}

// =============================================================================
// 窗口过程（静态）
// =============================================================================
LRESULT CALLBACK OverlayWindow::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    // 在 WM_NCCREATE 中获取 this 指针
    if (msg == WM_NCCREATE) {
        CREATESTRUCTW* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA,
            reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
        return TRUE;
    }

    // 获取 this 指针
    OverlayWindow* pThis = reinterpret_cast<OverlayWindow*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    if (pThis) {
        return pThis->handle_message(msg, wParam, lParam);
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// =============================================================================
// 消息处理
// =============================================================================
LRESULT OverlayWindow::handle_message(UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_PAINT:
        onPaint();
        return 0;

    case WM_LBUTTONDOWN: {
        POINT pt = { GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam) };
        startDrag(pt);
        return 0;
    }

    case WM_MOUSEMOVE: {
        if (m_isDragging) {
            POINT pt = { GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam) };
            doDrag(pt);
        }
        return 0;
    }

    case WM_LBUTTONUP:
        endDrag();
        return 0;

    case WM_DESTROY:
        return 0;

    case WM_DPICHANGED: {
        // DPI 变化时重新布局
        RECT* rect = reinterpret_cast<RECT*>(lParam);
        SetWindowPos(m_hwnd, nullptr,
            rect->left, rect->top,
            rect->right - rect->left, rect->bottom - rect->top,
            SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }

    default:
        return DefWindowProcW(m_hwnd, msg, wParam, lParam);
    }
}

// =============================================================================
// 绘制（WM_PAINT）
// =============================================================================
void OverlayWindow::onPaint() {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(m_hwnd, &ps);

    if (!hdc) {
        EndPaint(m_hwnd, &ps);
        return;
    }

    RECT clientRect;
    GetClientRect(m_hwnd, &clientRect);

    // 使用 GDI+ 双缓冲绘制
    Gdiplus::Graphics graphics(hdc);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

    // 绘制背景
    drawBackground(hdc);

    // 根据 DPI 缩放
    HDC hdcScaled = hdc; // TODO: DPI 感知缩放

    // 绘制内容
    if (m_isSessionEnded) {
        drawSessionEnded(hdcScaled, clientRect);
    } else if (m_isSessionActive) {
        drawPrivacyIndicator(hdcScaled, clientRect);
        drawAudioLevel(hdcScaled, clientRect);
        drawSegments(hdcScaled, clientRect);
    } else {
        drawPreSessionHint(hdcScaled, clientRect);
    }

    EndPaint(m_hwnd, &ps);
}

// =============================================================================
// 绘制背景
// =============================================================================
void OverlayWindow::drawBackground(HDC hdc) {
    RECT clientRect;
    GetClientRect(m_hwnd, &clientRect);

    // 使用 GDI+ 绘制圆角半透明背景
    Gdiplus::Graphics graphics(hdc);

    // 创建圆角矩形路径
    int radius = 12;
    Gdiplus::GraphicsPath path;
    path.AddArc(0, 0, radius * 2, radius * 2, 180, 90);
    path.AddArc(clientRect.right - radius * 2, 0, radius * 2, radius * 2, 270, 90);
    path.AddArc(clientRect.right - radius * 2, clientRect.bottom - radius * 2,
        radius * 2, radius * 2, 0, 90);
    path.AddArc(0, clientRect.bottom - radius * 2, radius * 2, radius * 2, 90, 90);
    path.CloseFigure();

    // 半透明深色背景
    // Alpha = 200 (约 78% 不透明)
    Gdiplus::Color bgColor(200, 30, 30, 30); // RGBA
    Gdiplus::SolidBrush bgBrush(bgColor);
    graphics.FillPath(&bgBrush, &path);

    // 细边框
    Gdiplus::Color borderColor(100, 255, 255, 255);
    Gdiplus::Pen borderPen(borderColor, 1.0f);
    graphics.DrawPath(&borderPen, &path);
}

// =============================================================================
// 绘制段落列表
// =============================================================================
void OverlayWindow::drawSegments(HDC hdc, RECT& clientRect) {
    std::lock_guard<std::mutex> lock(m_segmentsMutex);

    if (m_segments.empty()) return;

    TextRenderer renderer(hdc);

    int y = 40;  // 起始 Y 位置（留出音频电平和隐私指示器空间）
    int x = 16;  // 左边距
    int maxWidth = clientRect.right - x * 2;

    // 从最新的段落开始绘制（如果超出窗口高度，裁剪旧段落）
    int startIndex = 0;
    int estimatedHeight = 0;
    for (int i = static_cast<int>(m_segments.size()) - 1; i >= 0; --i) {
        estimatedHeight += 60; // 每段大约 60px
        if (estimatedHeight > clientRect.bottom - y - 16) {
            startIndex = i;
            break;
        }
    }

    for (int i = startIndex; i < static_cast<int>(m_segments.size()); ++i) {
        const auto& seg = m_segments[i];

        // 绘制置信度指示点
        Gdiplus::Color dotColor;
        if (seg.confidence >= 0.8f) {
            dotColor = Gdiplus::Color(255, 52, 199, 89);   // 绿色
        } else if (seg.confidence >= 0.6f) {
            dotColor = Gdiplus::Color(255, 255, 149, 0);   // 橙色
        } else {
            dotColor = Gdiplus::Color(255, 255, 59, 48);   // 红色
        }
        renderer.drawDot(x, y + 6, 4, dotColor);

        // 绘制英文行: "EN  <text>"
        renderer.drawLabel(x + 12, y, L"EN ",
            Gdiplus::Color(255, 52, 152, 219)); // 浅蓝色

        std::wstring wEnglish = TextRenderer::utf8ToWide(seg.english);
        renderer.drawText(x + 12 + renderer.measureLabel(L"EN ").Width, y,
            wEnglish, maxWidth - 60,
            Gdiplus::Color(255, 255, 255, 255), // 白色
            Gdiplus::FontFamilyW(L"Microsoft YaHei"), 11.0f);

        y += 22;

        // 绘制中文行: "中  <text>"
        renderer.drawLabel(x + 12, y, L"中 ",
            Gdiplus::Color(255, 230, 126, 34)); // 橙色

        std::string mandarinText = seg.mandarin;
        std::wstring wMandarin;

        if (seg.isPlaceholder) {
            // 占位符文本 — "翻译中..."
            wMandarin = TextRenderer::utf8ToWide(mandarinText);
            // 占位符用灰色
            renderer.drawText(x + 12 + renderer.measureLabel(L"中 ").Width, y,
                wMandarin, maxWidth - 60,
                Gdiplus::Color(255, 150, 150, 150), // 灰色
                Gdiplus::FontFamilyW(L"Microsoft YaHei"), 11.0f);
        } else {
            wMandarin = TextRenderer::utf8ToWide(mandarinText);
            renderer.drawText(x + 12 + renderer.measureLabel(L"中 ").Width, y,
                wMandarin, maxWidth - 60,
                Gdiplus::Color(255, 255, 255, 255), // 白色
                Gdiplus::FontFamilyW(L"Microsoft YaHei"), 11.0f);
        }

        y += 30;

        // 段间距
        y += 4;
    }

    // 如果段落数超过窗口高度，自动调整窗口大小
    int desiredHeight = y + 16;
    if (desiredHeight > WINDOW_MIN_HEIGHT && desiredHeight != m_currentHeight) {
        m_currentHeight = std::min(desiredHeight, WINDOW_HEIGHT);
        updateLayout();
    }
}

// =============================================================================
// 绘制音频电平条
// =============================================================================
void OverlayWindow::drawAudioLevel(HDC hdc, RECT& clientRect) {
    TextRenderer renderer(hdc);

    int x = 16;
    int y = 16;
    int barWidth = clientRect.right - x - 120;
    int barHeight = 4;

    // 标签 "🎤 音频电平"
    // 使用纯文本标签
    renderer.drawLabel(x, y - 2, L"Audio",
        Gdiplus::Color(255, 150, 150, 150));

    // 背景条
    RECT barRect = { x + 50, y, x + 50 + barWidth, y + barHeight };
    Gdiplus::Graphics graphics(hdc);
    Gdiplus::SolidBrush bgBrush(Gdiplus::Color(60, 255, 255, 255));
    graphics.FillRectangle(&bgBrush, barRect.left, barRect.top,
        barRect.right - barRect.left, barRect.bottom - barRect.top);

    // 电平条（绿色渐变）
    int fillWidth = static_cast<int>(barWidth * m_audioLevel);
    if (fillWidth > 0) {
        // 根据电平选择颜色
        Gdiplus::Color barColor;
        if (m_audioLevel < 0.6f) {
            barColor = Gdiplus::Color(255, 52, 199, 89); // 绿色
        } else if (m_audioLevel < 0.85f) {
            barColor = Gdiplus::Color(255, 255, 204, 0); // 黄色
        } else {
            barColor = Gdiplus::Color(255, 255, 59, 48); // 红色
        }

        Gdiplus::SolidBrush fillBrush(barColor);
        graphics.FillRectangle(&fillBrush, barRect.left, barRect.top,
            fillWidth, barRect.bottom - barRect.top);
    }
}

// =============================================================================
// 绘制预会话提示
// =============================================================================
void OverlayWindow::drawPreSessionHint(HDC hdc, RECT& clientRect) {
    TextRenderer renderer(hdc);

    std::wstring hint = L"Point your mic at the speaker and speech will appear here.";
    // 中文版: "将麦克风对准扬声器，语音将会显示在这里。"
    // Windows 版也支持中文提示

    Gdiplus::PointF origin(
        static_cast<Gdiplus::REAL>(clientRect.left + (clientRect.right - clientRect.left) / 2),
        static_cast<Gdiplus::REAL>(clientRect.top + (clientRect.bottom - clientRect.top) / 2)
    );

    Gdiplus::FontFamily fontFamily(L"Microsoft YaHei");
    Gdiplus::Font font(&fontFamily, 13.0f, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush brush(Gdiplus::Color(255, 150, 150, 150));

    Gdiplus::StringFormat format;
    format.SetAlignment(Gdiplus::StringAlignmentCenter);
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);

    Gdiplus::Graphics(hdc).DrawString(
        hint.c_str(), -1, &font, origin, &format, &brush);
}

// =============================================================================
// 绘制会话结束提示
// =============================================================================
void OverlayWindow::drawSessionEnded(HDC hdc, RECT& clientRect) {
    TextRenderer renderer(hdc);

    std::wstring hint = L"Session ended / 会话已结束";

    Gdiplus::PointF origin(
        static_cast<Gdiplus::REAL>(clientRect.left + (clientRect.right - clientRect.left) / 2),
        static_cast<Gdiplus::REAL>(clientRect.top + (clientRect.bottom - clientRect.top) / 2)
    );

    Gdiplus::FontFamily fontFamily(L"Microsoft YaHei");
    Gdiplus::Font font(&fontFamily, 14.0f, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush brush(Gdiplus::Color(255, 150, 150, 150));

    Gdiplus::StringFormat format;
    format.SetAlignment(Gdiplus::StringAlignmentCenter);
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);

    Gdiplus::Graphics(hdc).DrawString(
        hint.c_str(), -1, &font, origin, &format, &brush);
}

// =============================================================================
// 绘制隐私指示器
// =============================================================================
void OverlayWindow::drawPrivacyIndicator(HDC hdc, RECT& clientRect) {
    TextRenderer renderer(hdc);

    int x = 16;
    int y = 6;

    // 绿色圆点
    renderer.drawDot(x, y + 6, 4, Gdiplus::Color(255, 52, 199, 89));

    // "Privacy Mode: Active" 文本
    renderer.drawLabel(x + 10, y, L"Privacy: Local Processing Only",
        Gdiplus::Color(255, 150, 150, 150));
}

// =============================================================================
// 更新音频电平
// =============================================================================
void OverlayWindow::updateAudioLevel(float level) {
    m_audioLevel = level;
    if (m_hwnd) {
        InvalidateRect(m_hwnd, nullptr, FALSE);
    }
}

// =============================================================================
// 显示部分段落（英文先出现）
// =============================================================================
void OverlayWindow::showPartialSegment(int chunkIndex, const std::string& english, float confidence) {
    {
        std::lock_guard<std::mutex> lock(m_segmentsMutex);

        // 检查是否已存在同 chunkIndex 的段落（更新它）
        bool found = false;
        for (auto& seg : m_segments) {
            if (seg.chunkIndex == chunkIndex) {
                seg.english = english;
                seg.confidence = confidence;
                found = true;
                break;
            }
        }

        if (!found) {
            DisplaySegment seg;
            seg.chunkIndex = chunkIndex;
            seg.english = english;
            seg.mandarin = "翻译中...";
            seg.confidence = confidence;
            seg.isPlaceholder = true;
            m_segments.push_back(seg);
        }

        m_isSessionActive = true;

        // 裁剪旧段落
        while (m_segments.size() > WINDOW_MAX_SEGMENTS) {
            m_segments.erase(m_segments.begin());
        }
    }

    if (m_hwnd) {
        InvalidateRect(m_hwnd, nullptr, FALSE);
    }
}

// =============================================================================
// 完成部分段落（填充中文）
// =============================================================================
void OverlayWindow::finalizePartialSegment(int chunkIndex, const std::string& mandarin) {
    {
        std::lock_guard<std::mutex> lock(m_segmentsMutex);

        for (auto& seg : m_segments) {
            if (seg.chunkIndex == chunkIndex) {
                seg.mandarin = mandarin;
                seg.isPlaceholder = false;
                break;
            }
        }
    }

    if (m_hwnd) {
        InvalidateRect(m_hwnd, nullptr, FALSE);
    }
}

// =============================================================================
// 显示完整双语段落
// =============================================================================
void OverlayWindow::showSegment(const std::string& english, const std::string& mandarin, float confidence) {
    {
        std::lock_guard<std::mutex> lock(m_segmentsMutex);

        DisplaySegment seg;
        seg.chunkIndex = static_cast<int>(m_segments.size());
        seg.english = english;
        seg.mandarin = mandarin;
        seg.confidence = confidence;
        seg.isPlaceholder = false;
        m_segments.push_back(seg);

        m_isSessionActive = true;

        while (m_segments.size() > WINDOW_MAX_SEGMENTS) {
            m_segments.erase(m_segments.begin());
        }
    }

    if (m_hwnd) {
        InvalidateRect(m_hwnd, nullptr, FALSE);
    }
}

// =============================================================================
// 结束会话
// =============================================================================
void OverlayWindow::endSession() {
    m_isSessionActive = false;
    m_isSessionEnded = true;
    m_audioLevel = 0.0f;

    if (m_hwnd) {
        InvalidateRect(m_hwnd, nullptr, FALSE);
    }
}

// =============================================================================
// 拖拽操作
// =============================================================================
void OverlayWindow::startDrag(POINT pt) {
    m_isDragging = true;
    m_dragStart = pt;
    m_windowStart = { m_windowX, m_windowY };
    SetCapture(m_hwnd);
}

void OverlayWindow::doDrag(POINT pt) {
    if (!m_isDragging) return;

    int dx = pt.x - m_dragStart.x;
    int dy = pt.y - m_dragStart.y;

    m_windowX = m_windowStart.x + dx;
    m_windowY = m_windowStart.y + dy;

    SetWindowPos(m_hwnd, HWND_TOPMOST, m_windowX, m_windowY, 0, 0,
        SWP_NOSIZE | SWP_NOACTIVATE);
}

void OverlayWindow::endDrag() {
    m_isDragging = false;
    ReleaseCapture();
}

// =============================================================================
// 布局更新
// =============================================================================
void OverlayWindow::updateLayout() {
    if (m_hwnd) {
        SetWindowPos(m_hwnd, HWND_TOPMOST, 0, 0, WINDOW_WIDTH, m_currentHeight,
            SWP_NOMOVE | SWP_NOACTIVATE);
    }
}

// =============================================================================
// 窗口矩形计算
// =============================================================================
RECT OverlayWindow::getWindowRect() const {
    RECT rect;
    rect.left = m_windowX;
    rect.top = m_windowY;
    rect.right = m_windowX + WINDOW_WIDTH;
    rect.bottom = m_windowY + WINDOW_HEIGHT;
    return rect;
}

// =============================================================================
// 居中底部位置
// =============================================================================
RECT OverlayWindow::centerBottomRect(int width, int height, int marginFromBottom) {
    // 获取主显示器工作区域
    RECT workArea;
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &workArea, 0)) {
        // 回退到全屏
        workArea.left = 0;
        workArea.top = 0;
        workArea.right = GetSystemMetrics(SM_CXSCREEN);
        workArea.bottom = GetSystemMetrics(SM_CYSCREEN);
    }

    int screenX = workArea.left + (workArea.right - workArea.left - width) / 2;
    int screenY = workArea.bottom - height - marginFromBottom;

    RECT rect;
    rect.left = screenX;
    rect.top = screenY;
    rect.right = screenX + width;
    rect.bottom = screenY + height;
    return rect;
}

} // namespace SimultaneousInterpreter
