// =============================================================================
// Pipeline.cpp — 异步翻译流水线实现
// =============================================================================

#include "Pipeline.h"
#include <iostream>
#include <algorithm>
#include <numeric>

namespace SimultaneousInterpreter {

Pipeline::Pipeline() {
    std::cout << "[Pipeline] 流水线已创建" << std::endl;
}

Pipeline::~Pipeline() { stop(); }

bool Pipeline::initialize(
    std::shared_ptr<TranscriptionEngine> transcription,
    std::shared_ptr<TranslationEngine> translation,
    const PipelineConfig& config)
{
    if (!transcription || !translation) {
        std::cerr << "[Pipeline] 转写引擎和翻译引擎不能为空" << std::endl;
        return false;
    }
    if (!transcription->isInitialized()) {
        std::cerr << "[Pipeline] 转写引擎未初始化" << std::endl;
        return false;
    }
    if (!translation->isInitialized()) {
        std::cerr << "[Pipeline] 翻译引擎未初始化" << std::endl;
        return false;
    }

    m_transcription = transcription;
    m_translation = translation;
    m_config = config;

    std::cout << "[Pipeline] 流水线初始化完成" << std::endl;
    std::cout << "[Pipeline] " << m_config.sourceLanguage << " → "
              << m_config.targetLanguage << std::endl;
    return true;
}

void Pipeline::setSegmentHandler(std::function<void(const BilingualSegment&)> handler) {
    m_onSegment = std::move(handler);
}

void Pipeline::setEnglishReadyHandler(std::function<void(const EnglishReadyEvent&)> handler) {
    m_onEnglishReady = std::move(handler);
}

void Pipeline::setEventHandler(std::function<void(const std::string&)> handler) {
    m_onEvent = std::move(handler);
}

void Pipeline::start() {
    if (m_isRunning.load()) return;
    m_isRunning.store(true);
    m_chunkIndex.store(0);
    m_activeTranscriptions.store(0);
    m_speechFrames = 0;
    m_silenceFrames = 0;

    { std::lock_guard<std::mutex> lock(m_bufferMutex); m_audioBuffer.clear(); }
    { std::lock_guard<std::mutex> lock(m_queueMutex);
        std::queue<std::vector<int16_t>> empty; m_audioQueue.swap(empty); }

    m_audioThread = std::thread(&Pipeline::audioProcessingLoop, this);

    if (m_onEvent) m_onEvent("[Pipeline] 流水线已启动");
    std::cout << "[Pipeline] 流水线已启动" << std::endl;
}

void Pipeline::stop() {
    if (!m_isRunning.load()) return;
    m_isRunning.store(false);
    m_queueCondition.notify_all();
    if (m_audioThread.joinable()) m_audioThread.join();

    { std::lock_guard<std::mutex> lock(m_tasksMutex);
        for (auto& task : m_activeTasks)
            if (task.valid()) task.wait();
        m_activeTasks.clear();
    }
    std::cout << "[Pipeline] 流水线已停止" << std::endl;
}

void Pipeline::feedAudioBuffer(const std::vector<int16_t>& buffer) {
    if (!m_isRunning.load() || buffer.empty()) return;
    { std::lock_guard<std::mutex> lock(m_queueMutex); m_audioQueue.push(buffer); }
    m_queueCondition.notify_one();
}

void Pipeline::audioProcessingLoop() {
    std::cout << "[Pipeline] 音频处理线程已启动" << std::endl;

    while (m_isRunning.load()) {
        std::vector<int16_t> audioData;
        {
            std::unique_lock<std::mutex> lock(m_queueMutex);
            m_queueCondition.wait_for(lock, std::chrono::milliseconds(100), [this] {
                return !m_audioQueue.empty() || !m_isRunning.load();
            });
            if (!m_isRunning.load() && m_audioQueue.empty()) break;
            if (m_audioQueue.empty()) continue;
            audioData = std::move(m_audioQueue.front());
            m_audioQueue.pop();
        }

        auto floatSamples = pcmToFloat(audioData);
        if (floatSamples.empty()) continue;

        { std::lock_guard<std::mutex> lock(m_bufferMutex);
            m_audioBuffer.insert(m_audioBuffer.end(), floatSamples.begin(), floatSamples.end());
        }

        bool isSpeech = detectSpeech(floatSamples);

        { std::lock_guard<std::mutex> lock(m_bufferMutex);
            size_t minSamples = static_cast<size_t>(m_config.minAudioDurationSeconds * m_config.sampleRate);
            size_t maxSamples = static_cast<size_t>(m_config.maxAudioDurationSeconds * m_config.sampleRate);

            if (m_audioBuffer.size() >= minSamples) {
                bool shouldTranscribe = false;
                if (m_audioBuffer.size() >= maxSamples) {
                    shouldTranscribe = true;
                } else if (isSpeech && m_speechFrames > SPEECH_FRAMES_THRESHOLD &&
                           m_silenceFrames >= SILENCE_FRAMES_THRESHOLD) {
                    shouldTranscribe = true;
                }

                if (shouldTranscribe && m_activeTranscriptions.load() < m_config.maxConcurrentTranscriptions) {
                    size_t samplesToTake = std::min(m_audioBuffer.size(), maxSamples);
                    std::vector<int16_t> pcmChunk(samplesToTake);
                    for (size_t i = 0; i < samplesToTake; ++i)
                        pcmChunk[i] = static_cast<int16_t>(std::clamp(
                            m_audioBuffer[i] * static_cast<float>(INT16_MAX),
                            static_cast<float>(INT16_MIN), static_cast<float>(INT16_MAX)));

                    size_t overlapSamples = static_cast<size_t>(m_config.overlapSeconds * m_config.sampleRate);
                    if (m_audioBuffer.size() > samplesToTake)
                        m_audioBuffer.erase(m_audioBuffer.begin(),
                            m_audioBuffer.begin() + (samplesToTake - overlapSamples));
                    else
                        m_audioBuffer.clear();

                    m_speechFrames = 0;
                    m_silenceFrames = 0;

                    int chunkIdx = m_chunkIndex.fetch_add(1);
                    m_activeTranscriptions.fetch_add(1);

                    if (m_onEvent) {
                        std::ostringstream oss;
                        oss << "[Pipeline] 片段 " << chunkIdx << " 开始转写 ("
                            << pcmChunk.size() << " 采样)";
                        m_onEvent(oss.str());
                    }

                    auto task = std::async(std::launch::async,
                        [this, chunkIdx, pcmChunk]() { runTranscription(chunkIdx, pcmChunk); });

                    { std::lock_guard<std::mutex> lock(m_tasksMutex);
                        m_activeTasks.push_back(std::move(task)); }
                }
            }
        }
    }
    std::cout << "[Pipeline] 音频处理线程已退出" << std::endl;
}

bool Pipeline::detectSpeech(const std::vector<float>& samples) {
    if (samples.empty()) return false;
    double sum = 0.0;
    for (float s : samples) sum += static_cast<double>(s) * static_cast<double>(s);
    double energy = sum / static_cast<double>(samples.size());
    bool isLoud = energy > static_cast<double>(ENERGY_THRESHOLD);

    if (isLoud) { m_speechFrames++; m_silenceFrames = 0; }
    else { m_silenceFrames++; }

    return m_speechFrames >= SPEECH_FRAMES_THRESHOLD &&
           m_silenceFrames < SILENCE_FRAMES_THRESHOLD;
}

void Pipeline::runTranscription(int chunkIndex, std::vector<int16_t> audioData) {
    auto t0 = getCurrentTimeMs();
    auto result = m_transcription->transcribe(audioData);
    auto transcriptionMs = getCurrentTimeMs() - t0;

    std::string text = result.text;
    while (!text.empty() && (text.front() == ' ' || text.front() == '\n')) text.erase(0, 1);
    while (!text.empty() && (text.back() == ' ' || text.back() == '\n')) text.pop_back();

    if (text.empty()) {
        if (m_onEvent) m_onEvent("[Pipeline] 片段 " + std::to_string(chunkIndex) + " 转写为空");
        m_activeTranscriptions.fetch_sub(1);
        return;
    }

    if (m_onEvent) {
        std::ostringstream oss;
        oss << "[Pipeline] 片段 " << chunkIndex << " 转写完成 ("
            << transcriptionMs << "ms): " << text.substr(0, 30)
            << (text.size() > 30 ? "..." : "");
        m_onEvent(oss.str());
    }

    // 即时发送英文结果（分段揭示的第一阶段）
    if (m_onEnglishReady) {
        EnglishReadyEvent event;
        event.chunkIndex = chunkIndex;
        event.english = text;
        event.confidence = result.confidence;
        m_onEnglishReady(event);
    }

    // 异步启动翻译
    std::string textCopy = text;
    auto translationFuture = std::async(std::launch::async,
        [this, chunkIndex, textCopy]() { runTranslation(chunkIndex, textCopy); });
    { std::lock_guard<std::mutex> lock(m_tasksMutex);
        m_activeTasks.push_back(std::move(translationFuture)); }
}

void Pipeline::runTranslation(int chunkIndex, std::string text) {
    auto t0 = getCurrentTimeMs();
    auto result = m_translation->translate(text, m_config.sourceLanguage, m_config.targetLanguage);
    auto translationMs = getCurrentTimeMs() - t0;

    std::string mandarin = result.text;
    while (!mandarin.empty() && (mandarin.front() == ' ' || mandarin.front() == '\n')) mandarin.erase(0, 1);
    while (!mandarin.empty() && (mandarin.back() == ' ' || mandarin.back() == '\n')) mandarin.pop_back();

    if (m_onEvent) {
        std::ostringstream oss;
        oss << "[Pipeline] 片段 " << chunkIndex << " 翻译完成 ("
            << translationMs << "ms): " << mandarin.substr(0, 20)
            << (mandarin.size() > 20 ? "..." : "");
        m_onEvent(oss.str());
    }

    // 构建双语文本段落
    BilingualSegment segment;
    segment.english = text;
    segment.mandarin = mandarin;
    segment.confidence = result.confidence;
    segment.durationSeconds = 0.0;
    segment.producedAt = getCurrentTimeMs();

    if (m_onSegment) m_onSegment(segment);
    m_activeTranscriptions.fetch_sub(1);
}

uint64_t Pipeline::getCurrentTimeMs() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

std::vector<float> Pipeline::pcmToFloat(const std::vector<int16_t>& pcm) {
    std::vector<float> floats(pcm.size());
    for (size_t i = 0; i < pcm.size(); ++i)
        floats[i] = static_cast<float>(pcm[i]) / static_cast<float>(INT16_MAX);
    return floats;
}

} // namespace SimultaneousInterpreter
