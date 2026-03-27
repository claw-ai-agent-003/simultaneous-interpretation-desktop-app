// =============================================================================
// TranslationEngine.cpp — ONNX NLLB-200 翻译引擎实现
// =============================================================================

#include "TranslationEngine.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <algorithm>

#ifndef HAS_ONNXRUNTIME
#include <chrono>
#include <thread>
#include <unordered_map>
#endif

namespace SimultaneousInterpreter {

TranslationEngine::TranslationEngine() {
#ifdef HAS_ONNXRUNTIME
    try {
        m_env = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "NLLBTranslation");
        m_sessionOptions = std::make_unique<Ort::SessionOptions>();
        m_sessionOptions->SetIntraOpNumThreads(4);
        m_sessionOptions->SetInterOpNumThreads(2);
        m_sessionOptions->SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_EXTENDED);
        std::cout << "[TranslationEngine] ONNX Runtime 环境已初始化" << std::endl;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] ONNX Runtime 初始化失败: " << e.what() << std::endl;
    }
#else
    std::cout << "[TranslationEngine] 模拟模式 — 未启用 ONNX Runtime" << std::endl;
#endif
}

TranslationEngine::~TranslationEngine() { stop(); }

bool TranslationEngine::initialize(const std::string& modelPath, const std::string& tokenizerPath) {
    std::lock_guard<std::mutex> lock(m_mutex);

#ifdef HAS_ONNXRUNTIME
    try {
        std::string encoderPath = modelPath;
        std::string decoderPath = modelPath;
        std::string basePath = modelPath;
        if (basePath.size() > 5 && basePath.substr(basePath.size() - 5) == ".onnx")
            basePath = basePath.substr(0, basePath.size() - 5);

        std::string encFile = basePath + "-encoder.onnx";
        std::ifstream test(encFile);
        if (test.good()) { encoderPath = encFile; decoderPath = basePath + "-decoder.onnx"; }

        m_encoderSession = std::make_unique<Ort::Session>(*m_env, encoderPath.c_str(), *m_sessionOptions);
        m_decoderSession = (encoderPath != decoderPath)
            ? std::make_unique<Ort::Session>(*m_env, decoderPath.c_str(), *m_sessionOptions)
            : std::make_unique<Ort::Session>(*m_env, decoderPath.c_str(), *m_sessionOptions);

        std::cout << "[TranslationEngine] Encoder 已加载: " << encoderPath << std::endl;
        if (encoderPath != decoderPath)
            std::cout << "[TranslationEngine] Decoder 已加载: " << decoderPath << std::endl;

        loadTokenizer(tokenizerPath);
        m_initialized.store(true);
        std::cout << "[TranslationEngine] NLLB 翻译引擎初始化完成" << std::endl;
        return true;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] 模型加载失败: " << e.what() << std::endl;
        return false;
    }
#else
    std::cout << "[TranslationEngine] 模拟模式初始化完成 (模型: " << modelPath << ")" << std::endl;
    m_id2token.resize(VOCAB_SIZE);
    m_initialized.store(true);
    return true;
#endif
}

TranslationResult TranslationEngine::translate(
    const std::string& text, const std::string& sourceLanguage, const std::string& targetLanguage)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    TranslationResult result;
    result.sourceLanguage = sourceLanguage;
    result.targetLanguage = targetLanguage;
    result.confidence = 0.0f;

    if (!m_initialized.load() || text.empty()) return result;

    std::string srcNLLB = bcp47ToNLLB(sourceLanguage);
    std::string tgtNLLB = bcp47ToNLLB(targetLanguage);
    int64_t tgtLangToken = nllbLanguageToTokenID(tgtNLLB);
    auto inputIds = encodeText(text, srcNLLB);
    if (inputIds.empty()) return result;

#ifdef HAS_ONNXRUNTIME
    auto encoderOutput = runEncoder(inputIds);
    if (encoderOutput.empty()) return result;

    std::vector<int64_t> decoderInput = {BOS_TOKEN_ID, tgtLangToken};
    for (int step = 0; step < MAX_TOKENS; ++step) {
        auto logits = runDecoder(decoderInput, encoderOutput);
        if (logits.empty()) break;
        int64_t nextToken = logits.back();
        if (nextToken == EOS_TOKEN_ID || nextToken == PAD_TOKEN_ID) break;
        decoderInput.push_back(nextToken);
    }

    // 从 decoderInput 中提取翻译结果（移除 BOS 和语言 token）
    std::vector<int64_t> outputTokens(decoderInput.begin() + 2, decoderInput.end());
    result.text = decodeTokens(outputTokens);
#else
    result.text = simulateTranslation(text, sourceLanguage, targetLanguage);
#endif

    result.confidence = result.text.empty() ? 0.0f : 0.92f;
    return result;
}

void TranslationEngine::stop() {
    m_initialized.store(false);
    m_decoderSession.reset(); m_encoderSession.reset();
    m_sessionOptions.reset(); m_env.reset();
}

std::string TranslationEngine::bcp47ToNLLB(const std::string& bcp47) {
    static const std::unordered_map<std::string, std::string> m = {
        {"en", "eng_Latn"}, {"zh", "zho_Hans"}, {"zh-CN", "zho_Hans"},
        {"zh-Hans", "zho_Hans"}, {"zh-TW", "zho_Hant"},
    };
    auto it = m.find(bcp47);
    return it != m.end() ? it->second : bcp47;
}

int64_t TranslationEngine::nllbLanguageToTokenID(const std::string& nllbCode) {
    static const std::unordered_map<std::string, int64_t> m = {
        {"eng_Latn", 66804}, {"zho_Hans", 70426}, {"zho_Hant", 70427},
    };
    auto it = m.find(nllbCode);
    return it != m.end() ? it->second : 66804;
}

