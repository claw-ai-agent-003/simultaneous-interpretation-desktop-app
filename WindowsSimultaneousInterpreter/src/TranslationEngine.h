// =============================================================================
// TranslationEngine.h — ONNX NLLB-200 翻译引擎
// =============================================================================
// 功能说明:
//   使用 ONNX Runtime C++ API 加载 NLLB-200 distilled 模型，
//   实现英文↔中文双向翻译。
//
// 支持语言: eng_Latn (英语), zho_Hans (简体中文)
// 依赖: ONNX Runtime >= 1.16
// =============================================================================

#pragma once

#include <string>
#include <vector>
#include <memory>
#include <mutex>
#include <atomic>
#include <unordered_map>

#include <onnxruntime_cxx_api.h>

namespace SimultaneousInterpreter {

struct TranslationResult {
    std::string text;
    std::string sourceLanguage;
    std::string targetLanguage;
    float confidence;
};

class TranslationEngine {
public:
    TranslationEngine();
    ~TranslationEngine();

    TranslationEngine(const TranslationEngine&) = delete;
    TranslationEngine& operator=(const TranslationEngine&) = delete;

    bool initialize(const std::string& modelPath, const std::string& tokenizerPath);
    bool isInitialized() const { return m_initialized.load(); }

    TranslationResult translate(const std::string& text,
        const std::string& sourceLanguage, const std::string& targetLanguage);

    void stop();

private:
    static std::string bcp47ToNLLB(const std::string& bcp47);
    static int64_t nllbLanguageToTokenID(const std::string& nllbCode);

    bool loadTokenizer(const std::string& tokenizerPath);
    std::vector<int64_t> encodeText(const std::string& text, const std::string& language);
    std::string decodeTokens(const std::vector<int64_t>& tokenIds);

    std::vector<int64_t> runEncoder(const std::vector<int64_t>& inputIds);
    std::vector<int64_t> runDecoder(const std::vector<int64_t>& decoderInputIds,
        const std::vector<int64_t>& encoderOutput);

    // 模拟翻译（无 ONNX Runtime 时）
    std::string simulateTranslation(const std::string& text,
        const std::string& sourceLanguage, const std::string& targetLanguage);

    std::unique_ptr<Ort::Env>      m_env;
    std::unique_ptr<Ort::Session>   m_encoderSession;
    std::unique_ptr<Ort::Session>   m_decoderSession;
    std::unique_ptr<Ort::SessionOptions> m_sessionOptions;

    std::atomic<bool> m_initialized{false};

    static constexpr int MAX_TOKENS = 256;
    static constexpr int VOCAB_SIZE = 256218;
    static constexpr int64_t PAD_TOKEN_ID = 1;
    static constexpr int64_t BOS_TOKEN_ID = 2;
    static constexpr int64_t EOS_TOKEN_ID = 2;

    std::unordered_map<std::string, int64_t> m_token2id;
    std::vector<std::string> m_id2token;

    mutable std::mutex m_mutex;
};

} // namespace SimultaneousInterpreter
