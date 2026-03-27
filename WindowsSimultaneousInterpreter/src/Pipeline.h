// =============================================================================
// Pipeline.h — 异步 Whisper → NLLB 流水线
// =============================================================================
// 功能说明:
//   协调音频采集 → Whisper 转写 → NLLB 翻译的完整流水线。
//   使用 C++17 std::async + 线程池实现并发处理。
//
// 流水线架构:
//   [AudioCapture] --pcm data--> [Audio Queue] --chunk--> [VAD]
//       |                                                   |
//       |                                              [Whisper]
//       |                                                   |
//       |                                             [English Ready]
//       |                                              (即时显示)
//       |                                                   |
//       |                                               [NLLB-200]
//       |                                                   |
//       |                                            [Bilingual Segment]
//       |                                              (完整显示)
//       v
//   [OverlayWindow]
//
// 与 macOS 版对应:
//   macOS 使用 Swift Actor 模型
//   Windows 使用 C++ mutex + condition_variable
// =============================================================================

#pragma once

#include <string>
#include <vector>
#include <queue>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <functional>
#include <future>
#include <chrono>
#include <memory>
#include <sstream>

#include "AudioCapture.h"
#include "TranscriptionEngine.h"
#include "TranslationEngine.h"

namespace SimultaneousInterpreter {

struct BilingualSegment {
    std::string english;
    std::string mandarin;
    float confidence;
    double durationSeconds;
    uint64_t producedAt;
};

struct EnglishReadyEvent {
    int chunkIndex;
    std::string english;
    float confidence;
};

struct PipelineConfig {
    double minAudioDurationSeconds = 1.0;
    double maxAudioDurationSeconds = 30.0;
    double overlapSeconds = 0.5;
    int maxConcurrentTranscriptions = 2;
    std::string sourceLanguage = "en";
    std::string targetLanguage = "zh";
    int sampleRate = 16000;
};

class Pipeline {
public:
    Pipeline();
    ~Pipeline();

    Pipeline(const Pipeline&) = delete;
    Pipeline& operator=(const Pipeline&) = delete;

    bool initialize(std::shared_ptr<TranscriptionEngine> transcription,
        std::shared_ptr<TranslationEngine> translation,
        const PipelineConfig& config = PipelineConfig());

    void setSegmentHandler(std::function<void(const BilingualSegment&)> handler);
    void setEnglishReadyHandler(std::function<void(const EnglishReadyEvent&)> handler);
    void setEventHandler(std::function<void(const std::string&)> handler);

    void start();
    void stop();
    bool isRunning() const { return m_isRunning.load(); }

    /// 喂入音频数据（线程安全，可从任何线程调用）
    void feedAudioBuffer(const std::vector<int16_t>& buffer);

private:
    void audioProcessingLoop();
    bool detectSpeech(const std::vector<float>& samples);
    void runTranscription(int chunkIndex, std::vector<int16_t> audioData);
    void runTranslation(int chunkIndex, std::string text);

    static uint64_t getCurrentTimeMs();
    static std::vector<float> pcmToFloat(const std::vector<int16_t>& pcm);

    std::shared_ptr<TranscriptionEngine> m_transcription;
    std::shared_ptr<TranslationEngine>   m_translation;
    PipelineConfig m_config;

    std::queue<std::vector<int16_t>> m_audioQueue;
    std::mutex m_queueMutex;
    std::condition_variable m_queueCondition;

    std::vector<float> m_audioBuffer;
    std::mutex m_bufferMutex;

    std::thread m_audioThread;
    std::atomic<bool> m_isRunning{false};
    std::atomic<int> m_chunkIndex{0};
    std::atomic<int> m_activeTranscriptions{0};

    int m_speechFrames{0};
    int m_silenceFrames{0};
    static constexpr float ENERGY_THRESHOLD = 0.01f;
    static constexpr int SPEECH_FRAMES_THRESHOLD = 10;
    static constexpr int SILENCE_FRAMES_THRESHOLD = 5;

    std::function<void(const BilingualSegment&)> m_onSegment;
    std::function<void(const EnglishReadyEvent&)> m_onEnglishReady;
    std::function<void(const std::string&)> m_onEvent;

    std::mutex m_tasksMutex;
    std::vector<std::future<void>> m_activeTasks;
};

} // namespace SimultaneousInterpreter
