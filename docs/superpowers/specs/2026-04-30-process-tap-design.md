# Process Tap System Audio — Design Spec

**Date:** 2026-04-30
**Status:** Approved for implementation planning
**Supersedes:** Partially supersedes the system-audio capture portion of `2026-04-23-webrtc-aec-design.md`. Mic capture, AEC step, and downstream pipeline unchanged.

## Goal

Replace SCStream-based system-audio capture with a Core Audio Process Tap
(`AudioHardwareCreateProcessTap`, macOS 14.4+) that captures every process's
audio output except our own. Result: meeting-transcribe coexists with any
other tool capturing system audio (Notion Meeting Recorder, Teams Cloud
recording, QuickTime, OBS, Audio Hijack, etc.) without either side starving
the other.

The trigger: 2026-04-30 a real meeting recording produced 24 minutes of
metadata but only 9.8 seconds of system audio because Notion Meeting
Recorder was running in parallel and ScreenCaptureKit's system-audio output
is effectively exclusive across consumers. Process Taps were designed for
exactly this multi-consumer scenario and are the supported path on modern
macOS.

## Non-Goals

- Per-app capture targeting. We tap "everything except our own process" —
  same semantics as V2's `excludesCurrentProcessAudio = true`, implemented
  with translated Core Audio process `AudioObjectID`s. Per-app tap is a
  later feature if anyone asks.
- Replacing the mic path. Mic stays on SCStream (the 2026-04-23 RAW verdict
  still holds and mic input is not exclusive across processes).
- Real-time AEC. AEC remains a post-capture step inside `process`.
- A backwards-compat `setCapturesAudio` shim. The new path is mandatory.
- Auto-restart logic when the tap stops delivering after it has already
  started. That's issue #18. V3 only adds a startup no-delivery gate so a
  recording cannot begin with a dead system tap.

## Constraints

- macOS 14.4+ for `AudioHardwareCreateProcessTap`. We already require macOS
  Tahoe (26.x) per the V2 spec, so this is a tightening within an
  already-supported range.
- Apple Silicon. Same as V1/V2.
- Python-only. The CoreAudio C API surface is wrapped via
  `pyobjc-framework-CoreAudio` plus `ctypes` for missing C symbols, no Swift
  helper. `pyobjc-framework-CoreAudio` is an explicit runtime dependency in
  `pyproject.toml`. If pyobjc cannot expose `CATapDescription` or the C
  symbols cannot be loaded from CoreAudio via `ctypes`, the verification
  spike below catches it before refactoring.
- The `_WavRecorder` Protocol (`start()` / `stop()`) on `CaptureRecorder`
  stays intact.
- Wire format on disk (`mic_raw.wav`, `system.wav`) is unchanged. Old V2
  recordings remain processable. No migration.

## Verification Gate (mirrors V2 Task 1)

Before any production refactor, a 30-min throwaway spike answers four
empirical questions:

1. **Symbol availability and wiring.** Does pyobjc expose
   `CATapDescription`, process-object translation
   (`kAudioHardwarePropertyTranslatePIDToProcessObject`), tap UID lookup
   (`kAudioTapPropertyUID`), and aggregate tap-list setup
   (`kAudioAggregateDeviceTapListKey` / `kAudioSubTapUIDKey`, or the
   equivalent property setter)? Can `AudioHardwareCreateProcessTap`,
   `AudioHardwareCreateAggregateDevice`, `AudioDeviceCreateIOProcID`, and
   their destroy/stop counterparts be loaded from CoreAudio? If pyobjc's
   binding is incomplete and `ctypes` is not enough, we'd need a small Swift
   bridge — that materially changes the implementation plan.
2. **Tap delivery.** Does a private aggregate device containing the tap
   actually deliver non-empty buffers through an IO proc for at least 10s?
   This is a hard gate: creating a tap object is not enough; the aggregate
   must be wired to the tap UID and the callback must receive audio.
