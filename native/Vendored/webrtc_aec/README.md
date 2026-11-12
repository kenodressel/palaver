# WebRTC Audio Processing (AEC3)

This directory contains WebRTC's audio processing module, specifically the AEC3 (Acoustic Echo Cancellation) component.

## What is AEC3?

AEC3 is WebRTC's third-generation echo canceller. It removes speaker audio that bleeds into the microphone, enabling clean voice capture even when using speakers instead of headphones.

## Architecture
```
System Audio (speakers) ──► aec_process_render() ──┐
                                                   ├──► AEC Algorithm
Microphone Audio ─────────► aec_process_capture() ─┘
                                                   │
                                                   ▼
                                          Clean Mic Output
                                          (echo removed)
```

## How Palaver uses it

Nothing here is compiled. `native/Package.swift`'s `CRavenAEC` target force-loads
the pre-built `lib/Darwin/libraven_aec.a` (arm64, a fully compiled `aec_api.cpp.o`)
with the WebRTC static libraries in `lib/macos/` into `palaver-worker`, and its
module map uses `include/aec_api.h` in place. `src/` and the rest of `include/`
are kept for reference and license compliance only: recompiling `src/aec_api.cpp`
needs WebRTC-internal headers that upstream does not ship.

See `THIRD_PARTY.md` for the licensing / provenance story.

## Pre-built Libraries

Pre-built libraries are included in `lib/`:
- `lib/Darwin/libraven_aec.a` - the C API below (arm64)
- `lib/macos/libwebrtc_audio_processing.a`, `libcommon_audio.a`, `libsystem_wrappers.a`,
  `libwebrtc.a` - Universal (x86_64 + arm64)
  `libwebrtc_audio_processing.a` had WebRTC's `transient_click_annotate` tool in it, which defines `main`; it was
  removed from both slices (`ar d`) because newer linkers refuse a test bundle with a second `main`.

## C API

The C API (`include/aec_api.h`) provides a simple interface:
- `raven_aec_create()` - Create AEC processor
- `raven_aec_destroy()` - Clean up
- `raven_aec_process_render()` - Feed speaker/system audio (reference)
- `raven_aec_process_capture()` - Process mic audio, get clean output
- `raven_aec_set_stream_delay()` - Set estimated delay if known

## Source

Based on WebRTC M124 audio processing module.
Original: https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/
