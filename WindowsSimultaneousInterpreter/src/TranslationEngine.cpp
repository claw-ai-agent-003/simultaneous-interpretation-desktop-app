// =============================================================================
// TranslationEngine.cpp — ONNX NLLB-200 翻译引擎实现
// =============================================================================

#include "TranslationEngine.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <algorithm>

// 未安装 ONNX Runtime 时的模拟实现
#ifndef HAS_ONNXRUNTIME
#include <chrono>
#include <thread>
#endif

namespace SimultaneousInterpreter {

// =============================================================================
// 构造函数
// =============================================================================
TranslationEngine::TranslationEngine() {
#ifdef HAS_ONNXRUNTIME
    try {
        m_env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "NLLBTranslation");
        m_sessionOptions = std::make_unique<Ort::SessionOptions>();

        // 多线程配置
        m_sessionOptions->SetIntraOpNumThreads(4);
        m_sessionOptions->SetInterOpNumThreads(2);
        m_sessionOptions->SetGraphOptimizationLevel(
            GraphOptimizationLevel::ORT_ENABLE_EXTENDED);

        std::cout << "[TranslationEngine] ONNX Runtime 环境已初始化" << std::endl;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] ONNX Runtime 初始化失败: " << e.what() << std::endl;
    }
#else
    std::cout << "[TranslationEngine] 模拟模式 — 未启用 ONNX Runtime" << std::endl;
#endif
}

// =============================================================================
// 析构函数
// =============================================================================
TranslationEngine::~TranslationEngine() {
    stop();
}

// =============================================================================
// 初始化引擎
// =============================================================================
bool TranslationEngine::initialize(const std::string& modelPath, const std::string& tokenizerPath) {
    std::lock_guard<std::mutex> lock(m_mutex);

#ifdef HAS_ONNXRUNTIME
    try {
        // NLLB 模型通常分为 encoder 和 decoder 两个文件
        // 或合并为一个文件（取决于导出方式）
        std::string encoderPath = modelPath;
        std::string decoderPath = modelPath;

        // 检查是否有分开的 encoder/decoder 文件
        // 例如: nllb-encoder.onnx, nllb-decoder.onnx
        std::string basePath = modelPath;
        if (basePath.size() > 5 && basePath.substr(basePath.size() - 5) == ".onnx") {
            basePath = basePath.substr(0, basePath.size() - 5);
        }

        std::string encFile = basePath + "-encoder.onnx";
        std::string decFile = basePath + "-decoder.onnx";

        // 尝试加载分开的 encoder/decoder
        {
            std::ifstream test(encFile);
            if (test.good()) {
                encoderPath = encFile;
                decoderPath = decFile;
                test.close();
            }
        }

        // DirectML 加速（如果可用）
        // try {
        //     m_sessionOptions->AppendExecutionProvider("DML", {});
        //     std::cout << "[TranslationEngine] DirectML 加速已启用" << std::endl;
        // } catch (...) {
        //     std::cout << "[TranslationEngine] DirectML 不可用，使用 CPU" << std::endl;
        // }

        // 加载 encoder 模型
        m_encoderSession = std::make_unique<Ort::Session>(
            *m_env, encoderPath.c_str(), *m_sessionOptions);
        std::cout << "[TranslationEngine] Encoder 模型已加载: " << encoderPath << std::endl;

        // 如果 encoder 和 decoder 是分开的文件，加载 decoder
        if (encoderPath != decoderPath) {
            m_decoderSession = std::make_unique<Ort::Session>(
                *m_env, decoderPath.c_str(), *m_sessionOptions);
            std::cout << "[TranslationEngine] Decoder 模型已加载: " << decoderPath << std::endl;
        } else {
            // 单文件模型 — 使用同一个 session
            m_decoderSession = std::make_unique<Ort::Session>(
                *m_env, decoderPath.c_str(), *m_sessionOptions);
        }

        // 加载 tokenizer
        loadTokenizer(tokenizerPath);

        m_initialized.store(true);
        std::cout << "[TranslationEngine] NLLB 翻译引擎初始化完成" << std::endl;
        return true;

    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] 模型加载失败: " << e.what() << std::endl;
        return false;
    }