3. **Clock alignment.** Does `AudioTimeStamp.mHostTime` from the Process Tap
   share the same `mach_absolute_time` reference as `CMSampleBufferGetPresentationTimeStamp`
   from the SCStream microphone tap? Apple says yes; we verify by playing a
   beep through speakers while both taps run, locating the beep peak in both
   resulting tracks, and confirming the offset is < 20ms (well within the
   AEC AudioProcessing's tolerance).
4. **Permission UX.** Does first run from the Python CLI trigger the System
   Audio Recording prompt cleanly, and does it require an app-bundle
   `Info.plist` with `NSAudioCaptureUsageDescription`? If a plain console
   script cannot present the prompt or is denied without a usage string, we
   add a tiny launch wrapper/bundle before the refactor proceeds.

**Decision gate.** Spike result is RAW (symbols present or loadable,
aggregate wired to the tap, audio delivered, alignment holds, permission UX
known) → implementation plan proceeds as specified. Spike result is BLOCKED
→ escalate; possibly need a Swift helper or a launch wrapper for the tap
path. The spike output is committed as
`docs/superpowers/specs/2026-04-30-process-tap-verdict.md` and nothing else
changes until the verdict is in.

## Architecture

The change is surgical. Only the system-audio path moves.

```
V2 (current)                          V3 (after refactor)
────────────                          ────────────────────

  CaptureRecorder                      CaptureRecorder
    │                                    │
    └─ one SCStream                      ├─ SCStream (mic only)
        ├ audio output  ← exclusive!     │   └─ SCStreamOutputType.microphone
        └ mic output                     │
                                         └─ ProcessTap
                                             └─ everything except our process
                                                ← non-exclusive
```

**Component boundaries.**

`capture_recorder.py` keeps its public API. Internals split into two
private startup methods:

- `_start_mic_via_scstream()` — SCStream with `setCaptureMicrophone_(True)`
  and `setCapturesAudio_(False)` (do not claim system audio). Pushes
  `_TimedChunk` to `_mic_queue` exactly as today.
- `_start_system_via_process_tap()` — new. Constructs a `ProcessTap`
  instance from the new `_audio/process_tap.py` module, configured with
  our translated Core Audio process object excluded, registers a callback
  that converts each `AudioTimeStamp.mHostTime` to seconds and pushes a
  `_TimedChunk` to `_sys_queue`.

The writer thread, `_IncrementalTrackWriter`, AEC step, and everything
downstream are completely unchanged. They consume two queues of
PTS-tagged chunks; they don't care that one source is now a Process Tap.

**New module.** `meeting_transcribe/_audio/process_tap.py` (~150 LOC).
Single responsibility: wrap the CoreAudio Process Tap API and deliver
PTS-tagged audio chunks to a callback. Public surface:

```python
class ProcessTapError(RuntimeError):
    def __init__(self, message: str, os_status: int | None = None): ...

class ProcessTap:
    def __init__(self, on_chunk: Callable[[float, np.ndarray], None]): ...
    def start(self) -> None: ...   # raises ProcessTapError on failure
    def stop(self) -> None: ...    # idempotent
```

`on_chunk(pts_seconds, samples_float32_mono)` is the only contract with
`CaptureRecorder`. The PTS is on the host-time clock, directly comparable
to SCStream's CMTime PTS values.

**Why a separate module.** `capture_recorder.py` is already 681 lines.
Adding ~150 LOC of CoreAudio C-API ctypes plus aggregate-device management
would push it past the comfortable single-file threshold. The Process Tap
wrapper has one purpose and a clear interface; keeping it in its own file
matches the codebase's one-file-one-purpose discipline.

**Removed code.** `setCapturesAudio_(True)`, the
`SCStreamOutputTypeAudio` registration, the audio output's
`addStreamOutput` call. Mic-related SCStream wiring stays.

**File structure delta:**

```
meeting_transcribe/
    _audio/                     # new package
        __init__.py
        process_tap.py          # new — Process Tap wrapper
    capture_recorder.py         # modified — drop SCStream audio out
    cli.py                      # modified — friendly ProcessTapError exit 2
tests/
    test_process_tap.py         # new — unit tests with mocked CoreAudio
    test_capture_recorder.py    # modified — adjust mocks to ProcessTap
    test_integration_capture.py # modified — verify both tracks
pyproject.toml                  # modified — add pyobjc-framework-CoreAudio
```

## Process Tap Lifecycle

The `ProcessTap.start()` sequence:

1. **Resolve excluded process AudioObjectIDs.** Start from `os.getpid()`
   plus its parent PID. Parent inclusion is defensive: if pyobjc spawns a
   helper that registers as a separate audio client, it would otherwise leak
   its own audio back into our recording. Before building the tap
   description, translate each POSIX PID to a Core Audio process
   `AudioObjectID` via `kAudioHardwarePropertyTranslatePIDToProcessObject`
   on `kAudioObjectSystemObject`. `CATapDescription` process arrays contain
   `AudioObjectID`s, never raw PIDs. If our own PID cannot be translated,
   fail startup with `ProcessTapError`; if the parent PID cannot be
   translated, log and continue because it may not be an audio process.

2. **Build `CATapDescription`.** Set the tap to capture audio from "all
   processes except ours" using the translated process `AudioObjectID`s,
   e.g. `initMonoGlobalTapButExcludeProcesses:` or the current equivalent
   exposed by pyobjc. The exact selector/property spelling is pinned during
   the verification spike, but these semantics are not negotiable:
   - global system-output tap, not per-app targeting;
   - exclude our translated process object IDs;
   - private tap;
   - no output muting (`muteBehavior` leaves speakers/headphones audible);
   - mixdown allowed, with callback output normalized to mono float32
     16 kHz before it reaches `CaptureRecorder`.

3. **`AudioHardwareCreateProcessTap`.** Returns an `AudioObjectID`.
   Failure → `ProcessTapError(reason, os_status)` with the OSStatus.

4. **Get the tap UID.** Resolve the created tap's UID via
   `kAudioTapPropertyUID` (or the verified pyobjc equivalent). Keep this UID
   alive until teardown; the aggregate device refers to the tap by UID, not
   by the tap's `AudioObjectID`.

5. **`AudioHardwareCreateAggregateDevice` with the tap attached.**
   Create a private aggregate device with
   `kAudioAggregateDeviceIsPrivateKey = true` so it doesn't appear in the
   user's audio device picker, and include the tap in the aggregate's tap
   list (`kAudioAggregateDeviceTapListKey` containing a
   `kAudioSubTapUIDKey` entry for the tap UID, or the verified equivalent
   property-set path). The aggregate is required because tap output is
   delivered through the IO proc of an aggregate device — the tap object
   alone has no IO surface. An aggregate without the tap UID is a startup
   bug and must fail the verification spike.

6. **`AudioDeviceCreateIOProcID`** registers our IO callback. The
   callback:
   - extracts `inInputTime->mHostTime`, converts to seconds via
     `mach_timebase_info` (cached after first call: `(numer / denom) * 1e-9`).
   - extracts the first audio buffer as float32 samples.
   - resamples to 16 kHz mono if the source format differs (likely 48 kHz
     stereo from a typical output device).
   - calls `on_chunk(pts_seconds, samples)`.

7. **`AudioDeviceStart`.** Chunks flow.

8. **Startup delivery gate.** After `AudioDeviceStart`, `ProcessTap.start()`
   blocks until the first IO callback with a valid audio buffer arrives
   (silence is fine) or a 5s timeout expires. Timeout raises
   `ProcessTapError("system audio tap produced no buffers")` and cleans up
   the tap, aggregate, and IO proc. We do not allow a recording session to
   run for minutes with `_start_pts` waiting forever.

The `ProcessTap.stop()` sequence is the reverse and is idempotent:

1. `AudioDeviceStop`.
2. `AudioDeviceDestroyIOProcID`.
3. `AudioHardwareDestroyAggregateDevice`.
4. `AudioHardwareDestroyProcessTap`.

Each call's OSStatus is logged on non-zero return but stop swallows
errors. Mid-stop is best-effort cleanup, not a place to crash.

**OSStatus error mapping:**

| OSStatus                                  | meaning                          | our action                                      |
|-------------------------------------------|----------------------------------|-------------------------------------------------|
| `kAudioHardwareNoError` (0)               | success                          | continue                                        |
| `kAudioHardwareIllegalOperationError`     | TCC denied / API rejection       | `ProcessTapError("permission denied — System Settings → Privacy → System Audio Recording")` |
| `kAudioHardwareUnsupportedOperationError` | macOS < 14.4 OR no output device | `ProcessTapError("requires macOS 14.4+ and an audio output device")` |
| anything else                             | unknown error                    | `ProcessTapError(f"OSStatus {code}", os_status=code)` |

**Permission note.** Process Taps use macOS's System Audio Recording TCC
permission. This may be adjacent to, but must not be assumed identical to,
the ScreenCaptureKit prompt path we already use. The verification spike must
record the actual first-run behavior from the Python CLI. If macOS requires
`NSAudioCaptureUsageDescription`, the implementation adds the smallest
possible app/launcher wrapper that supplies that key; a silent denial or
traceback is not acceptable. README documents the exact System Settings
pane once verified.

## CaptureRecorder Integration

`_start_capture()` becomes:

```python
def _start_capture(self) -> None:
    self._start_mic_via_scstream()
    try:
        self._start_system_via_process_tap()
    except ProcessTapError:
        self._stop_scstream()
        raise
```

The system tap starts AFTER mic. Mic startup is the slower / more
permission-heavy path; if it fails we want to know first. If system-tap
creation fails, we tear down the started mic before propagating the
error.

`stop()` reverses: SCStream first (its async stop is the slow one),
ProcessTap second. Errors during shutdown are logged but swallowed —
shutdown is best-effort.

`cli.py` catches `ProcessTapError` from `record`, prints the message without
a Python traceback, calls `rec.stop()` only for successfully-started partial
sessions, and returns exit code 2. SCStream/mic failures keep their existing
behavior unless the implementation touches that path.

## Failure Modes

| Scenario                                        | Behavior |
|-------------------------------------------------|----------|
| Process Tap unsupported on this macOS           | `ProcessTapError` → CLI exits 2 with the message |
| TCC denied for system audio                     | `ProcessTapError` → CLI exits 2 with pointer to System Settings |
| Aggregate device creation fails                 | `ProcessTapError(os_status)` → CLI exits 2 |
| Aggregate device created without tap UID        | Verification spike fails; production code treats this as a startup bug, not a recoverable runtime state |
| IO proc never delivers (tap stuck)              | `ProcessTap.start()` times out before recording begins, cleans up, CLI exits 2. No 24-minute empty `system.wav`. |
| IO proc fires once then stops                   | Same as #18 for now: mic continues, system ends early. Mic.wav keeps full length (Fix B from `8e04283`), AEC processes overlap, appends mic tail unchanged. The recording is not considered proof of the Notion fix until the parallel-consumer test below shows continuous system capture. |
| Notion Recorder starts/stops mid-meeting        | Process Taps coexist by design — both keep getting samples. **This is the whole point.** |
| Audio output device changes mid-recording       | Aggregate device may need reconfiguration. Out of scope for this design — tracked as future hardening if observed. |
| Our own audio output (defensive)                | Translated process `AudioObjectID` excluded; doesn't leak back. |

**Removed failure mode:** SCStream's "another app stole the audio
source." Process Taps don't have a single audio source to fight over.

## Testing

**Unit tests (`tests/test_process_tap.py`).** Pure adapter-layer tests with
CoreAudio calls mocked:

- PID translation: given `excluded_pids=[1234]`, CoreAudio is asked to
  translate PID 1234 to a process `AudioObjectID`, and the tap description
  receives only translated object IDs.
- Tap-description construction: given translated excluded process objects,
  the serialized `CATapDescription` keys/values match the verified
  "global tap except our process objects, private, unmuted" semantics.
- Aggregate tap wiring: the aggregate-device create dictionary (or verified
  property-set calls) includes the tap UID in the aggregate tap list. A test
  fails if an aggregate can be created without the tap UID.
- IO-callback PTS conversion: given a fake `AudioTimeStamp` with known
  `mHostTime` and a mocked `mach_timebase_info`, the callback emits the
  correct PTS in seconds.
- IO-callback sample extraction: given a fake `AudioBufferList` with a
  known float32 buffer, the callback yields the correct numpy array.
- OSStatus → `ProcessTapError` mapping: parametrized over the table above.
- Lifecycle: `start()` invokes create/install/start in order with mocked
  CoreAudio. `stop()` invokes the reverse, idempotent on second call.
  Failure during step N of `start()` cleans up steps 0..N-1.
- Startup delivery gate: if no IO callback arrives within the timeout,
  `start()` raises `ProcessTapError`, cleanup runs, and
  `CaptureRecorder.start()` leaves no finalized empty recording behind.

**CLI tests (`tests/test_cli.py`).**

- `record` catches `ProcessTapError`, prints the friendly message, and
  returns 2 without a traceback.

**Integration test (`tests/test_integration_capture.py`, `-m integration`).**
Real hardware:

- The existing single-SCStream test is adapted: assert that mic comes from
  SCStream and system from ProcessTap, both deliver non-empty 16 kHz mono
  WAVs within 2s.
- New test: while the recorder runs, play `say -v Alex "test"`. Assert
  system.wav RMS in the say-window > 100. Confirms ProcessTap captures
  other-process audio.
- New test (the killer feature): start the recorder, play continuous
  system audio, then briefly allocate a SECOND audio consumer in a thread
  (another ProcessTap or an SCStream system-audio output) for ~2s. The
  recorder must keep capturing system audio before, during, and after that
  overlap; assert duration and RMS windows rather than just file existence.
  Regression test for the original Notion bug.
- Repeat the killer feature with consumer order reversed where possible:
  allocate the second consumer first, then start `CaptureRecorder`. This
  protects the real workflow where Notion may already be recording before
  `meeting-transcribe record` starts.

**Hardware verification (post-refactor, manual).** Real Notion Meeting
Recorder running in parallel during a real Teams meeting. Run both start
orders:

1. Start `meeting-transcribe record`, then start Notion Meeting Recorder.
2. Start Notion Meeting Recorder, then start `meeting-transcribe record`.

Confirm both tools produce usable recordings with no track stops and that
`system.wav` spans the actual meeting duration, not just the first few
seconds. Document as a verification note next to the V2 verification doc.

## Rollout

No data migration. New recordings produce the same `mic_raw.wav` +
`system.wav` files. Old V2 recordings still process correctly because the
`process` step doesn't care which API captured them. `meeting-transcribe
list` doesn't change.

README gets one paragraph noting V3's coexistence guarantee with other
system-audio recorders and updates first-run permission wording from
ScreenCaptureKit-only to the verified System Audio Recording prompt. Add
`pyobjc-framework-CoreAudio` to `pyproject.toml`; no package version bump —
internal architecture refactor.

## Risks and open questions

- **pyobjc symbol coverage.** If `AudioHardwareCreateProcessTap` or
  `CATapDescription` are missing from pyobjc-framework-CoreAudio, we'd need
  a Swift bridge. The verification spike resolves this before scope grows.
- **Process IDs vs process objects.** `CATapDescription` uses Core Audio
  process `AudioObjectID`s, not POSIX PIDs. The implementation must keep
  translation explicit and tested; this is a correctness risk because
  self-exclusion silently fails otherwise.
- **Aggregate tap-list wiring.** The aggregate device must include the tap
  UID. Creating a tap plus an empty private aggregate is possible but
  useless; the spike and unit tests must prove the UID is installed.
- **`AudioBufferList` packing layout in pyobjc.** The struct is variable-
  length (one `AudioBuffer` entry per channel). Reading mBuffers[0] from
  pyobjc may need a custom struct definition. Implementation detail; not
  a design risk.
- **Aggregate device persistence.** If our process crashes mid-recording,
  does the private aggregate device leak in CoreAudio's registry? Apple
  cleans up on process exit, but a hard kill might orphan it. Worth
  watching during integration tests.
- **TCC prompt UX on first run.** macOS 14.4+ Process Taps may require
  `NSAudioCaptureUsageDescription` and may present a prompt distinct from
  ScreenCaptureKit's. Verification spike catches this; if a plain CLI
  cannot satisfy the requirement, add the smallest possible launcher/bundle
  and document it in README.
