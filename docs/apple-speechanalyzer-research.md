# Research: Apple SpeechAnalyzer / SpeechTranscriber (WWDC 2025)

> Deep-research notes on Apple's new on-device speech-to-text model and its
> relevance as a transcription backend for this project (currently
> `mlx-whisper` + `pyannote`). Compiled 2026-07-16 from Apple primary docs +
> independent benchmarks; claims fact-checked via adversarial verification.

## TL;DR for meeting-transcribe

This project **already requires macOS 26 (Tahoe) on Apple Silicon** — the exact
platform gate that would otherwise disqualify Apple's new APIs. So the usual
"only on macOS 26 / M1+" blocker **does not apply here**. That makes
`SpeechTranscriber` a genuinely viable alternative (or opt-in fast path) to the
current `mlx-whisper` transcription step.

- ✅ **~2.2× faster** than Whisper (Large V3 Turbo) in independent hands-on tests, fully on-device, free.
- ✅ **German + English fully supported** (de_DE / de_AT / de_CH), plus ~20 other languages.
- ⚠️ **Swift-only API** — no Objective-C, no verified clean PyObjC bridge. Integration = ship a small Swift helper CLI and call it from Python.
- ⚠️ Accuracy is **comparable, not clearly better** than Whisper; may be weaker on non-EN/DE.
- ⚠️ **No built-in diarization** — `pyannote` is still needed for speaker separation. Apple gives transcription + timestamps, not "who spoke".
- ⚠️ Language coverage is ~22 languages vs Whisper's 100+.

## What it is

At WWDC 2025 Apple introduced a **brand-new, fully on-device speech-to-text
model** exposed through an expanded **Speech framework**:

- **`SpeechAnalyzer`** — a Swift `actor` that manages the analysis session and holds modules.
- **`SpeechTranscriber`** — the transcription module; most use cases only need this one module. (Siblings: `DictationTranscriber`, `SpeechDetector`.)
- Driven with **async/await + `AsyncSequence`**: audio buffers stream in, results stream out — input/output are decoupled (good for live/progressive transcription).
- Runs **entirely on-device** (no cloud). Apple built it for long-form, conversational, distant-mic, and low-latency use — i.e. exactly the meeting scenario.

## Platform / hardware requirements

| Requirement | Detail |
|---|---|
| OS | macOS 26 / iOS / iPadOS / tvOS / visionOS **26.0+** (not watchOS) |
| Hardware (Mac) | **Apple Silicon (M1+)** — Neural Engine acceleration; not on Intel |
| Toolchain | **Xcode 26** |
| API language | **Swift only** — no Objective-C parity (verified: refuted claim of ObjC variant) |

> Both requirements already match this repo's stated requirements
> (macOS Tahoe 26.x on Apple Silicon), so they cost us nothing.

## Model assets

Before use, apps install **locale-specific ML model "assets"** downloaded once
from Apple's servers (`AssetInventory`). The system retains, updates, and
**shares them across apps**. There is a cap on how many locales an app may
reserve:

- `reserve(locale:)`, `release(reservedLocale:)`, `reservedLocales`, `maximumReservedLocales`
- No automatic language detection like Whisper — the locale is chosen/reserved explicitly.
- Introduced in OS 26.0. No licensing fee surfaced in any source — assets are free and system-managed.

## Supported languages (SpeechTranscriber.supportedLocales)

**~22 languages across 42 locales.** German and English are both fully covered.

| Language | Locales |
|---|---|
| **German** ✅ | de_DE, de_AT, de_CH |
| English | en_US, en_GB, en_AU, en_CA, en_IE, en_IN, en_NZ, en_SG, en_ZA |
| Spanish | es_ES, es_MX, es_US, es_CL |
| French | fr_FR, fr_BE, fr_CA, fr_CH |
| Italian | it_IT, it_CH |
| Portuguese | pt_BR |
| Dutch | nl_NL, nl_BE |
| Chinese | zh_CN, zh_HK, zh_TW, yue_CN (Cantonese) |
| Japanese / Korean | ja_JP / ko_KR |
| Russian / Arabic / Hebrew | ru_RU / ar_SA / he_IL |
| Nordic | da_DK, nb_NO, sv_SE, fi_FI |
| Other | tr_TR, th_TH, vi_VN, ms_MY |

Two tiers exist: currently *installed* locales vs. *downloadable* ones. Query
`supportedLocales` at runtime; download on demand.