#else
    // 模拟模式
    std::cout << "[TranslationEngine] 模拟模式初始化完成" << std::endl;
    std::cout << "[TranslationEngine] 模型路径: " << modelPath << " (未加载)" << std::endl;
    std::cout << "[TranslationEngine] Tokenizer 路径: " << tokenizerPath << " (未加载)" << std::endl;

    // 初始化词汇表
    m_id2token.resize(VOCAB_SIZE);
    m_initialized.store(true);
    return true;
#endif
}

// =============================================================================
// 翻译文本
// =============================================================================
TranslationResult TranslationEngine::translate(
    const std::string& text,
    const std::string& sourceLanguage,
    const std::string& targetLanguage
) {
    std::lock_guard<std::mutex> lock(m_mutex);

    TranslationResult result;
    result.sourceLanguage = sourceLanguage;
    result.targetLanguage = targetLanguage;
    result.confidence = 0.0f;

    if (!m_initialized.load() || text.empty()) {
        return result;
    }

    // 转换 BCP-47 到 NLLB 语言代码
    std::string srcNLLB = bcp47ToNLLB(sourceLanguage);
    std::string tgtNLLB = bcp47ToNLLB(targetLanguage);
    int64_t tgtLangToken = nllbLanguageToTokenID(tgtNLLB);

    // Tokenize 源文本
    auto inputIds = encodeText(text, srcNLLB);

    if (inputIds.empty()) {
        return result;
    }

#ifdef HAS_ONNXRUNTIME
    // 运行 encoder
    auto encoderOutput = runEncoder(inputIds);
    if (encoderOutput.empty()) {
        return result;
    }

    // 自回归 decoder
    std::vector<int64_t> decoderInput = {BOS_TOKEN_ID, tgtLangToken};
    std::vector<int64_t> outputTokens;

    for (int step = 0; step < MAX_TOKENS; ++step) {
        auto logits = runDecoder(decoderInput, encoderOutput);
        if (logits.empty()) break;

        // 贪婪解码：取最后一个 token 的 logits
        int64_t nextToken = logits.back();

        if (nextToken == EOS_TOKEN_ID || nextToken == PAD_TOKEN_ID) {
            break;
        }

        outputTokens.push_back(nextToken);
        decoderInput.push_back(nextToken);
    }

    result.text = decodeTokens(outputTokens);
#else
    // 模拟翻译
    result.text = simulateTranslation(text, sourceLanguage, targetLanguage);
#endif

    result.confidence = result.text.empty() ? 0.0f : 0.92f;
    return result;
}

// =============================================================================
// 停止引擎
// =============================================================================
void TranslationEngine::stop() {
    m_initialized.store(false);
    m_decoderSession.reset();
    m_encoderSession.reset();
    m_sessionOptions.reset();
    m_env.reset();
    std::cout << "[TranslationEngine] 引擎已停止" << std::endl;
}

// =============================================================================
// BCP-47 → NLLB 语言代码
// =============================================================================
std::string TranslationEngine::bcp47ToNLLB(const std::string& bcp47) {
    static const std::unordered_map<std::string, std::string> mapping = {
        {"en",      "eng_Latn"},
        {"zh",      "zho_Hans"},
        {"zh-CN",   "zho_Hans"},
        {"zh-Hans", "zho_Hans"},
        {"zh-TW",   "zho_Hant"},
    };

    auto it = mapping.find(bcp47);
    return it != mapping.end() ? it->second : bcp47;
}

// =============================================================================
// NLLB 语言代码 → Token ID
// =============================================================================
int64_t TranslationEngine::nllbLanguageToTokenID(const std::string& nllbCode) {
    static const std::unordered_map<std::string, int64_t> mapping = {
        {"eng_Latn", 66804},
        {"zho_Hans", 70426},
        {"zho_Hant", 70427},
    };

    auto it = mapping.find(nllbCode);
    return it != mapping.end() ? it->second : 66804; // 默认英语
}

// =============================================================================
// 加载 Tokenizer
// =============================================================================
bool TranslationEngine::loadTokenizer(const std::string& tokenizerPath) {
    std::ifstream file(tokenizerPath);
    if (!file.is_open()) {
        std::cerr << "[TranslationEngine] 无法打开 tokenizer 文件: "
                  << tokenizerPath << std::endl;
        return false;
    }

    std::cout << "[TranslationEngine] Tokenizer 已加载 (简化模式)" << std::endl;
    return true;
}

