# Windows Audio Routing Spike — P2.1

## Objective

Validate WASAPI loopback capture on Windows without third-party virtual audio cable drivers.

## Problem Statement

Windows audio routing is fragmented:
- **WASAPI Loopback**: Captures system audio (theoretically)
- **Third-party drivers** (e.g., Virtual Audio Cable, VB-Audio): Required for some scenarios
- **"Install and go"** requirement may break if drivers are needed

## Research Findings

### WASAPI Loopback

Windows Audio Session API (WASAPI) provides loopback capture:

```cpp
// Pseudo-code for WASAPI loopback capture
CoCreateInstance(CLSID_MMDeviceEnumerator, ...)
ActivateAudioDevice()  // Get default render device
IAudioClient::Initialize(AUDCLNT_SHARMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, ...)
IAudioCaptureClient::GetBuffer(...)  // Receives rendered audio
```

### Reality Check

1. **WASAPI loopback works for most applications** — Chrome, Zoom, Teams, etc.
2. **Some applications bypass WASAPI** — Games with exclusive mode, certain legacy apps
3. **No admin rights needed** — Unlike some virtual cable drivers
4. **Windows 10/11** — Works in both

### Conclusion

**Viable for target use cases** (Sarah Chen's Zoom/Teams meetings):
- ✅ Most video conferencing apps use WASAPI
- ✅ No admin rights required
- ✅ Built into Windows

### Risk Mitigation

If exclusive-mode apps fail, graceful degradation:
- Show warning: "Some apps may require screen share audio"
- Document known incompatible apps

## Spike Implementation

Created minimal Windows audio capture stub for future implementation.

## Decision

**Windows audio routing is VIABLE without third-party drivers for the target use case.**

Defer Windows implementation to Phase 3+ after macOS validation.
