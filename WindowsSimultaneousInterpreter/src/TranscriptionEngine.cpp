// =============================================================================
// TranscriptionEngine.cpp — ONNX Whisper 语音转文字引擎实现
// =============================================================================

#include "TranscriptionEngine.h"
#include <iostream>
#include <fstream>
#include <cmath>
#include <algorithm>

#ifndef HAS_ONNXRUNTIME
#include <chrono>
#include <random>
#endif

namespace SimultaneousInterpreter {

TranscriptionEngine::TranscriptionEngine() {
#ifdef HAS_ONNXRUNTIME
    try {
        m_env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "WhisperTranscription");
        m_sessionOptions = std::make_unique<Ort::SessionOptions>();
        m_sessionOptions->SetIntraOpNumThreads(4);
        m_sessionOptions->SetInterOpNumThreads(2);
        m_sessionOptions->SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_EXTENDED);
        std::cout << "[TranscriptionEngine] ONNX Runtime 环境已初始化" << std::endl;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranscriptionEngine] ONNX Runtime 初始化失败: " << e.what() << std::endl;
    }
#else
    std::cout << "[TranscriptionEngine] 模拟模式 — 未启用 ONNX Runtime" << std::endl;
#endif
}

TranscriptionEngine::~TranscriptionEngine() { stop(); }

bool TranscriptionEngine::initialize(const std::string& modelPath, const std::string& tokenizerPath) {
    std::lock_guard<std::mutex> lock(m_mutex);

#ifdef HAS_ONNXRUNTIME
    try {
        m_session = std::make_unique<Ort::Session>(*m_env, modelPath.c_str(), *m_sessionOptions);
        std::cout << "[TranscriptionEngine] Whisper 模型已加载: " << modelPath << std::endl;

        Ort::AllocatorWithDefaultOptions allocator;
        std::cout << "[TranscriptionEngine] 输入数: " << m_session->GetInputCount() << std::endl;
        std::cout << "[TranscriptionEngine] 输出数: " << m_session->GetOutputCount() << std::endl;

        loadTokenizer(tokenizerPath);
        if (m_vocab.empty()) {
            m_vocab.resize(256);
            for (int i = 0; i < 256; ++i) m_vocab[i] = std::string(1, static_cast<char>(i));
            m_vocabSize = 256;
        }

        m_initialized.store(true);
        return true;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranscriptionEngine] 模型加载失败: " << e.what() << std::endl;
        return false;
    }
#else
    std::cout << "[TranscriptionEngine] 模拟模式初始化完成 (模型: " << modelPath << ")" << std::endl;
    m_vocab.resize(256);
    for (int i = 0; i < 256; ++i) m_vocab[i] = std::string(1, static_cast<char>(i));
    m_vocabSize = 256;
    m_initialized.store(true);
    return true;
#endif
}

TranscriptionResult TranscriptionEngine::transcribe(const std::vector<int16_t>& pcmData) {
    std::lock_guard<std::mutex> lock(m_mutex);
    TranscriptionResult result;
    result.language = "en";
    result.confidence = 0.0f;
    result.durationSeconds = static_cast<double>(pcmData.size()) / TARGET_SAMPLE_RATE;

    if (!m_initialized.load() || pcmData.empty()) return result;

    auto floatSamples = pcmToFloat(pcmData);
    if (floatSamples.empty()) return result;

    auto melSpec = computeLogMelSpectrogram(floatSamples, TARGET_SAMPLE_RATE);
    if (melSpec.empty()) return result;

    int nFrames = static_cast<int>(floatSamples.size()) / HOP_LENGTH;
    if (nFrames < 2) return result;

    auto tokenIds = runInference(melSpec, nFrames);
    result.text = decodeTokens(tokenIds);
    result.confidence = result.text.empty() ? 0.0f : 0.85f;
    return result;
}

void TranscriptionEngine::stop() {
    m_initialized.store(false);
    m_session.reset(); m_sessionOptions.reset(); m_env.reset();
}

std::vector<float> TranscriptionEngine::pcmToFloat(const std::vector<int16_t>& pcm) const {
    std::vector<float> floats(pcm.size());
    for (size_t i = 0; i < pcm.size(); ++i)
        floats[i] = static_cast<float>(pcm[i]) / static_cast<float>(INT16_MAX);
    return floats;
}

