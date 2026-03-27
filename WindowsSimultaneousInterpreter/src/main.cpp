// =============================================================================
// main.cpp — Windows 同传桌面应用入口
// =============================================================================
// 功能说明:
//   应用程序主入口，负责:
//   1. 初始化 COM 和 GDI+
//   2. 创建系统托盘图标（系统通知区域）
//   3. 初始化 Whisper 转写引擎和 NLLB 翻译引擎
//   4. 启动异步翻译流水线
//   5. 创建透明悬浮窗口
//   6. 运行 Windows 消息循环
//
// 使用方法:
//   WindowsSimultaneousInterpreter.exe [--model-dir <path>]
//
// 命令行参数:
//   --model-dir <path>  模型文件目录路径（默认: ./models）
//                       该目录应包含:
//                       - whisper-base.onnx (Whisper 模型)
//                       - whisper-tokenizer.json (Whisper tokenizer)
//                       - nllb-distilled-600M.onnx (NLLB 模型)
//                       - nllb-tokenizer.json (NLLB tokenizer)
//
// 系统托盘菜单:
//   - 开始采集 (Start Capture)
//   - 停止采集 (Stop Capture)
//   - 退出 (Quit)
//
// 与 macOS 版对应:
//   macOS: AppDelegate.swift → main.swift
//   Windows: main.cpp（合并在一个文件中）
// =============================================================================

#include <Windows.h>
#include <shellapi.h>
#include <string>
#include <memory>
#include <iostream>
#include <filesystem>

#include "AudioCapture.h"
#include "TranscriptionEngine.h"
#include "TranslationEngine.h"
#include "Pipeline.h"
#include "UI/OverlayWindow.h"

// =============================================================================
// 全局状态
// =============================================================================
namespace {

// 引擎和流水线
std::shared_ptr<SimultaneousInterpreter::AudioCapture>          g_audioCapture;
std::shared_ptr<SimultaneousInterpreter::TranscriptionEngine>   g_transcription;
std::shared_ptr<SimultaneousInterpreter::TranslationEngine>    g_translation;
std::shared_ptr<SimultaneousInterpreter::Pipeline>             g_pipeline;
std::shared_ptr<SimultaneousInterpreter::OverlayWindow>        g_overlay;

// 状态
bool g_isCapturing = false;
std::string g_modelDir = "./models";

// 托盘图标
HWND g_hwnd = nullptr;
NOTIFYICONDATAW g_nid = {};
UINT WM_TRAYICON = 0;

// 消息循环控制
HMENU g_trayMenu = nullptr;

} // anonymous namespace

// =============================================================================
// 函数声明
// =============================================================================
LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
bool initializeEngines();
void startCapture();
void stopCapture();
void cleanup();
std::string parseArgs(int argc, wchar_t* argv[]);

