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
// 依赖: ONNX Runtime >= 1.16
// =============================================================================

#pragma once

#include <string>
#include <vector>
#include <memory>
#include <mutex>
#include <atomic>

#include <onnxruntime_cxx_api.h>

namespace SimultaneousInterpreter {

struct TranscriptionResult {
    std::string text;
    std::string language;
    float confidence;
    double durationSeconds;
};

class TranscriptionEngine {
public:
    TranscriptionEngine();
    ~TranscriptionEngine();

    TranscriptionEngine(const TranscriptionEngine&) = delete;
    TranscriptionEngine& operator=(const TranscriptionEngine&) = delete;

    /// 初始化引擎并加载 Whisper ONNX 模型
    bool initialize(const std::string& modelPath, const std::string& tokenizerPath);

    bool isInitialized() const { return m_initialized.load(); }

    /// 执行语音转文字（输入: 16kHz mono Int16 PCM）
    TranscriptionResult transcribe(const std::vector<int16_t>& pcmData);

    void stop();

    const std::string& sourceLanguage() const { return m_sourceLanguage; }

private:
    std::vector<float> pcmToFloat(const std::vector<int16_t>& pcm) const;

    std::vector<float> computeLogMelSpectrogram(
        const std::vector<float>& samples, int sampleRate) const;

    std::vector<float> hannWindow(int width) const;

    bool loadTokenizer(const std::string& tokenizerPath);
    std::string decodeTokens(const std::vector<int64_t>& tokenIds) const;

    std::vector<int64_t> runInference(const std::vector<float>& melSpec, int nFrames);

    std::unique_ptr<Ort::Env>      m_env;
    std::unique_ptr<Ort::Session>   m_session;
    std::unique_ptr<Ort::SessionOptions> m_sessionOptions;

    std::atomic<bool> m_initialized{false};

    static constexpr int N_MEL = 80;
    static constexpr int N_FFT = 400;
    static constexpr int HOP_LENGTH = 160;
    static constexpr int MAX_TOKENS = 448;
    static constexpr int TARGET_SAMPLE_RATE = 16000;

    std::vector<std::string> m_vocab;
    int m_vocabSize{0};
    std::string m_sourceLanguage = "en";
    mutable std::mutex m_mutex;
};

} // namespace SimultaneousInterpreter
