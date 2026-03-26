# TODOS.md - Privacy-First Simultaneous Translation Wedge

## Status: PLANNING PHASE — Pre-Implementation

**Supersedes:** All prior TODOS referencing Electron+MLX+P2P+B browser extension architecture.
**Source of truth:** `root-master-design-20260326-browser-extension.md` (APPROVED)

**Design decisions (APPROVED):**
- Architecture: Native+MLX (Swift/SwiftUI for Mac)
- Target: Mac only (Apple Silicon M1+ required — MLX only on Apple Silicon)
- Language pair: English↔Mandarin only (wedge scope)
- Payment: One-time purchase
- Privacy: Local inference only + network activity indicator + per-session attestation log

---

## Phase 1: Wedge — Mac Native App (Weeks 1-4)

**Status: PHASE 1 COMPLETE** — All P1 items shipped in PR #1.

### P1.1: macOS Microphone Audio Capture
- **What:** Capture audio via microphone input using AVAudioEngine
- **Why:** Required for simultaneous translation. Sarah points laptop mic at speakers in meetings.
- **Effort:** S (1 week) → with CC+gstack: S
- **Priority:** P1
- **Context:** AVAudioEngine microphone capture. Requires microphone permission only (no Screen Recording permission needed). Works for in-person meetings where Sarah points mic at the speakerphone. For Zoom/Teams calls where audio comes through the laptop speakers (not the mic), this approach captures the mixed meeting audio — acceptable for wedge.
- **Limitation:** Does NOT capture system audio directly (no CoreAudio loopback). In-person or laptop-speaker meetings only. Remote meeting audio capture via screen sharing is NOT in scope.

### P1.2: MLX Whisper Integration
- **What:** Integrate Whisper-base (ONNX exported to MLX format) for English↔Mandarin transcription
- **Why:** Core ASR engine — must be fast enough for real-time
- **Effort:** M (1-2 weeks) → with CC+gstack: M
- **Priority:** P1
- **Context:** Use Xenova/whisper-base ONNX. Test latency on M1, M2, M3. Target: ≤1.5s per audio chunk.

### P1.3: MLX NLLB-200 Integration
- **What:** Integrate NLLB-200 distilled for English↔Mandarin translation
- **Why:** Core translation engine — must maintain meaning and nuance
- **Effort:** M (1-2 weeks) → with CC+gstack: M
- **Priority:** P1
- **Context:** Use distilled NLLB-200 variant (~1GB). Verify MLX compatibility. Target: ≤1.5s translation latency.

### P1.4: Pipelined Inference Architecture
- **What:** Concurrent/pipelined Whisper → NLLB processing to meet ≤3s end-to-end target
- **Why:** Sequential processing may exceed 3s target. Must be pipelined.
- **Effort:** M (1 week) → with CC+gstack: M
- **Priority:** P1
- **Context:** Audio chunk → Whisper (async) → NLLB (async) → overlay. Use Swift concurrency (async/await, actors). Chunk size + overlap strategy must be tuned.

### P1.5: SwiftUI Overlay Rendering
- **What:** Live bilingual text overlay (English + Mandarin) rendered via SwiftUI
- **Why:** Core UX — must be non-disruptive, readable, and low-latency
- **Effort:** M (1 week) → with CC+gstack: M
- **Priority:** P1
- **Context:** Fixed position (bottom-center, semi-transparent background). Font size must be readable at meeting distance. Chinese characters must render correctly (San Francisco system font supports CJK). Scroll behavior: show last N lines, auto-scroll.
- **Layout:** Stacked format — English text above, Mandarin translation directly below. Small language tag at the start of each line ("EN" / "中"). One segment = 2 lines. No speaker attribution in Phase 1 (diarization deferred to P3.4).
- **Interaction states:**
  - Pre-session (app launched): Overlay visible, shows "Point your mic at the speaker and speech will appear here." Real-time audio level bar (mic input indicator) confirms the app is capturing sound before the meeting starts.
  - Processing (≤3s pipeline): English text appears when Whisper completes (~1.5s), Mandarin appears when NLLB completes (~3s). Subtle "..." placeholder with pulse animation between completion stages.
  - Live session: EN→ZH stacked pairs auto-scroll. Most recent pair at bottom.
  - Low confidence: Small yellow/orange dot indicator (●●○○ style) inline with the low-confidence segment. No modal, popup, or interruption.
  - Session end: Overlay shows "Session ended" with final segment frozen. Auto-clears after 10s or on tap outside.
- **Critical moment limitation (Phase 1):** Low-confidence moments have no escalation path. Sarah must decide whether to trust the translation or ask the speaker to repeat. Human interpreter panic button is Phase 2 (P3.3) — intentionally absent from wedge.