Compared to Whisper (100+ languages) this is narrow, but it covers the
languages this project realistically needs.

## Performance & accuracy vs Whisper

| | Apple SpeechTranscriber | Whisper (current: mlx-whisper) |
|---|---|---|
| Speed | **~2.2× faster** (34-min video: 45s vs 1m41s MacWhisper Large V3 Turbo) | slower |
| Accuracy (EN) | comparable, **not clearly better** — disputed | Large V3 Turbo often very strong |
| Languages | ~22 | 100+ |
| Diarization | ❌ none (transcription only) | ❌ none (we use pyannote) |
| Cost / privacy | free, on-device | free, on-device |

Verification caveats:
- The "faster **with no quality loss**" claim was **refuted** (0-3). Realistic read: faster, accuracy roughly on par at best.
- Argmax benchmark: Apple WER 14.0% beats Whisper-base but loses to Whisper-small (12.8%). One outlier (9to5Mac) had Whisper Large V3 Turbo ~1% WER vs Apple ~8%.
- Speed figures trace largely to a **single anecdotal benchmark** (one 34-min English file, one Whisper GUI) — direction is robust, magnitude is not a controlled study.

## Integration path (Python → Swift-only API)

The API is Swift-only and **there is no verified clean PyObjC bridge** (the
`import Speech` PyObjC route did *not* survive verification — the new classes are
Swift actors with async/await, which PyObjC bridges poorly).

**Recommended approach:** ship a tiny **Swift helper CLI** and call it from
Python via `subprocess` — the same shape as this repo's other vendored native
helpers (e.g. the WebRTC AEC `.dylib`).

Open-source reference: [`argmaxinc/apple-speechanalyzer-cli-example`](https://github.com/argmaxinc/apple-speechanalyzer-cli-example) (100% Swift):

```bash
swift build -c release
apple-speechanalyzer-cli \
  --input-audio-path <path> --output-txt-path <path> \
  [--locale de_DE] [--live]
```

- default: `.offlineTranscription`
- `--live`: `.progressiveLiveTranscription` (real-time streaming)

### How it would slot into this pipeline

1. Keep audio capture + AEC + chunking exactly as-is.
2. Add a `transcriber` backend abstraction: `mlx-whisper` (default) vs
   `apple-speech` (opt-in). The Apple backend shells out to the Swift CLI per
   chunk / file, returns text + word timestamps.
3. **`pyannote` diarization stays** regardless of backend — Apple provides no
   speaker separation. We'd align Apple's timestamps against pyannote's speaker
   turns, same as today with Whisper.
4. Locale is explicit (e.g. `de_DE`); reserve it once via `AssetInventory`.

## Recommendation

Worth a **proof-of-concept as an opt-in fast backend**, since this project's
platform already meets every Apple requirement for free:

- ✅ Big speed win on meeting-length audio, no extra cost, stays offline.
- ✅ DE/EN covered; timestamps available for diarization alignment.
- ⚠️ Not a full Whisper replacement — keep `mlx-whisper` as default/fallback for
  languages Apple doesn't support and for max accuracy.
- ⚠️ Adds a Swift build step + a helper binary to ship/maintain.

## Open questions

- Word-level timestamp quality vs Whisper — good enough to align against pyannote turns?
- Real accuracy on **German meeting audio** (not English single-file benchmarks)?
- Asset sizes / storage footprint and the actual `maximumReservedLocales` limit.
- Robustness on distant-mic / overlapping speakers vs the current Whisper path.

## Sources

Primary:
- [WWDC25 Session 277 — Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [SpeechAnalyzer — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechtranscriber)
- [SpeechTranscriber.supportedLocales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales)
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- [Bringing advanced speech-to-text capabilities to your app](https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
- [argmaxinc/apple-speechanalyzer-cli-example](https://github.com/argmaxinc/apple-speechanalyzer-cli-example)

Secondary / benchmarks:
- [MacStories — Hands-on: Apple's new Speech APIs outpace Whisper](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)
- [AppleInsider — Apple Intelligence transcription is twice as fast as Whisper](https://appleinsider.com/articles/25/06/18/apple-intelligence-transcription-is-twice-as-fast-as-openais-whisper)
- [Argmax — Apple and Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)
- [Anton Gubarenko — iOS 26 SpeechAnalyzer Guide](https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide)
