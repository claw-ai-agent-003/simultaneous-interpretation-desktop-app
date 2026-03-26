# Privacy-First Offline Simultaneous Translation Desktop App

**Status:** PLANNING — Phase 1 not started

**Architecture:** Native macOS App (Swift/SwiftUI) with MLX for offline AI inference

**Approved Design:** `~/.gstack/projects/simultaneous-interpretation/root-master-design-20260326-browser-extension.md`

**TODOS:** `TODOS.md`

## Phase 1: Wedge — Mac Native App

- macOS Audio Capture (AVAudioEngine, microphone input)
- MLX Whisper Integration (English↔Mandarin)
- NLLB Translation Pipeline
- SwiftUI Overlay
- Privacy Verification UI
- Distribution Pipeline

## Key Decisions

- **Form:** Native macOS app (not browser extension — WebExtensions can't capture system audio)
- **Audio:** Microphone input only (no CoreAudio loopback in Phase 1)
- **Privacy:** Visual indicator only in Phase 1 (no network monitoring until P3.1)
- **Payment:** One-time purchase
- **Target:** Apple Silicon (M1+) only
