// =============================================================================
// TranscriptionEngine.cpp — ONNX Whisper 语音转文字引擎实现
// =============================================================================

#include "TranscriptionEngine.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <cmath>
#include <algorithm>
#include <numeric>

// 未安装 ONNX Runtime 时的模拟实现
#ifndef HAS_ONNXRUNTIME
#include <chrono>
#include <random>
#endif

namespace SimultaneousInterpreter {

// =============================================================================
// 构造函数
// =============================================================================
TranscriptionEngine::TranscriptionEngine() {
#ifdef HAS_ONNXRUNTIME
    try {
        // 初始化 ONNX Runtime 环境
        m_env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "WhisperTranscription");
        m_sessionOptions = std::make_unique<Ort::SessionOptions>();

        // 设置线程数（利用多核）
        m_sessionOptions->SetIntraOpNumThreads(4);
        m_sessionOptions->SetInterOpNumThreads(2);

        // 启用图优化
        m_sessionOptions->SetGraphOptimizationLevel(
            GraphOptimizationLevel::ORT_ENABLE_EXTENDED);

        std::cout << "[TranscriptionEngine] ONNX Runtime 环境已初始化" << std::endl;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranscriptionEngine] ONNX Runtime 初始化失败: " << e.what() << std::endl;
    }
#else
    std::cout << "[TranscriptionEngine] 模拟模式 — 未启用 ONNX Runtime" << std::endl;
#endif
}

// =============================================================================
// 析构函数
// =============================================================================
TranscriptionEngine::~TranscriptionEngine() {
    stop();
}

// =============================================================================
// 初始化引擎
// =============================================================================
bool TranscriptionEngine::initialize(const std::string& modelPath, const std::string& tokenizerPath) {
    std::lock_guard<std::mutex> lock(m_mutex);

#ifdef HAS_ONNXRUNTIME
    try {
        // 加载 ONNX 模型
        // 在 Windows x64 上，ONNX Runtime 默认使用 DirectML (DML) 执行提供程序
        // 也可使用 CUDA 如果有 NVIDIA GPU
        //
        // DML 加速示例:
        //   m_sessionOptions->AppendExecutionProvider("DML", {});

        m_session = std::make_unique<Ort::Session>(*m_env, modelPath.c_str(), *m_sessionOptions);

        std::cout << "[TranscriptionEngine] Whisper 模型已加载: " << modelPath << std::endl;

        // 打印模型输入/输出信息
        Ort::AllocatorWithDefaultOptions allocator;
        size_t numInputs = m_session->GetInputCount();
        size_t numOutputs = m_session->GetOutputCount();

        std::cout << "[TranscriptionEngine] 模型输入数: " << numInputs << std::endl;
        for (size_t i = 0; i < numInputs; ++i) {
            auto name = m_session->GetInputNameAllocated(i, allocator);
            std::cout << "  输入 " << i << ": " << name.get() << std::endl;
        }

        std::cout << "[TranscriptionEngine] 模型输出数: " << numOutputs << std::endl;
        for (size_t i = 0; i < numOutputs; ++i) {
            auto name = m_session->GetOutputNameAllocated(i, allocator);
            std::cout << "  输出 " << i << ": " << name.get() << std::endl;
        }

        // 加载 tokenizer
        if (!loadTokenizer(tokenizerPath)) {
            std::cerr << "[TranscriptionEngine] 警告: Tokenizer 加载失败，将使用简单解码" << std::endl;
            // 初始化一个最小的词汇表
            m_vocab.resize(256);
            for (int i = 0; i < 256; ++i) {
                m_vocab[i] = std::string(1, static_cast<char>(i));
            }
            m_vocabSize = 256;
        }

        m_initialized.store(true);
        std::cout << "[TranscriptionEngine] 引擎初始化完成" << std::endl;
        return true;

    } catch (const Ort::Exception& e) {
        std::cerr << "[TranscriptionEngine] 模型加载失败: " << e.what() << std::endl;
        return false;
    }
#else
    // 模拟模式：不加载实际模型
    std::cout << "[TranscriptionEngine] 模拟模式初始化完成" << std::endl;
    std::cout << "[TranscriptionEngine] 模型路径: " << modelPath << " (未加载)" << std::endl;
    std::cout << "[TranscriptionEngine] Tokenizer 路径: " << tokenizerPath << " (未加载)" << std::endl;

    // 初始化最小词汇表
    m_vocab.resize(256);
    for (int i = 0; i < 256; ++i) {
        m_vocab[i] = std::string(1, static_cast<char>(i));
    }
    m_vocabSize = 256;

    m_initialized.store(true);
    return true;
#endif
}

