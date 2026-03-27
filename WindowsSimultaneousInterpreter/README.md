# WindowsSimultaneousInterpreter — Windows 同时传译桌面应用

**Windows 版本的同时传译（同声传译）桌面应用，使用 ONNX Runtime 进行本地离线 AI 推理。**

## 概述 / Overview

这是 [Simultaneous Interpretation Desktop App](../../README.md) 的 Windows 原生实现版本。

- **macOS 版**: Swift + MLX (Apple Silicon 专属)
- **Windows 版**: C++17 + ONNX Runtime (Windows 10/11 x64)

### 核心功能

- 🔊 **WASAPI Loopback 采集**: 无需第三方虚拟音频驱动，直接捕获系统音频
- 🗣️ **Whisper 语音转文字**: ONNX Runtime 加载 Whisper-base 模型，本地转写
- 🌐 **NLLB-200 翻译**: ONNX Runtime 加载 NLLB-200 distilled 模型，英中双向翻译
- 🖼️ **透明悬浮窗**: Win32 API + GDI+ 实现毛玻璃效果悬浮窗，双语文本渲染
- 🔒 **隐私优先**: 所有处理完全在本地完成，音频和文本不离开设备

## 技术栈 / Tech Stack

| 组件 | 技术 |
|------|------|
| 语言 | C++17 |
| 构建 | CMake 3.21+ |
| 编译器 | MSVC 2022 (Visual Studio 17) |
| 音频采集 | WASAPI (Windows Audio Session API) Loopback |
| 语音转文字 | ONNX Runtime C++ API + Whisper-base |
| 翻译 | ONNX Runtime C++ API + NLLB-200 distilled 600M |
| GPU 加速 | DirectML (Windows 10+) / CUDA (NVIDIA) |
| UI | Win32 API + GDI+ |
| 目标平台 | Windows 10/11 x64 |

## 项目结构 / Project Structure

```
WindowsSimultaneousInterpreter/
├── CMakeLists.txt              # CMake 构建配置（MSVC 2022）
├── src/
│   ├── main.cpp                # 应用入口（系统托盘 + 消息循环）
│   ├── AudioCapture.h/.cpp     # WASAPI Loopback 音频采集
│   ├── TranscriptionEngine.h/.cpp  # ONNX Whisper 语音转文字
│   ├── TranslationEngine.h/.cpp    # ONNX NLLB-200 翻译
│   ├── Pipeline.h/.cpp         # 异步 Whisper→NLLB 流水线
│   └── UI/
│       ├── OverlayWindow.h/.cpp    # Win32 透明悬浮窗口
│       └── TextRenderer.h/.cpp     # GDI+ 双语文本渲染
├── models/
│   └── README.md               # 模型下载说明
└── README.md                   # 本文件
```

## 构建说明 / Build Instructions

### 前置要求 / Prerequisites

1. **Visual Studio 2022** (Community Edition 即可)
   - 安装组件: "使用 C++ 的桌面开发"
2. **CMake 3.21+** (VS 2022 自带)
3. **ONNX Runtime** (v1.16+)
   - 下载: https://github.com/microsoft/onnxruntime/releases
   - 选择 `onnxruntime-win-x64-*.zip`

### 构建步骤 / Build Steps

```powershell
# 1. 下载并解压 ONNX Runtime
# 解压到: C:\libs\onnxruntime

# 2. 创建构建目录
cd WindowsSimultaneousInterpreter
cmake -B build -A x64 -DONNXRUNTIME_DIR="C:\libs\onnxruntime"

# 3. 编译 (Release)
cmake --build build --config Release

# 4. 运行
.\build\bin\Release\WindowsSimultaneousInterpreter.exe --model-dir .\models
```

### 开发者模式构建（无 ONNX Runtime）

如果不安装 ONNX Runtime，项目仍可编译和运行（模拟模式）:

```powershell
cmake -B build -A x64
cmake --build build --config Release
.\build\bin\Release\WindowsSimultaneousInterpreter.exe
```

模拟模式会生成伪转写和翻译结果，用于 UI 和流水线测试。

## 模型准备 / Model Setup