### P1.6: Privacy Verification UI
- **What:** Visual "Privacy Mode" indicator in the overlay
- **Why:** Makes the privacy guarantee visible
- **Effort:** S (1 week) → with CC+gstack: S
- **Priority:** P1
- **Context:** Simple UI indicator showing "Privacy Mode Active" with a toggle. No actual network monitoring in Phase 1. The visual presence of the indicator serves as a trust signal. Real network attestation (signed per-session log) deferred to P3.1 Privacy Audit Export.
- **Interaction states:**
  - Default: "Privacy Mode: Active" with green dot indicator. Toggle is ON.
  - Toggle OFF (user-initiated): Indicator changes to "Privacy Mode: Off" with gray dot. No actual monitoring change in Phase 1.
  - Toggle failure: N/A in Phase 1 (no actual network monitoring to fail).

### P1.7: Distribution Pipeline
- **What:** GitHub Actions CI/CD for automated .dmg builds, code signing, notarization
- **Why:** Cannot ship Mac app without signing
- **Effort:** M (1-2 weeks) → with CC+gstack: M
- **Priority:** P1
- **Context:** Mac notarization required ($99/year developer account). Test the signing+notarization pipeline early — first-time notarization can take hours to days for new Apple Developer accounts.

---

## Phase 2: Validation + Windows Spike (Weeks 5-8)

### P2.1: Windows Audio Routing Spike
- **What:** Validate WASAPI loopback on Windows — can system audio be captured without third-party virtual audio cable drivers?
- **Why:** Windows audio routing is fragmented. If third-party drivers required, "install and go" breaks.
- **Effort:** S (1 week spike) → with CC+gstack: S
- **Priority:** P1
- **Decision gate:** If no viable routing without drivers → Windows deferred indefinitely or pivot to hardware audio passthrough

### P2.2: Payment Infrastructure
- **What:** One-time purchase payment flow (Lemonsqueezy or equivalent)
- **Why:** Must be able to charge before launch
- **Effort:** S (1 week) → with CC+gstack: S
- **Priority:** P1
- **Context:** Lemonsqueezy or Paddle for Mac app payment. License key delivery. Simple — no subscription infrastructure needed for wedge.

### P2.3: Sarah Validation
- **What:** Show wedge to Sarah Chen. Get payment commitment.
- **Why:** Validates the wedge before Phase 2 expansion
- **Effort:** S (1 meeting)
- **Priority:** P0
- **Ask:** "Would you pay [X] yuan for this, today, before next week's executive Q&A?"

---

## Phase 3: Post-Validation Expansions

### P3.1: Privacy Audit Export
- **What:** Exportable PDF per meeting proving zero bytes sent to cloud (signed attestation)
- **Why:** Enterprise differentiator — converts "we promise" into "here's the proof"
- **Effort:** S (1 week) → with CC+gstack: S
- **Priority:** P2
- **Depends on:** Phase 1 complete

### P3.2: Windows Native App (if P2.1 VALIDATED)
- **What:** ONNX-based Windows implementation if audio routing validated
- **Effort:** M → with CC+gstack: M
- **Priority:** P2
- **Depends on:** P2.1 (Windows Audio Routing Spike — VALIDATED)

### P3.3: Human Interpreter Fallback (Pilot)
- **What:** Panic button connecting to verified interpreter in ~60 seconds (pilot: 10 interpreters, 9-5 coverage, ~100 yuan/call)
- **Why:** Insurance against AI failure + revenue stream
- **Effort:** M (3-4 weeks + ops) → with CC+gstack: M
- **Priority:** P2
- **Depends on:** Phase 1 validation + ops setup (interpreter network)
- **Context:** This is a SERVICE business, not just software. Requires: interpreter vetting, on-call rotation, SLA monitoring, payment to interpreters. Pilot before 24/7 coverage.

### P3.4: Speaker Diarization
- **What:** Label different speakers in overlay (Speaker A / Speaker B)
- **Why:** Executive Q&A format has multiple speakers — labeling improves readability
- **Effort:** M → with CC+gstack: M
- **Priority:** P2
- **Depends on:** Phase 1

### P3.5: Code-Switching Handling
- **What:** Handle English technical terms embedded in Mandarin (and vice versa) without context switching
- **Why:** Bilingual executive meetings commonly mix technical jargon
- **Effort:** M → with CC+gstack: M
- **Priority:** P2
- **Depends on:** Phase 1 (Whisper/NLLB baseline working)

---

## Phase 4: Platform Expansion (Post-Phase-3)

### P4.1: Multi-Language Support (5 languages)
- **What:** Chinese ↔ English ↔ Japanese ↔ Korean with bidirectional translation
- **Why:** Asia-Pacific business requires 3+ languages
- **Effort:** M → with CC+gstack: M
- **Depends on:** NLLB-200 infrastructure validated in Phase 1

### P4.2: P2P Shared Sessions
- **What:** Multi-participant meetings where each sees subtitles in their preferred language
- **Why:** The 10x platform vision — replaces human interpreters, network effects
- **Effort:** XL (8-12 weeks) → with CC+gstack: XL
- **Depends on:** Phase 3 + iOS companion app

