// =============================================================================
// Pipeline.h — 异步 Whisper → NLLB 流水线
// =============================================================================
// 功能说明:
//   协调音频采集 → Whisper 转写 → NLLB 翻译的完整流水线。
//   使用 C++17 std::async + 线程池实现并发处理。
//
// 流水线架构:
//
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
// 设计要点:
//   - 分段揭示 (Staged Reveal): 英文先出现，中文 "翻译中..." 随后填充
//   - 最小延迟: Whisper 结果立即显示，不等 NLLB 完成
//   - 并发控制: 限制同时进行的转写/翻译任务数
//   - 线程安全: 使用 mutex 和 atomic 保护共享状态
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

#include "AudioCapture.h"
#include "TranscriptionEngine.h"
#include "TranslationEngine.h"

namespace SimultaneousInterpreter {

// =============================================================================
// 双语段落
// =============================================================================
struct BilingualSegment {
    std::string english;          // 英文转写
    std::string mandarin;         // 中文翻译
    float confidence;             // Whisper 置信度
    double durationSeconds;       // 音频时长
    uint64_t producedAt;          // 产生时间戳（毫秒）
};

// =============================================================================
// 英文就绪事件（分段揭示：英文先出现，中文稍后填充）
// =============================================================================
struct EnglishReadyEvent {
    int chunkIndex;               // 片段索引
    std::string english;          // 英文转写文本
    float confidence;             // 置信度
};

// =============================================================================
// 流水线配置
// =============================================================================
struct PipelineConfig {
    double minAudioDurationSeconds = 1.0;    // 最小音频时长（秒）才触发转写
    double maxAudioDurationSeconds = 30.0;   // 最大音频时长（秒）每个片段
    double overlapSeconds = 0.5;            // 连续片段之间的重叠（秒）
    int maxConcurrentTranscriptions = 2;     // 最大并发转写任务数
    std::string sourceLanguage = "en";       // 源语言 (BCP-47)
    std::string targetLanguage = "zh";       // 目标语言 (BCP-47)
    int sampleRate = 16000;                  // 音频采样率
};

// =============================================================================
// Pipeline — 异步翻译流水线
// =============================================================================
class Pipeline {
public:
    Pipeline();
    ~Pipeline();

    // 禁止拷贝
    Pipeline(const Pipeline&) = delete;
    Pipeline& operator=(const Pipeline&) = delete;

    /// 初始化流水线
    /// @param transcription 转写引擎
    /// @param translation   翻译引擎
    /// @param config        流水线配置
    bool initialize(
        std::shared_ptr<TranscriptionEngine> transcription,
        std::shared_ptr<TranslationEngine> translation,
        const PipelineConfig& config = PipelineConfig()
    );

    /// 设置双语文本回调
    void setSegmentHandler(std::function<void(const BilingualSegment&)> handler);

    /// 设置英文就绪回调（分段揭示）
    void setEnglishReadyHandler(std::function<void(const EnglishReadyEvent&)> handler);

    /// 设置事件日志回调
    void setEventHandler(std::function<void(const std::string&)> handler);

    /// 启动流水线
    void start();

    /// 停止流水线，等待所有任务完成
    void stop();

    /// 是否正在运行
    bool isRunning() const { return m_isRunning.load(); }

    /// 喂入音频数据（线程安全，可从任何线程调用）
    void feedAudioBuffer(const std::vector<int16_t>& buffer);

private:
    // ---- 音频处理线程 ----
    void audioProcessingLoop();

    // ---- VAD（语音活动检测） ----
    bool detectSpeech(const std::vector<float>& samples);

    // ---- 转写任务 ----
    void runTranscription(int chunkIndex, std::vector<int16_t> audioData);

    // ---- 翻译任务 ----
    void runTranslation(int chunkIndex, std::string text);

    // ---- 辅助 ----
    static uint64_t getCurrentTimeMs();
    static std::vector<float> pcmToFloat(const std::vector<int16_t>& pcm);

    // ---- 引擎 ----
    std::shared_ptr<TranscriptionEngine> m_transcription;
    std::shared_ptr<TranslationEngine>   m_translation;

    // ---- 配置 ----
    PipelineConfig m_config;

    // ---- 音频队列 ----
    std::queue<std::vector<int16_t>> m_audioQueue;
    std::mutex m_queueMutex;
    std::condition_variable m_queueCondition;

    // ---- 音频累积缓冲区 ----
    std::vector<float> m_audioBuffer;
    std::mutex m_bufferMutex;

    // ---- 音频处理线程 ----
    std::thread m_audioThread;
    std::atomic<bool> m_isRunning{false};

    // ---- 片段计数 ----
    std::atomic<int> m_chunkIndex{0};

    // ---- 并发控制 ----
    std::atomic<int> m_activeTranscriptions{0};

    // ---- VAD 状态 ----
    int m_speechFrames{0};
    int m_silenceFrames{0};
    static constexpr float ENERGY_THRESHOLD = 0.01f;
    static constexpr int SPEECH_FRAMES_THRESHOLD = 10;
    static constexpr int SILENCE_FRAMES_THRESHOLD = 5;

    // ---- 回调 ----
    std::function<void(const BilingualSegment&)> m_onSegment;
    std::function<void(const EnglishReadyEvent&)> m_onEnglishReady;
    std::function<void(const std::string&)> m_onEvent;

    // ---- 活跃任务跟踪 ----
    std::mutex m_tasksMutex;
    std::vector<std::future<void>> m_activeTasks;
};

} // namespace SimultaneousInterpreter
