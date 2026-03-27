// =============================================================================
// TranslationEngine.h — ONNX NLLB-200 翻译引擎
// =============================================================================
// 功能说明:
//   使用 ONNX Runtime C++ API 加载 NLLB-200 distilled 模型，
//   实现英文↔中文双向翻译。
//
// 与 macOS 版的区别:
//   - macOS 使用 MLX 框架（仅支持 Apple Silicon）
//   - Windows 使用 ONNX Runtime（支持 DirectML/CUDA 加速）
//
// 支持语言:
//   - eng_Latn (英语)
//   - zho_Hans (简体中文)
//
// 模型:
//   - NLLB-200 distilled 600M: 12 层 Transformer encoder-decoder
//   - 词汇表大小: 256,218 tokens
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
#include <unordered_map>

// ONNX Runtime C++ API
#include <onnxruntime_cxx_api.h>

namespace SimultaneousInterpreter {

// =============================================================================
// 翻译结果
// =============================================================================
struct TranslationResult {
    std::string text;           // 翻译后的文本
    std::string sourceLanguage; // 源语言 (BCP-47)
    std::string targetLanguage; // 目标语言 (BCP-47)
    float confidence;           // 置信度 [0.0, 1.0]
};

// =============================================================================
// TranslationEngine — NLLB-200 翻译引擎
// =============================================================================
class TranslationEngine {
public:
    TranslationEngine();
    ~TranslationEngine();

    // 禁止拷贝
    TranslationEngine(const TranslationEngine&) = delete;
    TranslationEngine& operator=(const TranslationEngine&) = delete;

    /// 初始化引擎并加载 NLLB 模型
    /// @param modelPath     ONNX 模型文件路径（.onnx）
    /// @param tokenizerPath tokenizer.json 文件路径
    /// @return 成功返回 true
    bool initialize(const std::string& modelPath, const std::string& tokenizerPath);

    /// 检查引擎是否已初始化
    bool isInitialized() const { return m_initialized.load(); }

    /// 翻译文本
    /// @param text          源文本
    /// @param sourceLanguage 源语言 BCP-47 标签 (如 "en", "zh")
    /// @param targetLanguage 目标语言 BCP-47 标签 (如 "en", "zh")
    /// @return 翻译结果
    TranslationResult translate(
        const std::string& text,
        const std::string& sourceLanguage,
        const std::string& targetLanguage
    );

    /// 停止引擎，释放资源
    void stop();

private:
    // ---- BCP-47 → NLLB 语言代码映射 ----
    static std::string bcp47ToNLLB(const std::string& bcp47);

    // ---- NLLB 语言代码 → Token ID 映射 ----
    static int64_t nllbLanguageToTokenID(const std::string& nllbCode);

    // ---- Tokenizer ----
    bool loadTokenizer(const std::string& tokenizerPath);
    std::vector<int64_t> encodeText(const std::string& text, const std::string& language);
    std::string decodeTokens(const std::vector<int64_t>& tokenIds);

    // ---- ONNX 推理 ----
    std::vector<int64_t> runEncoder(const std::vector<int64_t>& inputIds);
    std::vector<int64_t> runDecoder(
        const std::vector<int64_t>& decoderInputIds,
        const std::vector<int64_t>& encoderOutput
    );

    // ONNX Runtime 对象
    std::unique_ptr<Ort::Env>      m_env;
    std::unique_ptr<Ort::Session>   m_encoderSession;
    std::unique_ptr<Ort::Session>   m_decoderSession;
    std::unique_ptr<Ort::SessionOptions> m_sessionOptions;

    // 模型状态
    std::atomic<bool> m_initialized{false};

    // NLLB 模型参数
    static constexpr int MAX_TOKENS = 256;     // 最大翻译输出 token 数
    static constexpr int VOCAB_SIZE = 256218;  // NLLB 词汇表大小
    static constexpr int64_t PAD_TOKEN_ID = 1;
    static constexpr int64_t BOS_TOKEN_ID = 2;
    static constexpr int64_t EOS_TOKEN_ID = 2; // NLLB 中 BOS = EOS

    // Tokenizer 词汇表（简化版）
    std::unordered_map<std::string, int64_t> m_token2id;
    std::vector<std::string> m_id2token;

    // 线程安全
    mutable std::mutex m_mutex;
};

} // namespace SimultaneousInterpreter