### P4.3: Meeting Recording + Transcription
- **What:** Full audio recording, local transcription, searchable transcripts, clip export
- **Why:** Platform lock-in for high-stakes meetings
- **Effort:** M → with CC+gstack: M
- **Depends on:** Phase 1

### P4.4: Meeting Intelligence
- **What:** Auto-summary, action items extraction, "Meeting Brief" PDF
- **Why:** Daily habit formation — transforms tool into assistant
- **Effort:** M → with CC+gstack: M
- **Depends on:** Meeting Recording

### P4.5: iPhone Companion App
- **What:** iPhone app for live translation, meeting briefs, voice memos, local WiFi sync
- **Why:** Executives are mobile. Conference room use case.
- **Effort:** L → with CC+gstack: L
- **Depends on:** Phase 2

---

## Deferred / Backlog

### Intel Mac Support
- **What:** ONNX-based fallback for Intel Macs (MLX Apple Silicon only)
- **Why:** ~30% of Mac users still on Intel (declining but non-zero)
- **Effort:** M → with CC+gstack: M
- **Priority:** BACKLOG
- **Note:** Not worth building for wedge. Evaluate post-Phase-1 if market demand exists.

### Enterprise Features (Team Management, Billing)
- **What:** Team accounts, admin dashboard, usage analytics
- **Why:** B2B enterprise sales (law firms, hospitals, corporations)
- **Effort:** L → with CC+gstack: L
- **Priority:** Phase 4+
- **Depends on:** Phase 1-3 validation

### App Store Submissions
- **What:** Mac App Store, iOS App Store, Windows Store
- **Why:** Distribution, automatic updates, trust signal
- **Effort:** M → with CC+gstack: M
- **Priority:** Phase 4+

### Language Expansion (10+ languages)
- **What:** French, German, Spanish, Italian, Thai, Vietnamese + others
- **Effort:** M → with CC+gstack: M
- **Priority:** Phase 4+
- **Depends on:** Model optimization (Phase 4)

---

## Completed

### Phase 1 — Mac Native App
- **P1.1 macOS Microphone Audio Capture** — **Completed:** v0.1.0.0 (2026-03-26)
- **P1.2 MLX Whisper Integration** — **Completed:** v0.1.0.0 (2026-03-26)
- **P1.3 NLLB-200 Translation** — **Completed:** v0.1.0.0 (2026-03-26)
- **P1.4 Pipelined Inference Architecture** — **Completed:** v0.1.0.0 (2026-03-26)
- **P1.5 SwiftUI Overlay Rendering** — **Completed:** v0.1.0.0 (2026-03-26)
- **P1.6 Privacy Verification UI** — **Completed:** v0.1.0.0 (2026-03-26)

---

## Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| macOS audio capture requires permissions/drivers | Medium | High | Spike first (P1.1) |
| Sequential Whisper+NLLB exceeds 3s latency | High | High | Pipelined architecture (P1.4) |
| MLX model compatibility on M1/M2/M3 | Low | High | Test early in P1.2 |
| Apple Silicon only excludes Intel users | High | Medium | Accept as Phase 1 constraint; revisit post-validation |
| Windows audio routing needs third-party drivers | High | High | Spike first (P2.1) — may block Windows entirely |
| Mac notarization delays/failures | Medium | Medium | Run pipeline early in P1.7 |
| NLLB-200 code-switching quality | Medium | Medium | Accept baseline; handle in Phase 3 |

---

## Decisions Made (APPROVED)

| Decision | Rationale |
|----------|-----------|
| Native+MLX (Swift/SwiftUI) | Browser extension rejected — WebExtensions can't capture system audio |
| Mac only (Apple Silicon) | MLX only runs on Apple Silicon. Intel deferred to backlog. |
| English↔Mandarin only | Validated first pair. Ship one language to ship fast. |
| One-time purchase | Simpler than per-use metering. Test per-use with Sarah. |
| No cloud fallback | Privacy guarantee is absolute. Human fallback is Phase 2+, not wedge. |
| No human interpreter in wedge | Privacy guarantee must be absolute. Fallback is a Phase 2 feature. |
| No multi-language in wedge | Scope discipline. Expand only after validation. |
| No meeting recording in wedge | Scope discipline. Add after translation core validates. |

---

**Last Updated:** 2026-03-26 (CEO Review — SELECTIVE EXPANSION mode)
**Status:** PLANNING — Architecture APPROVED, implementation not started
**Source:** Design doc `root-master-design-20260326-browser-extension.md` (APPROVED)

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 1 | CLEAR | 3 proposals, 3 accepted |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR | SCOPE REDUCED mode |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | CLEAR | 5/10 → 6/10, 4 decisions added |

**VERDICT:** CEO + ENG + DESIGN CLEARED — ready to implement.
