# Changelog

## [0.1.0.0] - 2026-03-26

### Added
- **P1.1 macOS Microphone Audio Capture**: AVAudioEngine-based audio capture with real-time audio level monitoring, privacy-preserving microphone permission handling, and automatic gain control
- **P1.2 MLX Whisper Integration**: English↔Mandarin speech-to-text using MLX Whisper with ONNX model loading, configurable audio chunking, and confidence scoring
- **P1.3 NLLB-200 Translation**: English↔Mandarin translation using NLLB-200 distilled model via MLX with streaming token output support
- **P1.4 Concurrent Interpreter Pipeline**: Actor-based Swift concurrency pipeline with pipelined Whisper→NLLB processing, overlap management for VAD continuity, and graceful cancellation
- **P1.5 SwiftUI Overlay Rendering**: Floating bilingual text overlay with staged reveal (English first, Mandarin fills in later), pulse animation during translation, confidence indicators, and session lifecycle management
- **P1.6 Privacy Verification UI**: Visual privacy mode indicator with toggle, green/gray dot status, and per-session attestation display

### Changed
- Updated minimum macOS version to support MLX framework requirements
- Improved audio buffer management with overlap handling for seamless chunk transitions