// =============================================================================
// WinMain — 应用程序入口
// =============================================================================
int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR lpCmdLine, int nCmdShow) {
    // 解析命令行参数
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(lpCmdLine, &argc);
    if (argc > 0 && argv) {
        g_modelDir = parseArgs(argc, argv);
    }
    LocalFree(argv);

    std::cout << "==========================================================" << std::endl;
    std::cout << "  Windows 同时传译桌面应用 v0.1.0" << std::endl;
    std::cout << "  Privacy-First Offline Simultaneous Translation" << std::endl;
    std::cout << "==========================================================" << std::endl;
    std::cout << "  模型目录: " << g_modelDir << std::endl;

    // ---- 初始化 COM（单线程模式 — 用于 UI 线程） ----
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) {
        std::cerr << "COM 初始化失败" << std::endl;
        return 1;
    }

    // ---- 注册窗口类 ----
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.style = 0;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"SimultaneousInterpreterMain";

    if (!RegisterClassExW(&wc)) {
        std::cerr << "注册窗口类失败" << std::endl;
        CoUninitialize();
        return 1;
    }

    // ---- 创建隐藏主窗口（仅用于消息处理） ----
    g_hwnd = CreateWindowExW(
        0,
        L"SimultaneousInterpreterMain",
        L"Simultaneous Interpreter",
        0, 0, 0, 0, 0,
        HWND_MESSAGE,  // 仅消息窗口，不显示
        nullptr, hInstance, nullptr
    );

    if (!g_hwnd) {
        std::cerr << "创建主窗口失败" << std::endl;
        CoUninitialize();
        return 1;
    }

    // ---- 注册托盘图标消息 ----
    WM_TRAYICON = RegisterWindowMessageW(L"WM_TRAYICON_SIMULTANEOUS_INTERPRETER");

    // ---- 创建系统托盘图标 ----
    g_nid.cbSize = sizeof(NOTIFYICONDATAW);
    g_nid.hWnd = g_hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAYICON;
    g_nid.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcscpy_s(g_nid.szTip, L"Simultaneous Interpreter / 同时传译");

    Shell_NotifyIconW(NIM_ADD, &g_nid);

    // ---- 创建悬浮窗口 ----
    g_overlay = std::make_shared<SimultaneousInterpreter::OverlayWindow>();
    g_overlay->create();

    // ---- 初始化引擎 ----
    if (!initializeEngines()) {
        std::cerr << "引擎初始化失败 — 应用将以模拟模式运行" << std::endl;
    }

    std::cout << std::endl;
    std::cout << "应用已启动。右键点击系统托盘图标进行控制。" << std::endl;

    // ---- 消息循环 ----
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        if (msg.message == WM_TRAYICON) {
            switch (LOWORD(msg.lParam)) {
            case WM_RBUTTONUP: {
                // 右键点击托盘图标 — 显示菜单
                POINT pt;
                GetCursorPos(&pt);
                SetForegroundWindow(g_hwnd);

                g_trayMenu = CreatePopupMenu();
                AppendMenuW(g_trayMenu, MF_STRING | (g_isCapturing ? MF_GRAYED : 0),
                    1, L"开始采集 / Start Capture");
                AppendMenuW(g_trayMenu, MF_STRING | (!g_isCapturing ? MF_GRAYED : 0),
                    2, L"停止采集 / Stop Capture");
                AppendMenuW(g_trayMenu, MF_SEPARATOR, 0, nullptr);
                AppendMenuW(g_trayMenu, MF_STRING, 3, L"退出 / Quit");

                TrackPopupMenu(g_trayMenu, TPM_RIGHTALIGN, pt.x, pt.y, 0, g_hwnd, nullptr);
                DestroyMenu(g_trayMenu);
                break;
            }
            case WM_LBUTTONDBCLK:
                // 双击托盘图标 — 切换采集
                if (g_isCapturing) {
                    stopCapture();
                } else {
                    startCapture();
                }
                break;
            }
            continue;
        }

        switch (msg.message) {
        case WM_COMMAND:
            switch (LOWORD(msg.wParam)) {
            case 1: // 开始采集
                startCapture();
                break;
            case 2: // 停止采集
                stopCapture();
                break;
            case 3: // 退出
                cleanup();
                PostQuitMessage(0);
                return 0;
            }
            break;

        case WM_DESTROY:
            cleanup();
            PostQuitMessage(0);
            return 0;
        }

        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    // ---- 清理 ----
    cleanup();
    CoUninitialize();

    return 0;
}

// =============================================================================
// 窗口过程
// =============================================================================
LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// =============================================================================
// 初始化引擎
// =============================================================================
bool initializeEngines() {
    // 构建模型路径
    std::string whisperModelPath = g_modelDir + "/whisper-base.onnx";
    std::string whisperTokenizerPath = g_modelDir + "/whisper-tokenizer.json";
    std::string nllbModelPath = g_modelDir + "/nllb-distilled-600M.onnx";
    std::string nllbTokenizerPath = g_modelDir + "/nllb-tokenizer.json";

    // ---- 创建转写引擎 (Whisper) ----
    g_transcription = std::make_shared<SimultaneousInterpreter::TranscriptionEngine>();
    if (!g_transcription->initialize(whisperModelPath, whisperTokenizerPath)) {
        std::cerr << "[Main] Whisper 引擎初始化失败" << std::endl;
        std::cerr << "[Main] 请将 whisper-base.onnx 放置在: " << g_modelDir << std::endl;
        // 继续运行（模拟模式）
    }

    // ---- 创建翻译引擎 (NLLB-200) ----
    g_translation = std::make_shared<SimultaneousInterpreter::TranslationEngine>();
    if (!g_translation->initialize(nllbModelPath, nllbTokenizerPath)) {
        std::cerr << "[Main] NLLB 引擎初始化失败" << std::endl;
        std::cerr << "[Main] 请将 nllb-distilled-600M.onnx 放置在: " << g_modelDir << std::endl;
        // 继续运行（模拟模式）
    }

    // ---- 创建流水线 ----
    g_pipeline = std::make_shared<SimultaneousInterpreter::Pipeline>();
    SimultaneousInterpreter::PipelineConfig config;
    config.sourceLanguage = "en";
    config.targetLanguage = "zh";
    config.minAudioDurationSeconds = 1.0;
    config.maxAudioDurationSeconds = 30.0;

    if (!g_pipeline->initialize(g_transcription, g_translation, config)) {
        std::cerr << "[Main] 流水线初始化失败" << std::endl;
        return false;
    }

    // ---- 设置流水线回调 ----

    // 英文就绪回调（分段揭示：英文先出现）
    g_pipeline->setEnglishReadyHandler([](const SimultaneousInterpreter::EnglishReadyEvent& event) {
        std::cout << "[English Ready] [" << event.chunkIndex << "] "
                  << event.english.substr(0, 50)
                  << (event.english.size() > 50 ? "..." : "") << std::endl;

        if (g_overlay) {
            g_overlay->showPartialSegment(event.chunkIndex, event.english, event.confidence);
        }
    });

    // 完整双语文本回调
    g_pipeline->setSegmentHandler([](const SimultaneousInterpreter::BilingualSegment& segment) {
        std::cout << "[Segment] EN: " << segment.english.substr(0, 30)
                  << " → ZH: " << segment.mandarin.substr(0, 20) << std::endl;
    });

    // 翻译完成回调 — 填充中文翻译
    g_pipeline->setEventHandler([](const std::string& event) {
        // 解析事件以提取翻译完成信息
        // 格式: "[Pipeline] 片段 N 翻译完成 (Xms): <text>"
        if (event.find("翻译完成") != std::string::npos ||
            event.find("Translation complete") != std::string::npos) {

            // 提取片段索引
            size_t idx = event.find("片段 ");
            if (idx != std::string::npos) {
                idx += 7; // "片段 " 的长度
                int chunkIndex = 0;
                while (idx < event.size() && isdigit(event[idx])) {
                    chunkIndex = chunkIndex * 10 + (event[idx] - '0');
                    idx++;
                }

                // 提取翻译文本
                size_t textIdx = event.find("): ");
                if (textIdx != std::string::npos) {
                    textIdx += 3;
                    std::string mandarin = event.substr(textIdx);
                    // 去除末尾的 "..." 或换行
                    while (!mandarin.empty() && (mandarin.back() == '.' || mandarin.back() == '\n')) {
                        mandarin.pop_back();
                    }

                    if (g_overlay && !mandarin.empty()) {
                        g_overlay->finalizePartialSegment(chunkIndex, mandarin);
                    }
                }
            }
        }
    });

    return true;
}

