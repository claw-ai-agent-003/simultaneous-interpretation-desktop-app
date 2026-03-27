// =============================================================================
// TranscriptionEngine.h — ONNX Whisper 语音转文字引擎
// =============================================================================
// 功能说明:
//   使用 ONNX Runtime C++ API 加载 Whisper-base 模型，
//   将 16kHz mono PCM 音频转换为文字。
//
// 与 macOS 版的区别:
//   - macOS 使用 MLX 框架（仅支持 Apple Silicon）
//   - Windows 使用 ONNX Runtime（跨平台，支持 CUDA/DML 加速）
//
// 模型输入:
//   - log-mel 频谱图 (Tensor): shape [1, 80, nFrames]
//     - 80 mel 频带（Whisper 标准配置）
//     - 16kHz 采样率，25ms 窗口，10ms 步长
//
// 模型输出:
//   - token_ids (Tensor): shape [1, maxTokens]
//
// 依赖:
//   - ONNX Runtime >= 1.16
// =============================================================================

#pragma once

#include <string>
#include <vector>
#include <memory>
#include <mutex>
#include <atomic>

// ONNX Runtime C++ API
#include <onnxruntime_cxx_api.h>

namespace SimultaneousInterpreter {

// =============================================================================
// 转写结果
// =============================================================================
struct TranscriptionResult {
    std::string text;           // 转写文本
    std::string language;       // 检测到的语言 (BCP-47, 如 "en", "zh")
    float confidence;           // 置信度 [0.0, 1.0]
    double durationSeconds;     // 音频时长（秒）
};

// =============================================================================
// TranscriptionEngine — Whisper 语音转文字引擎
// =============================================================================
class TranscriptionEngine {
public:
    /// 构造函数（不加载模型，需调用 initialize）
    TranscriptionEngine();

    /// 析构函数 — 释放 ONNX Runtime 资源
    ~TranscriptionEngine();

    // 禁止拷贝
    TranscriptionEngine(const TranscriptionEngine&) = delete;
    TranscriptionEngine& operator=(const TranscriptionEngine&) = delete;

    /// 初始化引擎并加载 Whisper ONNX 模型
    /// @param modelPath   ONNX 模型文件路径（.onnx）
    /// @param tokenizerPath  tokenizer.json 文件路径
    /// @return 成功返回 true
    bool initialize(const std::string& modelPath, const std::string& tokenizerPath);

    /// 检查引擎是否已初始化
    bool isInitialized() const { return m_initialized.load(); }

    /// 执行语音转文字
    /// @param pcmData 16kHz mono Int16 PCM 音频数据
    /// @return 转写结果
    TranscriptionResult transcribe(const std::vector<int16_t>& pcmData);

    /// 停止引擎，释放资源
    void stop();

    /// 获取源语言（Whisper 默认 "en"）
    const std::string& sourceLanguage() const { return m_sourceLanguage; }

private:
    // ---- 音频预处理 ----

    /// 将 Int16 PCM 转为归一化浮点采样 [-1.0, 1.0]
    std::vector<float> pcmToFloat(const std::vector<int16_t>& pcm) const;

    /// 计算 log-mel 频谱图
    /// @param samples   浮点采样数据
    /// @param sampleRate 采样率
    /// @return 频谱图数据 [nMel * nFrames]
    std::vector<float> computeLogMelSpectrogram(
        const std::vector<float>& samples,
        int sampleRate
    ) const;

    /// 计算 Hann 窗函数
    std::vector<float> hannWindow(int width) const;

    // ---- Tokenizer ----

    /// 加载 tokenizer 词汇表
    bool loadTokenizer(const std::string& tokenizerPath);

    /// 将 token IDs 解码为文本
    std::string decodeTokens(const std::vector<int64_t>& tokenIds) const;

    // ---- ONNX Runtime 推理 ----

    /// 运行 ONNX 模型推理
    /// @param melSpec log-mel 频谱图数据 [nMel * nFrames]
    /// @param nFrames 帧数
    /// @return 输出 token IDs
    std::vector<int64_t> runInference(
        const std::vector<float>& melSpec,
        int nFrames
    );

    // ONNX Runtime 对象
    std::unique_ptr<Ort::Env>      m_env;
    std::unique_ptr<Ort::Session>   m_session;
    std::unique_ptr<Ort::SessionOptions> m_sessionOptions;

    // 模型状态
    std::atomic<bool> m_initialized{false};

    // Whisper 模型参数
    static constexpr int N_MEL = 80;           // Mel 频带数
    static constexpr int N_FFT = 400;          // FFT 窗口大小 (25ms @ 16kHz)
    static constexpr int HOP_LENGTH = 160;     // 步长 (10ms @ 16kHz)
    static constexpr int MAX_TOKENS = 448;     // 最大输出 token 数
    static constexpr int TARGET_SAMPLE_RATE = 16000;

    // Tokenizer 词汇表 (简化版，实际应从 tokenizer.json 加载)
    std::vector<std::string> m_vocab;
    int m_vocabSize{0};

    // 源语言
    std::string m_sourceLanguage = "en";

    // 线程安全
    mutable std::mutex m_mutex;
};

} // namespace SimultaneousInterpreter
