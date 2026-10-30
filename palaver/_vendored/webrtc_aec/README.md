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

## Building (palaver vendor fork)

The upstream CMakeLists.txt re-compiles `src/aec_api.cpp`, which requires
WebRTC-internal headers that upstream does not ship. Our `CMakeLists.txt`
instead links the pre-built `lib/Darwin/libraven_aec.a` into a dylib;
`src/` and `include/` are kept for reference and license compliance only.

See `THIRD_PARTY.md` for the licensing / provenance story.

### macOS (arm64)
```bash
cd palaver/_vendored/webrtc_aec
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
# Produces libraven_aec.dylib next to this README.
```

### Windows / Intel macOS
Not supported by this fork yet. Upstream ships universal (x86_64 + arm64)
WebRTC libs in `lib/macos/` and Windows libs in `lib/windows/`, but
`lib/Darwin/libraven_aec.a` is arm64-only and that's all the vendor fork
currently wires up.

## Pre-built Libraries

Pre-built libraries are included in `lib/` for CI convenience:
- `lib/macos/libwebrtc_audio_processing.a` - Universal (x86_64 + arm64)
- `lib/windows/webrtc_audio_processing.lib` - x64

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