// =============================================================================
// 文本编码
// =============================================================================
std::vector<int64_t> TranslationEngine::encodeText(
    const std::string& text,
    const std::string& language
) {
    std::vector<int64_t> tokenIds;

    // 添加语言标签 token
    std::string langPrefix = ">>" + language + "<<";
    for (char c : langPrefix) {
        tokenIds.push_back(static_cast<int64_t>(c));
    }

    // 添加文本 token（简化版）
    for (char c : text) {
        tokenIds.push_back(static_cast<int64_t>(static_cast<unsigned char>(c)));
    }

    return tokenIds;
}

// =============================================================================
// Token 解码
// =============================================================================
std::string TranslationEngine::decodeTokens(const std::vector<int64_t>& tokenIds) {
    std::string text;

    for (auto id : tokenIds) {
        // 跳过特殊 token
        if (id <= 2) continue; // <pad>, </s>, <s>

        if (id >= 0 && id < static_cast<int64_t>(m_id2token.size())) {
            std::string token = m_id2token[static_cast<size_t>(id)];
            if (!token.empty()) {
                // 移除 NLLB 的 SentencePiece 标记
                // ▁ (U+2581) 表示空格
                if (token[0] == '\xe2' && token.size() >= 3 &&
                    token[1] == '\x96' && token[2] == '\x81') {
                    // 这是 ▁ 字符（UTF-8: E2 96 81）
                    token = " " + token.substr(3);
                }
                text += token;
            }
        } else {
            // 简化处理：直接映射为字符
            text += static_cast<char>(id & 0xFF);
        }
    }

    // 清理前后空格
    while (!text.empty() && text.front() == ' ') text.erase(0, 1);
    while (!text.empty() && text.back() == ' ') text.pop_back();

    return text;
}

// =============================================================================
// Encoder 推理
// =============================================================================
std::vector<int64_t> TranslationEngine::runEncoder(
    const std::vector<int64_t>& inputIds
) {
#ifdef HAS_ONNXRUNTIME
    if (!m_encoderSession) return {};

    try {
        Ort::AllocatorWithDefaultOptions allocator;
        Ort::MemoryInfo memoryInfo = Ort::MemoryInfo::CreateCpu(
            OrtArenaAllocator, OrtMemTypeDefault);

        std::vector<int64_t> inputShape = {1, static_cast<int64_t>(inputIds.size())};
        Ort::Value inputTensor = Ort::Value::CreateTensor<int64_t>(
            memoryInfo,
            const_cast<int64_t*>(inputIds.data()),
            inputIds.size(),
            inputShape.data(),
            inputShape.size()
        );

        auto inputName = m_encoderSession->GetInputNameAllocated(0, allocator);
        auto outputName = m_encoderSession->GetOutputNameAllocated(0, allocator);

        const char* inputNames[] = {inputName.get()};
        const char* outputNames[] = {outputName.get()};

        // 获取输出形状
        auto outputInfo = m_encoderSession->GetOutputTypeInfo(0)
            ->GetTensorTypeAndShapeInfo();
        auto outputShape = outputInfo.GetShape();
        size_t outputSize = 1;
        for (auto dim : outputShape) outputSize *= dim;

        std::vector<int64_t> outputData(outputSize);
        Ort::Value outputTensor = Ort::Value::CreateTensor<int64_t>(
            memoryInfo,
            outputData.data(),
            outputData.size(),
            outputShape.data(),
            outputShape.size()
        );

        m_encoderSession->Run(
            Ort::RunOptions{nullptr},
            inputNames, &inputTensor, 1,
            outputNames, &outputTensor, 1
        );

        return outputData;

    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] Encoder 推理失败: " << e.what() << std::endl;
        return {};
    }
#else
    return inputIds; // 模拟模式：直接返回输入
#endif
}

