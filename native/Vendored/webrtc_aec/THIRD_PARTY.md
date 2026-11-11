# Third-party code

This directory is vendored from
[`Laxcorp-Research/project-raven`](https://github.com/Laxcorp-Research/project-raven)
(MIT license), specifically the `src/native/webrtc-aec/` subtree as of commit
`da117ced11f056e95dd2b840f3e66aaf43375f45` (pull date: 2026-04-24).

## project-raven

Source:  https://github.com/Laxcorp-Research/project-raven
License: MIT

The wrapper C API in `src/aec_api.cpp` / `include/aec_api.h` is authored by
the project-raven maintainers. It is retained here for license compliance
and reference only; it is **not** compiled as part of this vendor fork —
see below.

## WebRTC static libraries (`lib/macos/*.a`, `lib/Darwin/libraven_aec.a`)

`libwebrtc_audio_processing.a`, `libcommon_audio.a`, `libsystem_wrappers.a`,
and `libwebrtc.a` are pre-built from the WebRTC audio-processing codebase
(WebRTC M124 per upstream's README).

License: BSD-3-Clause (Google, The WebRTC project authors).
Source:  https://webrtc.googlesource.com/src

`libraven_aec.a` (`lib/Darwin/`) is the project-raven maintainers' pre-built
object archive of their `aec_api.cpp`, linked against the WebRTC libs
above. It is arm64-only.

These binaries are embedded unchanged. We do not modify or redistribute
WebRTC source code; see the WebRTC project's license headers for full terms.

## Why pre-built rather than rebuild from source

`src/aec_api.cpp` includes WebRTC-internal headers
(`webrtc/modules/audio_processing/include/audio_processing.h`,
`webrtc/modules/interface/module_common_types.h`) that the upstream repo
does not ship — `third_party/webrtc/` is an empty directory and
`include/webrtc/audio_processing.h` is a flat stub. Reconstructing the full
WebRTC header tree would require running `depot_tools gclient sync` against
Chromium's WebRTC branch, which is hours of work and out of scope for V2.

Palaver therefore links the pre-built `lib/Darwin/libraven_aec.a` (which
already contains a compiled `aec_api.cpp.o`) with the WebRTC static libs via
`-force_load` into `palaver-worker` (the `CRavenAEC` target in
`native/Package.swift`).