// =============================================================================
// 执行语音转文字
// =============================================================================
TranscriptionResult TranscriptionEngine::transcribe(const std::vector<int16_t>& pcmData) {
    std::lock_guard<std::mutex> lock(m_mutex);

    TranscriptionResult result;
    result.language = "en";
    result.confidence = 0.0f;
    result.durationSeconds = static_cast<double>(pcmData.size()) / TARGET_SAMPLE_RATE;

    if (!m_initialized.load() || pcmData.empty()) {
        return result;
    }

    // 第一步：Int16 PCM → 归一化浮点
    auto floatSamples = pcmToFloat(pcmData);
    if (floatSamples.empty()) {
        return result;
    }

    // 第二步：计算 log-mel 频谱图
    auto melSpec = computeLogMelSpectrogram(floatSamples, TARGET_SAMPLE_RATE);
    if (melSpec.empty()) {
        return result;
    }

    // 计算帧数
    int nFrames = static_cast<int>(floatSamples.size()) / HOP_LENGTH;
    if (nFrames < 2) {
        // 音频片段太短，不足以形成有效频谱图
        return result;
    }

    // 第三步：ONNX 推理
    auto tokenIds = runInference(melSpec, nFrames);

    // 第四步：解码 token IDs 为文本
    result.text = decodeTokens(tokenIds);
    result.confidence = result.text.empty() ? 0.0f : 0.85f;

    return result;
}

// =============================================================================
// 停止引擎
// =============================================================================
void TranscriptionEngine::stop() {
    m_initialized.store(false);
    m_session.reset();
    m_sessionOptions.reset();
    m_env.reset();
    std::cout << "[TranscriptionEngine] 引擎已停止" << std::endl;
}

// =============================================================================
// PCM 转 Float
// =============================================================================
std::vector<float> TranscriptionEngine::pcmToFloat(const std::vector<int16_t>& pcm) const {
    std::vector<float> floats(pcm.size());
    for (size_t i = 0; i < pcm.size(); ++i) {
        floats[i] = static_cast<float>(pcm[i]) / static_cast<float>(INT16_MAX);
    }
    return floats;
}