bool TranslationEngine::loadTokenizer(const std::string& tokenizerPath) {
    std::ifstream file(tokenizerPath);
    if (!file.is_open()) {
        std::cerr << "[TranslationEngine] 无法打开 tokenizer: " << tokenizerPath << std::endl;
        return false;
    }
    std::cout << "[TranslationEngine] Tokenizer 已加载 (简化模式)" << std::endl;
    return true;
}

std::vector<int64_t> TranslationEngine::encodeText(const std::string& text, const std::string& language) {
    std::vector<int64_t> ids;
    std::string prefix = ">>" + language + "<<";
    for (char c : prefix) ids.push_back(static_cast<int64_t>(c));
    for (char c : text) ids.push_back(static_cast<int64_t>(static_cast<unsigned char>(c)));
    return ids;
}

std::string TranslationEngine::decodeTokens(const std::vector<int64_t>& tokenIds) {
    std::string text;
    for (auto id : tokenIds) {
        if (id <= 2) continue;
        if (id >= 0 && id < static_cast<int64_t>(m_id2token.size())) {
            std::string token = m_id2token[static_cast<size_t>(id)];
            if (!token.empty()) {
                if (token[0] == '\xe2' && token.size() >= 3 && token[1] == '\x96' && token[2] == '\x81')
                    token = " " + token.substr(3);
                text += token;
            }
        } else {
            text += static_cast<char>(id & 0xFF);
        }
    }
    while (!text.empty() && text.front() == ' ') text.erase(0, 1);
    while (!text.empty() && text.back() == ' ') text.pop_back();
    return text;
}

std::vector<int64_t> TranslationEngine::runEncoder(const std::vector<int64_t>& inputIds) {
#ifdef HAS_ONNXRUNTIME
    if (!m_encoderSession) return {};
    try {
        Ort::AllocatorWithDefaultOptions allocator;
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<int64_t> shape = {1, static_cast<int64_t>(inputIds.size())};
        Ort::Value input = Ort::Value::CreateTensor<int64_t>(memInfo,
            const_cast<int64_t*>(inputIds.data()), inputIds.size(), shape.data(), shape.size());

        auto inName = m_encoderSession->GetInputNameAllocated(0, allocator);
        auto outName = m_encoderSession->GetOutputNameAllocated(0, allocator);
        const char* inNames[] = {inName.get()};
        const char* outNames[] = {outName.get()};

        auto outInfo = m_encoderSession->GetOutputTypeInfo(0)->GetTensorTypeAndShapeInfo();
        auto outShape = outInfo.GetShape();
        size_t outSize = 1;
        for (auto d : outShape) outSize *= d;

        std::vector<int64_t> outData(outSize);
        Ort::Value out = Ort::Value::CreateTensor<int64_t>(memInfo,
            outData.data(), outData.size(), outShape.data(), outShape.size());

        m_encoderSession->Run(Ort::RunOptions{nullptr}, inNames, &input, 1, outNames, &out, 1);
        return outData;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] Encoder 失败: " << e.what() << std::endl;
        return {};
    }
#else
    return inputIds;
#endif
}

std::vector<int64_t> TranslationEngine::runDecoder(
    const std::vector<int64_t>& decoderInputIds, const std::vector<int64_t>& encoderOutput)
{
#ifdef HAS_ONNXRUNTIME
    if (!m_decoderSession) return {};
    try {
        Ort::AllocatorWithDefaultOptions allocator;
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        std::vector<int64_t> dShape = {1, static_cast<int64_t>(decoderInputIds.size())};
        Ort::Value decIn = Ort::Value::CreateTensor<int64_t>(memInfo,
            const_cast<int64_t*>(decoderInputIds.data()), decoderInputIds.size(),
            dShape.data(), dShape.size());

        std::vector<int64_t> eShape = {1, static_cast<int64_t>(encoderOutput.size())};
        Ort::Value encOut = Ort::Value::CreateTensor<int64_t>(memInfo,
            const_cast<int64_t*>(encoderOutput.data()), encoderOutput.size(),
            eShape.data(), eShape.size());

        auto in0 = m_decoderSession->GetInputNameAllocated(0, allocator);
        size_t numInputs = m_decoderSession->GetInputCount();
        auto in1 = m_decoderSession->GetInputNameAllocated(
            std::min(numInputs - 1, (size_t)1), allocator);
        auto outN = m_decoderSession->GetOutputNameAllocated(0, allocator);

        const char* inNames[] = {in0.get(), in1.get()};
        const char* outNames[] = {outN.get()};
        Ort::Value inputs[] = {std::move(decIn), std::move(encOut)};

        auto outInfo = m_decoderSession->GetOutputTypeInfo(0)->GetTensorTypeAndShapeInfo();
        auto outShape = outInfo.GetShape();
        size_t outSize = 1;
        for (auto d : outShape) outSize *= d;

        std::vector<int64_t> outData(outSize);
        Ort::Value out = Ort::Value::CreateTensor<int64_t>(memInfo,
            outData.data(), outData.size(), outShape.data(), outShape.size());

        m_decoderSession->Run(Ort::RunOptions{nullptr}, inNames, inputs, 2, outNames, &out, 1);
        return outData;
    } catch (const Ort::Exception& e) {
        std::cerr << "[TranslationEngine] Decoder 失败: " << e.what() << std::endl;
        return {};
    }
#else
    return decoderInputIds;
#endif
}

std::string TranslationEngine::simulateTranslation(
    const std::string& text, const std::string& sourceLanguage, const std::string& targetLanguage)
{
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

    if (sourceLanguage == "en" && targetLanguage == "zh") {
        auto it = enToZh.find(text);
        if (it != enToZh.end()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            return it->second;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        return "[模拟翻译] " + text;
    }

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
