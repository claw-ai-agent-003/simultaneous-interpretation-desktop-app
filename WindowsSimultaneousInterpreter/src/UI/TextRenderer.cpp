// =============================================================================
// TextRenderer.cpp — GDI+ 文本渲染器实现
// =============================================================================

#include "TextRenderer.h"
#include <algorithm>

namespace SimultaneousInterpreter {

// =============================================================================
// 构造函数
// =============================================================================
TextRenderer::TextRenderer(HDC hdc) : m_hdc(hdc) {
    m_graphics = new Gdiplus::Graphics(hdc);
    m_graphics->SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    m_graphics->SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);
}

// =============================================================================
// 析构函数
// =============================================================================
// 注意：TextRenderer 的生命周期应短于 HDC
// 析构函数为内联默认实现

// =============================================================================
// 绘制文本
// =============================================================================
void TextRenderer::drawText(
    int x, int y,
    const std::wstring& text,
    int maxWidth,
    const Gdiplus::Color& color,
    const Gdiplus::FontFamily& fontFamily,
    float fontSize
) {
    if (!m_graphics || text.empty()) return;

    Gdiplus::Font font(&fontFamily, fontSize, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush brush(color);

    // 创建格式化对象
    Gdiplus::StringFormat format;
    format.SetAlignment(Gdiplus::StringAlignmentNear);
    format.SetLineAlignment(Gdiplus::StringAlignmentNear);
    format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);

    // 设置最大行数
    format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
    // 允许自动换行
    format.SetFormatFlags(0);

    // 绘制矩形
    Gdiplus::RectF layoutRect(
        static_cast<Gdiplus::REAL>(x),
        static_cast<Gdiplus::REAL>(y),
        static_cast<Gdiplus::REAL>(maxWidth),
        static_cast<Gdiplus::REAL>(fontSize * 3)  // 最多 3 行
    );

    m_graphics->DrawString(
        text.c_str(),
        static_cast<int>(text.length()),
        &font,
        layoutRect,
        &format,
        &brush
    );
}

// =============================================================================
// 绘制标签
// =============================================================================
void TextRenderer::drawLabel(
    int x, int y,
    const std::wstring& text,
    const Gdiplus::Color& color
) {
    if (!m_graphics || text.empty()) return;

    // 使用固定的标签字体
    Gdiplus::FontFamily fontFamily(L"Segoe UI");
    Gdiplus::Font font(&fontFamily, 11.0f, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush brush(color);

    m_graphics->DrawString(
        text.c_str(),
        static_cast<int>(text.length()),
        &font,
        Gdiplus::PointF(static_cast<Gdiplus::REAL>(x), static_cast<Gdiplus::REAL>(y)),
        &brush
    );
}

// =============================================================================
// 测量标签宽度
// =============================================================================
Gdiplus::RectF TextRenderer::measureLabel(const std::wstring& text) {
    if (!m_graphics || text.empty()) {
        return Gdiplus::RectF(0, 0, 0, 0);
    }

    Gdiplus::FontFamily fontFamily(L"Segoe UI");
    Gdiplus::Font font(&fontFamily, 11.0f, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);

    Gdiplus::RectF bounds;
    m_graphics->MeasureString(
        text.c_str(),
        static_cast<int>(text.length()),
        &font,
        Gdiplus::PointF(0, 0),
        &bounds
    );

    return bounds;
}

// =============================================================================
// 绘制圆点
// =============================================================================
void TextRenderer::drawDot(int x, int y, int radius, const Gdiplus::Color& color) {
    if (!m_graphics) return;

    Gdiplus::SolidBrush brush(color);
    m_graphics->FillEllipse(&brush, x, y, radius * 2, radius * 2);
}

// =============================================================================
// UTF-8 转 Wide String
// =============================================================================
std::wstring TextRenderer::utf8ToWide(const std::string& utf8) {
    if (utf8.empty()) return {};

    int wideLen = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
    if (wideLen <= 0) return {};

    std::wstring wide(wideLen - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, wide.data(), wideLen);
    return wide;
}

// =============================================================================
// Wide String 转 UTF-8
// =============================================================================
std::string TextRenderer::wideToUtf8(const std::wstring& wide) {
    if (wide.empty()) return {};

    int utf8Len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (utf8Len <= 0) return {};

    std::string utf8(utf8Len - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, utf8.data(), utf8Len, nullptr, nullptr);
    return utf8;
}

} // namespace SimultaneousInterpreter