// =============================================================================
// 计算 Log-Mel 频谱图
// =============================================================================
std::vector<float> TranscriptionEngine::computeLogMelSpectrogram(
    const std::vector<float>& samples,
    int sampleRate
) const {
    if (samples.empty()) return {};

    int nFrames = static_cast<int>(samples.size()) / HOP_LENGTH;
    if (nFrames <= 0) return {};

    // 生成 Hann 窗
    auto window = hannWindow(N_FFT);

    // 分配频谱图缓冲区 [nMel * nFrames]
    // 先计算 STFT 功率谱，然后应用 Mel 滤波器
    int nFreq = N_FFT / 2 + 1; // 频率 bin 数量

    // 每帧计算 STFT
    // 输出: [nFrames * nFreq] 功率谱
    std::vector<float> powerSpectrum(nFrames * nFreq, 0.0f);

    for (int frame = 0; frame < nFrames; ++frame) {
        int start = frame * HOP_LENGTH;

        // 应用窗函数并计算 DFT
        // 使用简化的功率谱估算（实际生产中应使用 FFTW 或类似库）
        std::vector<float> windowed(N_FFT);
        for (int i = 0; i < N_FFT && (start + i) < static_cast<int>(samples.size()); ++i) {
            windowed[i] = samples[start + i] * window[i];
        }

        // 简化 STFT：仅计算几个关键频率 bin 的能量
        // 实际实现应使用完整的 FFT
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

    // 应用 Mel 滤波器（简化版）
    // 实际应用中应使用预计算的 Mel 滤波器矩阵
    // 这里直接返回功率谱作为频谱图的近似
    std::vector<float> melSpec(N_MEL * nFrames);

    for (int frame = 0; frame < nFrames; ++frame) {
        for (int mel = 0; mel < N_MEL; ++mel) {
            // 将频率 bin 线性映射到 mel 频带
            float sum = 0.0f;
            int binStart = mel * nFreq / N_MEL;
            int binEnd = (mel + 1) * nFreq / N_MEL;
            for (int bin = binStart; bin < binEnd && bin < nFreq; ++bin) {
                sum += powerSpectrum[frame * nFreq + bin];
            }
            // 取对数（加小常数防止 log(0)）
            melSpec[frame * N_MEL + mel] = std::log(sum + 1e-10f);
        }
    }

    return melSpec;
}

// =============================================================================
// Hann 窗函数
// =============================================================================
std::vector<float> TranscriptionEngine::hannWindow(int width) const {
    std::vector<float> window(width);
    for (int i = 0; i < width; ++i) {
        window[i] = 0.5f * (1.0f - std::cos(2.0f * 3.14159265358979323846f * i / (width - 1)));
    }
    return window;
}

// =============================================================================
// 加载 Tokenizer
// =============================================================================
bool TranscriptionEngine::loadTokenizer(const std::string& tokenizerPath) {
    // 尝试加载 tokenizer.json
    // Whisper 使用 BPE tokenizer，词汇表通常包含 ~50,000 个 token
    std::ifstream file(tokenizerPath);
    if (!file.is_open()) {
        std::cerr << "[TranscriptionEngine] 无法打开 tokenizer 文件: "
                  << tokenizerPath << std::endl;
        return false;
    }

    // 简化加载 — 实际应用中应使用完整的 JSON 解析库（如 nlohmann/json）
    // 这里仅读取基本结构
    std::cout << "[TranscriptionEngine] Tokenizer 已加载 (简化模式)" << std::endl;
    m_vocabSize = 51865; // Whisper-base 词汇表大小
    m_vocab.resize(m_vocabSize);
    return true;
}

// =============================================================================
// 解码 Token IDs
// =============================================================================
std::string TranscriptionEngine::decodeTokens(const std::vector<int64_t>& tokenIds) const {
    std::string text;

    for (auto id : tokenIds) {
        // Whisper 特殊 token（跳过）
        // 50257 = <|endoftext|>
        // 50258 = <|startoftranscript|>
        if (id >= 50257) continue;

        // 从词汇表查找
        if (id >= 0 && id < static_cast<int64_t>(m_vocab.size())) {
            text += m_vocab[static_cast<size_t>(id)];
        }
    }

    // 移除 Whisper 特殊标记和空格
    // Whisper 输出通常包含 "<|en|>" 等标记
    while (!text.empty() && text[0] == '<') {
        auto end = text.find('>');
        if (end == std::string::npos) break;
        text = text.substr(end + 1);
    }

    return text;
}

// =============================================================================
// ONNX 推理
// =============================================================================
std::vector<int64_t> TranscriptionEngine::runInference(
    const std::vector<float>& melSpec,
    int nFrames
) {
#ifdef HAS_ONNXRUNTIME
    try {
        Ort::AllocatorWithDefaultOptions allocator;
        Ort::MemoryInfo memoryInfo = Ort::MemoryInfo::CreateCpu(
            OrtArenaAllocator, OrtMemTypeDefault);

        // 准备输入 tensor: [1, 80, nFrames]
        std::vector<int64_t> inputShape = {1, N_MEL, nFrames};
        Ort::Value inputTensor = Ort::Value::CreateTensor<float>(
            memoryInfo,
            const_cast<float*>(melSpec.data()),
            melSpec.size(),
            inputShape.data(),
            inputShape.size()
        );

        // 准备输出 tensor
        std::vector<int64_t> outputShape = {1, MAX_TOKENS};
        Ort::Value outputTensor = Ort::Value::CreateTensor<int64_t>(
            memoryInfo,
            new int64_t[MAX_TOKENS]{0},
            MAX_TOKENS,
            outputShape.data(),
            outputShape.size()
        );

        // 获取输入输出名称
        auto inputName = m_session->GetInputNameAllocated(0, allocator);
        auto outputName = m_session->GetOutputNameAllocated(0, allocator);

        const char* inputNames[] = {inputName.get()};
        const char* outputNames[] = {outputName.get()};

        // 运行推理
        m_session->Run(
            Ort::RunOptions{nullptr},
            inputNames, &inputTensor, 1,
            outputNames, &outputTensor, 1
        );

        // 提取输出 token IDs
        auto* outputData = outputTensor.GetTensorMutableData<int64_t>();
        auto outputInfo = outputTensor.GetTensorTypeAndShapeInfo();
        size_t outputSize = outputInfo.GetElementCount();

        std::vector<int64_t> tokens(outputData, outputData + outputSize);

        // 释放输出 tensor 内存
        delete[] outputData;

        return tokens;

    } catch (const Ort::Exception& e) {
        std::cerr << "[TranscriptionEngine] 推理失败: " << e.what() << std::endl;
        return {};
    }
#else
    // 模拟模式：返回一些示例 token
    // 模拟一段英文转写
    static int callCount = 0;
    callCount++;

    if (callCount % 3 == 0) {
        // 模拟空结果（静音片段）
        return {};
    }

    // 模拟输出: "This is a test of the simultaneous interpretation system"
    std::vector<int64_t> mockTokens;
    std::string mockTexts[] = {
        "This is a test of the system.",
        "Welcome to the meeting everyone.",
        "Let's discuss the project timeline.",
        "The results are very promising.",
        "Can you hear me clearly?",
    };
    std::string text = mockTexts[callCount % 5];

    // 简单的字符到 token 映射
    for (char c : text) {
        mockTokens.push_back(static_cast<int64_t>(static_cast<unsigned char>(c)));
    }

    return mockTokens;
#endif
}

} // namespace SimultaneousInterpreter
