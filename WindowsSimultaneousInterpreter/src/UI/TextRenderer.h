// =============================================================================
// TextRenderer.h — GDI+ 文本渲染器
// =============================================================================
// 功能说明:
//   封装 GDI+ 文本绘制操作，提供简洁的 API 用于双语文本渲染。
//   支持颜色、字体、大小、对齐方式等自定义。
//
// 字体选择:
//   - 英文: Segoe UI (Windows 系统字体)
//   - 中文: Microsoft YaHei (微软雅黑)
//
// 使用方法:
//   TextRenderer renderer(hdc);
//   renderer.drawText(100, 200, L"Hello World", 300, white, fontFamily, 12.0f);
// =============================================================================

#pragma once

#include <Windows.h>
#include <gdiplus.h>
#include <string>
#include <vector>

namespace SimultaneousInterpreter {

// =============================================================================
// TextRenderer — GDI+ 文本渲染器
// =============================================================================
class TextRenderer {
public:
    /// 构造函数
    /// @param hdc 设备上下文句柄
    explicit TextRenderer(HDC hdc);

    /// 绘制文本
    /// @param x         X 坐标
    /// @param y         Y 坐标
    /// @param text      宽字符文本
    /// @param maxWidth  最大宽度（超出则换行）
    /// @param color     文字颜色
    /// @param fontFamily 字体族
    /// @param fontSize  字体大小（像素）
    void drawText(
        int x, int y,
        const std::wstring& text,
        int maxWidth,
        const Gdiplus::Color& color,
        const Gdiplus::FontFamily& fontFamily,
        float fontSize = 12.0f
    );

    /// 绘制标签文本（例如 "EN ", "中 "）
    void drawLabel(
        int x, int y,
        const std::wstring& text,
        const Gdiplus::Color& color
    );

    /// 测量标签文本宽度
    Gdiplus::RectF measureLabel(const std::wstring& text);

    /// 绘制圆点
    void drawDot(int x, int y, int radius, const Gdiplus::Color& color);

    /// UTF-8 转 Wide String
    static std::wstring utf8ToWide(const std::string& utf8);

    /// Wide String 转 UTF-8
    static std::string wideToUtf8(const std::wstring& wide);

private:
    HDC m_hdc;
    Gdiplus::Graphics* m_graphics{nullptr};
};

} // namespace SimultaneousInterpreter
