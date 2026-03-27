# Changelog

## [0.2.0.0] - 2026-03-27

### Added

#### Phase 2 — Validation + Windows Spike
- **P2.1 Windows Audio Routing Spike**: WASAPI loopback validation on Windows — system audio can be captured without third-party drivers
- **P2.2 Payment Infrastructure**: LemonSqueezy one-time purchase integration with license key delivery
- **P2.3 Sarah Validation**: Customer discovery preparation and validation workflow

#### Phase 3 — Post-Validation Expansions
- **P3.1 Privacy Audit Export**: NetworkMonitor (NWPathMonitor) + HMAC-SHA256 signed session attestation + CoreGraphics PDF export with zero-cloud proof
- **P3.2 Windows Native App**: Complete C++ implementation with WASAPI loopback capture, ONNX Runtime transcription/translation, Win32 transparent overlay window, and GDI+ bilingual text rendering
- **P3.3 Human Interpreter Fallback (Pilot)**: Panic Button UI (red pulsing 🆘), Mock interpreter dispatch service, WebRTC audio bridge interfaces, per-minute billing (¥10/min, ¥100 minimum, pilot free)
- **P3.4 Speaker Diarization**: Incremental DBSCAN clustering (pure Swift), parallel execution with Whisper (zero latency impact), 10-color speaker labels (🔵 Speaker A), ECAPA-TDNN embedding placeholder
- **P3.5 Code-Switching Handling**: NLTagger-based language detection, mixed-language segment preservation, ~200-term bilingual business/technical dictionary (API, KPI, ROI, SaaS, 核心竞争力, 闭环, 赋能, etc.)

#### Phase 4 — Platform Expansion
- **P4.1 Multi-Language Support**: Extended to 4 languages (EN↔ZH↔JA↔KO) via single multilingual NLLB-200 model; language switcher in overlay toolbar; dynamic placeholder text per language
- **P4.2 P2P Shared Sessions**: WebRTC DataChannel architecture for multi-participant subtitle sharing (audio never transmitted); WebSocket/Firebase/Supabase signaling service interfaces; ParticipantManager with per-language subtitle routing
- **P4.3 Meeting Recording + Transcription**: AVAudioEngine M4A recording (16kHz AAC); JSON transcript persistence with full-text search; TXT/SRT/JSON export; recording indicator in overlay; meeting records UI
- **P4.4 Meeting Intelligence**: Local NLP summarization (NLTagger); rule-based action item extraction (Chinese: 要/需要/必须; English: will/should/need to); CoreGraphics Meeting Brief PDF generator with action items table
- **P4.5 iPhone Companion App**: Standalone iOS 17+ SwiftUI app (bundle: com.simultaneousinterpretation.ioscompanion); MultipeerConnectivity WiFi P2P sync from Mac; live translation display; history and meeting brief views

### Changed
- `project.yml`: Updated MLX to v0.31.1; added GoogleWebRTC dependency for interpreter fallback
- `InterpreterPipeline`: `sourceLanguage/targetLanguage` → `sourceLanguageCode/targetLanguageCode: LanguageCode`; added `broadcastSegment()` for P2P mode
- `OverlayView`: Language switcher popup; speaker labels; recording indicator; panic button integration; P2P sidebar and control bar
- `AppDelegate`: Integrated attestation lifecycle, interpreter service binding, recording lifecycle

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
