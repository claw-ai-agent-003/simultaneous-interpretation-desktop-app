# 模型下载说明 / Model Download Instructions

本目录用于存放 ONNX 格式的 AI 模型文件。应用启动时会从此目录加载模型。

---

## 所需模型文件 / Required Model Files

| 文件名 | 说明 | 来源 | 大小（约） |
|--------|------|------|-----------|
| `whisper-base.onnx` | Whisper base 语音转文字模型 | [whisper](https://github.com/openai/whisper) → ONNX 导出 | ~150 MB |
| `whisper-tokenizer.json` | Whisper BPE tokenizer | 同上 | ~1 MB |
| `nllb-distilled-600M.onnx` | NLLB-200 distilled 600M 翻译模型 | [nllb](https://github.com/facebookresearch/nllb) → ONNX 导出 | ~1.2 GB |
| `nllb-tokenizer.json` | NLLB SentencePiece tokenizer | 同上 | ~800 KB |

---

## 下载方式 / How to Download

### 方式一：直接下载预转换模型 / Pre-converted Models (推荐)

从以下地址下载预转换的 ONNX 模型:

1. **Whisper Base ONNX**
   ```bash
   # Hugging Face - ONNX 格式
   curl -L -o whisper-base.onnx \
     https://huggingface.co/openai/whisper-base/resolve/main/onnx/encoder.onnx
   ```

   或从 [Hugging Face ONNX Hub](https://huggingface.co/models?search=whisper+onnx) 查找。

2. **NLLB-200 Distilled 600M ONNX**
   ```bash
   # 从 Hugging Face 下载
   curl -L -o nllb-distilled-600M.onnx \
     https://huggingface.co/facebook/nllb-200-distilled-600M/resolve/main/model.onnx
   ```

### 方式二：自行转换 / Convert from PyTorch

如果预转换模型不可用，可以使用以下工具自行转换:

#### Whisper → ONNX

```bash
pip install onnxruntime onnx
pip install optimum  # Hugging Face 的 ONNX 转换工具

python -c "
from optimum.exporters.onnx import main_export
main_export('openai/whisper-base', output='./', task='automatic-speech-recognition')
"
```

#### NLLB-200 → ONNX

```bash
pip install transformers onnx onnxruntime

python -c "
from transformers import AutoModelForSeq2SeqLM
import torch

model = AutoModelForSeq2SeqLM.from_pretrained('facebook/nllb-200-distilled-600M')
dummy_input = {
    'input_ids': torch.randint(0, 256218, (1, 32)),
    'attention_mask': torch.ones(1, 32, dtype=torch.long)
}
torch.onnx.export(
    model, (dummy_input['input_ids'], dummy_input['attention_mask']),
    'nllb-distilled-600M.onnx',
    input_names=['input_ids', 'attention_mask'],
    output_names=['last_hidden_state'],
    dynamic_axes={
        'input_ids': {1: 'seq_length'},
        'attention_mask': {1: 'seq_length'},
    },
    opset_version=14
)
"
```

---

## 模型许可证 / Model Licenses

- **Whisper**: [MIT License](https://github.com/openai/whisper/blob/main/LICENSE)
- **NLLB-200**: [MIT License](https://github.com/facebookresearch/nllb/blob/main/LICENSE)

---

## 目录结构 / Directory Structure

```
models/
├── README.md                    # 本文件
├── whisper-base.onnx            # Whisper 语音转文字模型
├── whisper-tokenizer.json       # Whisper tokenizer
├── nllb-distilled-600M.onnx     # NLLB 翻译模型
└── nllb-tokenizer.json          # NLLB tokenizer
```

## 磁盘空间 / Disk Space

总计约需要 **1.5 GB** 的磁盘空间存放模型文件。