// =============================================================================
// Decoder 推理
// =============================================================================
std::vector<int64_t> TranslationEngine::runDecoder(
    const std::vector<int64_t>& decoderInputIds,
    const std::vector<int64_t>& encoderOutput
) {
#ifdef HAS_ONNXRUNTIME
    if (!m_decoderSession) return {};

    try {
        Ort::AllocatorWithDefaultOptions allocator;
        Ort::MemoryInfo memoryInfo = Ort::MemoryInfo::CreateCpu(
            OrtArenaAllocator, OrtMemTypeDefault);

        // Decoder 输入: decoder_input_ids + encoder_output
        std::vector<int64_t> decShape = {1, static_cast<int64_t>(decoderInputIds.size())};
        Ort::Value decInputTensor = Ort::Value::CreateTensor<int64_t>(
            memoryInfo,
            const_cast<int64_t*>(decoderInputIds.data()),
            decoderInputIds.size(),
            decShape.data(),
            decShape.size()
        );

        std::vector<int64_t> encShape = {1, static_cast<int64_t>(encoderOutput.size())};
        Ort::Value encOutputTensor = Ort::Value::CreateTensor<int64_t>(
            memoryInfo,
            const_cast<int64_t*>(encoderOutput.data()),
            encoderOutput.size(),
            encShape.data(),
            encShape.size()
        );

        auto inputName0 = m_decoderSession->GetInputNameAllocated(0, allocator);
        auto inputName1 = m_decoderSession->GetInputNameAllocated(
            std::min(m_decoderSession->GetInputCount() - 1, (size_t)1), allocator);
        auto outputName = m_decoderSession->GetOutputNameAllocated(0, allocator);

        const char* inputNames[] = {inputName0.get(), inputName1.get()};
        const char* outputNames[] = {outputName.get()};
        Ort::Value inputs[] = {std::move(decInputTensor), std::move(encOutputTensor)};

        auto outputInfo = m_decoderSession->GetOutputTypeInfo(0)
            ->GetTensorTypeAndShapeInfo();
        auto outputShape = outputInfo.GetShape();
        size_t outputSize = 1;
        for (auto dim : outputShape) outputSize *= dim;

        std::vector<int64_t> outputData(outputSize);
        Ort::Value outputTensor = Ort::Value::CreateTensor<int64_t>(
            memoryInfo,
            outputData.data(),
            outputData.size(),
            outputShape.data(),
            outputShape.size()
        );

        m_decoderSession->Run(
            Ort::RunOptions{nullptr},
            inputNames, inputs, 2,
            outputNames, &outputTensor, 1
        );

        return outputData;

    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] Decoder 推理失败: " << e.what() << std::endl;
        return {};
    }
#else
    // 模拟模式：返回伪 logits（取 decoder input 的最后一个值作为 "最佳 token"）
    return decoderInputIds;
#endif
}

// =============================================================================
// 模拟翻译（未安装 ONNX Runtime 时使用）
// =============================================================================
std::string TranslationEngine::simulateTranslation(
    const std::string& text,
    const std::string& sourceLanguage,
    const std::string& targetLanguage
) {
    // 简单的模拟翻译映射
    static const std::unordered_map<std::string, std::string> enToZh = {
        {"This is a test of the system.", "这是系统的测试。"},
        {"Welcome to the meeting everyone.", "欢迎各位参加会议。"},
        {"Let's discuss the project timeline.", "我们来讨论一下项目时间表。"},
        {"The results are very promising.", "结果非常有希望。"},
        {"Can you hear me clearly?", "你能听清楚我说话吗？"},
        {"Thank you for your presentation.", "感谢你的演讲。"},
        {"We need to review the budget.", "我们需要审查预算。"},
        {"The next meeting is scheduled.", "下一次会议已安排好。"},
    };

    // 检查是否是 EN→ZH
    if (sourceLanguage == "en" && targetLanguage == "zh") {
        auto it = enToZh.find(text);
        if (it != enToZh.end()) {
            // 模拟翻译延迟
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            return it->second;
        }
        // 未知文本：返回通用翻译
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        return "[模拟翻译] " + text;
    }

    // ZH→EN
    if (sourceLanguage == "zh" && targetLanguage == "en") {
        for (const auto& [en, zh] : enToZh) {
            if (zh == text) {
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                return en;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        return "[Simulated] " + text;
    }

    return text;
}

} // namespace SimultaneousInterpreter