std::vector<float> TranscriptionEngine::computeLogMelSpectrogram(
    const std::vector<float>& samples, int sampleRate) const
{
    if (samples.empty()) return {};
    int nFrames = static_cast<int>(samples.size()) / HOP_LENGTH;
    if (nFrames <= 0) return {};

    auto window = hannWindow(N_FFT);
    int nFreq = N_FFT / 2 + 1;
    std::vector<float> powerSpectrum(nFrames * nFreq, 0.0f);

    for (int frame = 0; frame < nFrames; ++frame) {
        int start = frame * HOP_LENGTH;
        std::vector<float> windowed(N_FFT);
        for (int i = 0; i < N_FFT && (start + i) < static_cast<int>(samples.size()); ++i)
            windowed[i] = samples[start + i] * window[i];

        for (int bin = 0; bin < nFreq; ++bin) {
            float re = 0.0f, im = 0.0f;
            double freq = 2.0 * 3.14159265358979323846 * bin / N_FFT;
            for (int i = 0; i < N_FFT; ++i) {
                re += windowed[i] * static_cast<float>(cos(freq * i));
                im += windowed[i] * static_cast<float>(sin(freq * i));
            }
            powerSpectrum[frame * nFreq + bin] = re * re + im * im;
        }
    }

    std::vector<float> melSpec(N_MEL * nFrames);
    for (int frame = 0; frame < nFrames; ++frame) {
        for (int mel = 0; mel < N_MEL; ++mel) {
            float sum = 0.0f;
            int binStart = mel * nFreq / N_MEL;
            int binEnd = (mel + 1) * nFreq / N_MEL;
            for (int bin = binStart; bin < binEnd && bin < nFreq; ++bin)
                sum += powerSpectrum[frame * nFreq + bin];
            melSpec[frame * N_MEL + mel] = std::log(sum + 1e-10f);
        }
    }
    return melSpec;
}

std::vector<float> TranscriptionEngine::hannWindow(int width) const {
    std::vector<float> window(width);
    for (int i = 0; i < width; ++i)
        window[i] = 0.5f * (1.0f - std::cos(2.0f * 3.14159265358979323846f * i / (width - 1)));
    return window;
}

bool TranscriptionEngine::loadTokenizer(const std::string& tokenizerPath) {
    std::ifstream file(tokenizerPath);
    if (!file.is_open()) {
        std::cerr << "[TranscriptionEngine] 无法打开 tokenizer: " << tokenizerPath << std::endl;
        return false;
    }
    std::cout << "[TranscriptionEngine] Tokenizer 已加载 (简化模式)" << std::endl;
    m_vocabSize = 51865;
    m_vocab.resize(m_vocabSize);
    return true;
}

std::string TranscriptionEngine::decodeTokens(const std::vector<int64_t>& tokenIds) const {
    std::string text;
    for (auto id : tokenIds) {
        if (id >= 50257) continue;
        if (id >= 0 && id < static_cast<int64_t>(m_vocab.size()))
            text += m_vocab[static_cast<size_t>(id)];
    }
    while (!text.empty() && text[0] == '<') {
        auto end = text.find('>');
        if (end == std::string::npos) break;
        text = text.substr(end + 1);
    }
    return text;
}

std::vector<int64_t> TranscriptionEngine::runInference(
    const std::vector<float>& melSpec, int nFrames)
{
#ifdef HAS_ONNXRUNTIME
    try {
        Ort::AllocatorWithDefaultOptions allocator;
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        std::vector<int64_t> inputShape = {1, N_MEL, nFrames};
        Ort::Value inputTensor = Ort::Value::CreateTensor<float>(
            memInfo, const_cast<float*>(melSpec.data()), melSpec.size(),
            inputShape.data(), inputShape.size());

        std::vector<int64_t> outputShape = {1, MAX_TOKENS};
        Ort::Value outputTensor = Ort::Value::CreateTensor<int64_t>(
            memInfo, new int64_t[MAX_TOKENS]{0}, MAX_TOKENS,
            outputShape.data(), outputShape.size());

        auto inputName = m_session->GetInputNameAllocated(0, allocator);
        auto outputName = m_session->GetOutputNameAllocated(0, allocator);
        const char* inputNames[] = {inputName.get()};
        const char* outputNames[] = {outputName.get()};

        m_session->Run(Ort::RunOptions{nullptr}, inputNames, &inputTensor, 1,
                       outputNames, &outputTensor, 1);

        auto* outputData = outputTensor.GetTensorMutableData<int64_t>();
        auto info = outputTensor.GetTensorTypeAndShapeInfo();
        size_t size = info.GetElementCount();
        std::vector<int64_t> tokens(outputData, outputData + size);
        delete[] outputData;
        return tokens;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranscriptionEngine] 推理失败: " << e.what() << std::endl;
        return {};
    }
#else
    // 模拟模式
    static int callCount = 0;
    callCount++;
    if (callCount % 3 == 0) return {};
    std::string texts[] = {
        "This is a test of the system.",
        "Welcome to the meeting everyone.",
        "Let's discuss the project timeline.",
        "The results are very promising.",
        "Can you hear me clearly?",
    };
    std::string text = texts[callCount % 5];
    std::vector<int64_t> tokens;
    for (char c : text) tokens.push_back(static_cast<int64_t>(static_cast<unsigned char>(c)));
    return tokens;
#endif
}

} // namespace SimultaneousInterpreter