请参阅 [models/README.md](models/README.md) 下载所需模型文件。

将模型文件放入 `models/` 目录:

```
models/
├── whisper-base.onnx            # ~150 MB
├── whisper-tokenizer.json
├── nllb-distilled-600M.onnx     # ~1.2 GB
└── nllb-tokenizer.json
```

## 使用说明 / Usage

1. **启动应用**: 双击 `WindowsSimultaneousInterpreter.exe` 或从命令行运行
2. **系统托盘**: 应用启动后，右下角通知区域会出现图标
3. **开始采集**: 右键托盘图标 → "开始采集"
4. **悬浮窗**: 底部居中会出现透明悬浮窗，显示双语翻译文本
5. **拖拽移动**: 拖拽悬浮窗到任意位置
6. **停止采集**: 右键托盘图标 → "停止采集"

### 命令行参数

```powershell
# 指定模型目录
.\WindowsSimultaneousInterpreter.exe --model-dir D:\models
```

## 架构设计 / Architecture

### 流水线 / Pipeline

```
┌──────────────┐     PCM 16kHz     ┌──────────────┐
│  WASAPI      │ ─────────────────→ │  Audio Queue │
│  Loopback    │                   │  + VAD       │
└──────────────┘                   └──────┬───────┘
                                          │ chunks
                                          ▼
                                   ┌──────────────┐
                                   │   Whisper    │
                                   │   (ONNX)     │
                                   └──────┬───────┘
                                          │ text
                                          ▼
                                   ┌──────────────┐
                                   │  English     │ ← 即时显示 (分段揭示)
                                   │  Ready       │
                                   └──────┬───────┘
                                          │ text
                                          ▼
                                   ┌──────────────┐
                                   │  NLLB-200    │
                                   │  (ONNX)      │
                                   └──────┬───────┘
                                          │ translation
                                          ▼
                                   ┌──────────────┐
                                   │  Bilingual   │ → 透明悬浮窗
                                   │  Segment     │
                                   └──────────────┘
```

### 分段揭示 (Staged Reveal)

英文转写结果立即显示，中文翻译以 "翻译中..." 占位，
翻译完成后自动替换，提供最佳用户体验。

### 线程模型

| 线程 | 职责 |
|------|------|
| UI 线程 | Win32 消息循环 + GDI+ 绘制 |
| 音频采集线程 | WASAPI COM 操作 + 音频采集 |
| 音频处理线程 | VAD + 分段 + 任务调度 |
| 线程池 | Whisper 转写 + NLLB 翻译 (std::async) |

## 与 macOS 版的差异 / Differences from macOS

| 方面 | macOS | Windows |
|------|-------|---------|
| 语言 | Swift | C++17 |
| 音频采集 | AVAudioEngine (麦克风) | WASAPI Loopback (系统音频) |
| AI 推理框架 | MLX (Apple Silicon) | ONNX Runtime (跨平台) |
| GPU 加速 | Apple Neural Engine | DirectML / CUDA |
| UI 框架 | SwiftUI + NSWindow | Win32 API + GDI+ |
| 窗口效果 | NSVisualEffectView | DWM ExtendFrameIntoClientArea |
| 状态栏 | NSStatusItem | 系统托盘图标 |

## 隐私 / Privacy

- ✅ 所有音频处理完全在本地完成
- ✅ 所有 AI 推理完全在本地完成
- ✅ 没有任何网络通信
- ✅ 没有遥测或数据收集
- ✅ 悬浮窗显示 "Privacy: Local Processing Only" 指示器

## 已知限制 / Known Limitations

1. **独占模式应用**: 使用 WASAPI 独占模式的应用（部分游戏）无法被 loopback 捕获
2. **ONNX 模型转换**: Whisper 和 NLLB 模型需要导出为 ONNX 格式
3. **DPI 缩放**: 当前 DPI 感知支持为基本级别
4. **多显示器**: 窗口默认位于主显示器

## 许可证 / License

与主项目相同。请参阅 [../../LICENSE](../../LICENSE)。

---

**基于 P2.1 Windows Audio Spike 验证结果 — WASAPI Loopback 可行，无需第三方驱动。**