// =============================================================================
// 开始采集
// =============================================================================
void startCapture() {
    if (g_isCapturing) return;

    std::cout << "\n--- 开始采集 ---" << std::endl;

    // 打印默认音频设备
    if (g_audioCapture) {
        std::cout << "音频设备: " << g_audioCapture->getDefaultDeviceName() << std::endl;
    }

    // 创建音频采集器
    if (!g_audioCapture) {
        g_audioCapture = std::make_shared<SimultaneousInterpreter::AudioCapture>();
    }

    // 音频电平回调 → 更新悬浮窗音量表
    g_audioCapture->start(
        [](float level) {
            if (g_overlay) {
                g_overlay->updateAudioLevel(level);
            }
        },
        [](const std::vector<int16_t>& buffer) {
            // 音频数据回调 → 喂入流水线
            if (g_pipeline && g_pipeline->isRunning()) {
                g_pipeline->feedAudioBuffer(buffer);
            }
        }
    );

    // 启动流水线
    if (g_pipeline) {
        g_pipeline->start();
    }

    g_isCapturing = true;

    // 更新托盘提示
    g_nid.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wcscpy_s(g_nid.szTip, L"正在采集 / Capturing...");
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    std::cout << "采集已启动 (WASAPI Loopback)" << std::endl;
}

// =============================================================================
// 停止采集
// =============================================================================
void stopCapture() {
    if (!g_isCapturing) return;

    std::cout << "\n--- 停止采集 ---" << std::endl;

    if (g_audioCapture) {
        g_audioCapture->stop();
    }

    if (g_pipeline) {
        g_pipeline->stop();
    }

    if (g_overlay) {
        g_overlay->endSession();
    }

    g_isCapturing = false;

    // 更新托盘提示
    wcscpy_s(g_nid.szTip, L"Simultaneous Interpreter / 同时传译");
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);

    std::cout << "采集已停止" << std::endl;
}

// =============================================================================
// 清理资源
// =============================================================================
void cleanup() {
    stopCapture();

    if (g_pipeline)     g_pipeline.reset();
    if (g_translation)  g_translation->stop();
    if (g_transcription) g_transcription->stop();
    if (g_audioCapture) g_audioCapture.reset();
    if (g_overlay)      g_overlay->destroy();
    g_overlay.reset();

    // 移除托盘图标
    Shell_NotifyIconW(NIM_DELETE, &g_nid);

    std::cout << "[Main] 资源已释放" << std::endl;
}

// =============================================================================
// 解析命令行参数
// =============================================================================
std::string parseArgs(int argc, wchar_t* argv[]) {
    for (int i = 0; i < argc - 1; ++i) {
        std::wstring arg = argv[i];
        if (arg == L"--model-dir" && i + 1 < argc) {
            // 转换 Wide String 为 UTF-8
            int len = WideCharToMultiByte(CP_UTF8, 0, argv[i + 1], -1, nullptr, 0, nullptr, nullptr);
            if (len > 0) {
                std::string result(len - 1, '\0');
                WideCharToMultiByte(CP_UTF8, 0, argv[i + 1], -1, result.data(), len, nullptr, nullptr);
                return result;
            }
        }
    }
    return "./models";
}
