"""CLI dispatch."""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path

import soundfile as sf

from . import migrate, notify
from .config import Config, default_config_path, load_config
from .paths import RecordingPaths
from .session_log import event, session_log, stage


def _cmd_record(args: argparse.Namespace) -> int:
    from .session import RecordingSession

    cfg = _load_cfg(args)
    session = RecordingSession(cfg.output_dir)

    stop_event = threading.Event()

    def _on_sigint(_signum, _frame):
        stop_event.set()

    meter = None
    prev_handler = signal.signal(signal.SIGINT, _on_sigint)
    try:
        folder = session.start()
        paths = RecordingPaths(folder)
        print(f"Recording to {folder}", flush=True)
        print("Press Ctrl+C to stop.", flush=True)
        print(f"Microphone via {session.mic_source}, system audio via {session.system_source}.", flush=True)
        for track in session.missing:
            print(f"⚠ Not recording the {track} — run `palaver doctor`.", flush=True)
        if not args.quiet and sys.stdout.isatty():
            from .meter import LevelMeter

            meter = LevelMeter(
                [
                    ("mic", Path(str(paths.mic_raw_wav) + ".part")),
                    ("system", Path(str(paths.system_wav) + ".part")),
                ]
            )
            meter.start()
        stop_event.wait()
    finally:
        signal.signal(signal.SIGINT, prev_handler)
        if meter is not None:
            meter.stop()
        if session.recording:
            print("\nStopping…")
            session.stop()

    print(f"Saved: {folder}")
    if args.run:
        return _cmd_run(
            argparse.Namespace(
                folder=str(folder), config=args.config, dictionary=args.dictionary
            )
        )
    return 0


def _cmd_doctor(args: argparse.Namespace) -> int:
    from . import doctor

    path = Path(args.config).expanduser() if args.config else default_config_path()
    checks = doctor.run_checks(config_path=path, offline=args.offline)
    print(doctor.format_report(checks))
    failed = sum(c.status == "fail" for c in checks)
    print(f"\n{failed} problem(s) to fix." if failed else "\nAll set.")
    return 1 if failed else 0


def _cmd_app(args: argparse.Namespace) -> int:
    from . import app_bundle
    from .daemon import forwarded_cli_options

    if args.action == "autostart":
        enabled = args.state != "off"
        app_bundle.set_autostart(enabled)
        print("Palaver starts at login." if enabled else "Autostart removed.")
        return 0
    if args.action == "build-release":
        app = app_bundle.build_release_app(Path(args.dest))
        print(f"Built {app}")
        return 0
    if args.action == "restart-web":
        return _restart_web()
    if args.action == "uninstall":
        removed = app_bundle.uninstall()
        print("\n".join(f"Removed {p}" for p in removed) or "Nothing installed.")
        return 0
    if args.store_tokens:
        stored = app_bundle.store_tokens_in_keychain()
        print(f"Stored {', '.join(stored) or 'no tokens (none set in this shell)'} in the login Keychain.")
    app = app_bundle.install(
        python=Path(sys.executable),
        cli_options=forwarded_cli_options(args),
        login=args.login,
    )
    print(f"Installed {app}" + (" (starts at login)" if args.login else ""))
    print(
        "Open it, then allow Microphone and System Audio Recording for\n"
        "Palaver when macOS asks. `palaver doctor` run from\n"
        "Terminal checks the terminal's permissions, not the app's."
    )
    return 0


# The running server finishes its changes (process.DRAIN_SECONDS), the new
# one has READY_TIMEOUT to come up: wait longer than both.
RESTART_WEB_TIMEOUT = 100.0


def _restart_web() -> int:
    """Restart only the Meetings window's server (#57): any time, also during
    a call; the recording runs in the app and is never touched."""
    from . import appctl

    try:
        answer = appctl.call("restart_web", timeout=RESTART_WEB_TIMEOUT)
    except appctl.CallFailed:
        print("Palaver is not running, or did not answer, or still runs the window's server inside the\n"
              "app (a version from before #57: restart the whole app once). Nothing was restarted.")
        return 1
    except appctl.CallRefused as exc:
        print(f"Palaver did not restart the window's server: {exc}")
        return 1
    pid = (answer or {}).get("pid")
    if not pid:
        print("Palaver restarted the window's server, but it is not up yet; see the log.")
        return 1
    print(f"Restarted the window's server (pid {pid}); the window reloads where it was.")
    return 0


def _cmd_webapp_serve(args: argparse.Namespace) -> int:
    from .daemon import LOG_PATH, forwarded_cli_options
    from .session_log import session_log
    from .webapp import process

    sys.stdout.reconfigure(line_buffering=True)
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with session_log(LOG_PATH):
        event("webapp_start")
        return process.serve(_load_cfg(args), forwarded_cli_options(args), listen_fd=args.listen_fd,
                             ready_fd=args.ready_fd, port=args.port,
                             app_socket=Path(args.app_socket) if args.app_socket else None)


def _cmd_menubar(args: argparse.Namespace) -> int:
    from .menubar import run_app

    from .daemon import forwarded_cli_options

    # The app's output goes to app.log: write each line at once, or warnings
    # sit in the buffer and are lost when the app quits.
    sys.stdout.reconfigure(line_buffering=True)
    from .daemon import DaemonRunning

    try:
        run_app(_load_cfg(args), forwarded_cli_options(args))
    except DaemonRunning as exc:  # a second Palaver must not touch the first one's recording
        print(f"error: {exc}")
        notify.notify("Palaver is already running", str(exc))
        return 1
    return 0


def _cmd_daemon(args: argparse.Namespace) -> int:
    from .daemon import LOG_PATH, build_daemon, forwarded_cli_options, quit_reason, read_status

    if args.action == "status":
        print(read_status())
        return 0

    cfg = _load_cfg(args)
    from .daemon import DaemonRunning

    try:
        daemon = build_daemon(cfg, forwarded_cli_options(args))
    except DaemonRunning as exc:
        print(f"error: {exc}")
        return 1
    stop_event = threading.Event()
    reason = ["restart"]  # how the daemon was stopped: Ctrl+C is the user's own stop

    def _on_signal(signum, _frame):
        reason[0] = quit_reason(signum)
        stop_event.set()

    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    print(f"Watching for Teams calls (log: {LOG_PATH}). Ctrl+C to quit.", flush=True)
    previous = {sig: signal.signal(sig, _on_signal) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with session_log(LOG_PATH):
            event("daemon_start")
            try:
                daemon.run(until=stop_event.is_set)
            finally:
                daemon.shutdown(reason[0])
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return 0


def _cmd_process(args: argparse.Namespace) -> int:
    cfg = _load_cfg(args)
    folder = Path(args.folder)
    paths = RecordingPaths(folder)
    if not folder.is_dir():
        print(f"error: {folder} is not a recording folder.")
        return 2
    dictionary_path = Path(args.dictionary).expanduser() if args.dictionary else None
    if dictionary_path is not None and not dictionary_path.is_file():
        print(f"error: dictionary {dictionary_path} not found.")
        return 2
    from .continuation import parts, still_recording
    from .live import worker_running

    recording = still_recording(folder)
    if recording:
        print(f"error: {recording[0].name} is still being recorded; "
              f"{folder.name} is processed once the recording stops.")
        return 3
    busy = [f for f in (folder, *parts(folder)) if worker_running(f)]
    if busy:
        print(f"error: {busy[0].name} is still being processed live; try again in a minute.")
        return 3
    from . import usage

    started = time.monotonic()
    rc = 1
    try:
        with session_log(paths.session_log):
            event("process_start", dictionary=str(dictionary_path) if dictionary_path else None)
            rc = _process(cfg, folder, paths, dictionary_path, notes=not getattr(args, "no_notes", False))
            event("process_done", rc=rc)
    finally:
        usage.record("process", seconds=time.monotonic() - started, ok=rc == 0, transcriber=getattr(cfg, "transcriber", None))
    if rc == 0:
        _refresh_coach_baseline(cfg)
    if rc == 0 and getattr(args, "cmd", None) == "process":
        notify.notify("Transcript ready", folder.name, folder.name)
    return rc


def _refresh_coach_baseline(cfg) -> None:
    """The live coach's baseline (#41), with this meeting in it: computed
    here, after the call, so the app never reads every meeting during one."""
    from . import coach

    try:
        coach.refresh_baseline(cfg.output_dir, user_name=cfg.user_name)
    except Exception as exc:  # the transcript is there either way
        print(f"warning: could not update the coach's baseline: {exc}")


def _make_transcriber(cfg: Config, dictionary_path: Path | None):
    from .dictionary import load_dictionary
    from .transcriber import make_transcriber

    return make_transcriber(
        cfg.transcriber,
        whisper_repo=cfg.whisper_repo,
        dictionary=load_dictionary(dictionary_path),
        language=cfg.language,
        parakeet_repo=cfg.parakeet_repo,
    )


def _cmd_live(args: argparse.Namespace) -> int:
    from . import live
    from .diarizer import IncrementalDiarizer, PyannoteDiarizer

    cfg = _load_cfg(args)
    folder = Path(args.folder)
    paths = RecordingPaths(folder)
    dictionary_path = Path(args.dictionary).expanduser() if args.dictionary else None
    _limit_mlx_cache()  # runs next to the call for its whole length
    pid_file = live.pid_path(folder)
    pid_file.write_text(str(os.getpid()))
    try:
        with session_log(paths.session_log):
            event("live_start")
            processor = live.LiveProcessor(
                paths,
                transcriber=_make_transcriber(cfg, dictionary_path),
                diarizer=IncrementalDiarizer(PyannoteDiarizer(repo=cfg.diarizer_repo, hf_token=cfg.hf_token)),
                user_name=cfg.user_name,
                language=cfg.language,
            )
            try:
                finished = live.run_live(processor, paths)
            except BaseException:
                processor.abort()
                raise
            event("live_done", finished=finished)
    finally:
        pid_file.unlink(missing_ok=True)
    return 0 if finished else 1


def _limit_mlx_cache() -> None:
    import mlx.core as mx

    from .live import MLX_CACHE_LIMIT

    mx.set_cache_limit(MLX_CACHE_LIMIT)


def _cmd_stream(args: argparse.Namespace) -> int:
    from . import stream, stream_engine
    from .dictionary import load_dictionary

    cfg = _load_cfg(args)
    folder = Path(args.folder)
    paths = RecordingPaths(folder)
    dictionary_path = Path(args.dictionary).expanduser() if args.dictionary else None
    other = stream.running_pid(folder)
    if other is not None and other != os.getpid():
        # Two streams would both load the model and rewrite stream.json.
        with session_log(paths.session_log):
            event("stream_already_running", pid=other)
        return 0
    paths.stream_pid.write_text(str(os.getpid()))
    try:
        with session_log(paths.session_log):
            event("stream_start")
            system_engine, mic_engine = stream_engine.load_engines(
                cfg.parakeet_repo, load_dictionary(dictionary_path)
            )
            processor = stream.RealtimeProcessor(
                paths, system_engine=system_engine, mic_engine=mic_engine
            )
            finished = stream.run_stream(processor, paths, memory=stream_engine.mlx_memory)
            event("stream_done", finished=finished, peak_mb=stream_engine.mlx_peak_mb())
    finally:
        paths.stream_pid.unlink(missing_ok=True)
    return 0 if finished else 1


def _cmd_next_question(args: argparse.Namespace) -> int:
    """Best next question (#41): the inputs (next_question.build_prompt) on
    stdin, the answer as JSON on stdout — {"questions", "engine"}, or
    {"error"} with exit 1 (EXIT_MODEL_BUSY while a local model is in use)."""
    from contextlib import nullcontext

    from . import llm, next_question, notes, providers

    cfg = _load_cfg(args)
    folder = Path(args.folder)

    def answer(data: dict, code: int) -> int:
        print(json.dumps(data, ensure_ascii=False))
        return code

    try:
        inputs = json.loads(sys.stdin.read())
        # The current meeting decides the model ("Keep on This Mac" keeps it
        # local). A cloud model gets no earlier meeting kept on this Mac; the
        # access log names every meeting whose content is sent.
        others = [Path(cfg.output_dir) / m for m in inputs.get("meetings") or [] if m != folder.name] \
            if getattr(cfg, "output_dir", None) else []
        if llm.choice_for(cfg, next_question.FEATURE, [folder]) not in (providers.LOCAL, providers.PENDING):
            others = [m for m in others if not llm.is_local_only(m)]
            kept = {m.name for m in others}
            inputs["last_time"] = [t for t in inputs.get("last_time") or [] if t.get("id") in kept]
        engine = llm.engine(cfg, next_question.FEATURE, parse=next_question.parse, meetings=[folder, *others])
        with nullcontext() if engine.cloud else _one_model_at_a_time(wait=False):
            out = next_question.ask(inputs, engine.run)
    except ModelBusy:
        return answer({"error": "The language model is busy; try again in a minute."}, EXIT_MODEL_BUSY)
    except next_question.NothingYet as exc:
        return answer({"error": str(exc)}, 1)
    except (notes.NotesError, ValueError) as exc:
        return answer({"error": str(exc)}, 1)
    return answer({**out, "engine": engine.label}, 0)


def _save_segments(path: Path, segments) -> None:
    """Whole or not at all: `process` skips a track whose segments file
    exists, so a kill while writing must not leave half of one (#49)."""
    from .live import _write_atomic

    _write_atomic(path, json.dumps([s.to_dict() for s in segments], indent=2))


def _process(
    cfg: Config, folder: Path, paths: RecordingPaths, dictionary_path: Path | None, *, notes: bool = True
) -> int:
    # Crash recovery: if `record` was killed before stop() finalized the WAVs,
    # mic_raw.wav.part / system.wav.part may be on disk instead of the final
    # files. The streaming writer leaves them with a header reflecting actual
    # bytes written, so they're playable as-is — just need to rename.
    _promote_part_files(paths)
    _fold_audio_problems(paths)
    # A recording continued after a Palaver restart: one meeting from here on.
    from .continuation import join_parts, recover_head

    paths = recover_head(paths)
    folder = paths.folder
    join_parts(paths)

    if not paths.meta.exists():
        # Same crash scenario: meta.json is written by Recorder.stop() so a
        # SIGKILL leaves it missing. Reconstruct from the folder name (which
        # is the recording start time) and the WAV duration.
        if _synthesize_meta_from_audio(folder, paths):
            print(
                f"warning: {paths.meta.name} was missing — reconstructed from "
                f"folder name and WAV duration. Likely a crashed recording."
            )
        else:
            print(
                f"error: {paths.meta} not found. This folder was not closed cleanly "
                f"by `record` (likely killed mid-recording) and no audio was found "
                f"to reconstruct session timestamps from.",
            )
            return 2

    if not paths.mic_wav.exists():
        print("Running AEC (mic_raw.wav + system.wav → mic.wav)…")
        from .aec import aec_process
        if not paths.mic_raw_wav.exists():
            print(
                f"error: {paths.mic_raw_wav.name} not found. "
                f"This recording was made before V2 and has no pre-AEC mic track."
            )
            return 2
        if not paths.system_wav.exists():
            print(f"error: {paths.system_wav.name} not found — capture was broken.")
            return 2
        with stage("aec"):
            aec_process(
                mic_raw_path=paths.mic_raw_wav,
                system_path=paths.system_wav,
                out_path=paths.mic_wav,
            )
    else:
        print("Skipping AEC (mic.wav already present)")
    # A live worker stopped or killed during the call leaves its own,
    # unfinished mic.wav; the one above is final.
    Path(str(paths.mic_wav) + ".part").unlink(missing_ok=True)

    from .cleanup import (
        MIC_MIN_PEAK_DBFS,
        SYSTEM_MIN_PEAK_DBFS,
        drop_bleed_duplicates,
        drop_echo,
        drop_silent_segments,
    )
    from .diarizer import PyannoteDiarizer
    from .merger import merge
    from .models import Segment, SpeakerTurn
    from .render import render_markdown

    transcriber = _make_transcriber(cfg, dictionary_path)
    diarizer = PyannoteDiarizer(repo=cfg.diarizer_repo, hf_token=cfg.hf_token)

    # System track first: with language="auto" its detected language is
    # reused for the mic. Whisper detects from the first 30 s, which on the
    # AEC'd mic is often near-silence and yields a wrong language.
    # It goes to the cloud service chosen for transcription, if any (#54).
    from . import transcription
    from .dictionary import load_dictionary

    transcription.sweep_pending(folder.parent)  # what a service could not delete before
    from .transcriber import holds_audio

    # The tap can deliver nothing for a whole call, or nothing played: a
    # valid recording, transcribed from the mic alone.
    system_empty = not holds_audio(paths.system_wav)
    if system_empty:
        print("System track holds no audio; transcribing the microphone only")
        event("system_track_empty")

    def transcribe_system_here():
        if system_empty:
            return [], None
        print("Transcribing system track…")
        with stage("transcribe", track="system") as info:
            segments = transcriber.transcribe(paths.system_wav)
            info.update(segments=len(segments), language=transcriber.last_language)
        return segments, transcriber.last_language

    if transcription.cloud_choice(cfg, folder) and transcription.wants_cloud(paths):
        _attach_calendar(cfg, paths)  # the invitees' names are keyterms
    if transcription.system_track(cfg, paths, local=transcribe_system_here,
                                  dictionary=load_dictionary(dictionary_path)) is None:
        print("Skipping system transcription (already done)")

    if not paths.mic_segments.exists():
        mic_language = None
        if cfg.language == "auto" and paths.language.exists():
            mic_language = paths.language.read_text().strip() or None
        print(f"Transcribing mic track{f' ({mic_language})' if mic_language else ''}…")
        with stage("transcribe", track="mic", language=mic_language) as info:
            mic_segs = transcriber.transcribe(paths.mic_wav, language=mic_language)
            info.update(segments=len(mic_segs))
        for s in mic_segs:
            s.speaker = cfg.user_name
        _save_segments(paths.mic_segments, mic_segs)
    else:
        print("Skipping mic transcription (already done)")

    # Embeddings feed voice recognition; recordings diarized before they were
    # kept are diarized again (pyannote is deterministic: same turns).
    if system_empty:
        paths.speaker_embeddings.write_text("{}")
        paths.system_turns.write_text("[]")
    elif not paths.system_turns.exists() or not paths.speaker_embeddings.exists():
        print("Diarizing system track…")
        with stage("diarize") as info:
            turns = diarizer.diarize(paths.system_wav)
            info.update(turns=len(turns), speakers=len({t.speaker for t in turns}))
        paths.speaker_embeddings.write_text(json.dumps(diarizer.last_embeddings))
        paths.system_turns.write_text(
            json.dumps([t.to_dict() for t in turns], indent=2)
        )
    else:
        print("Skipping diarization (already done)")

    print("Merging…")
    mic_segs = [Segment.from_dict(d) for d in json.loads(paths.mic_segments.read_text())]
    sys_segs = [Segment.from_dict(d) for d in json.loads(paths.system_segments.read_text())]
    turns = [SpeakerTurn.from_dict(d) for d in json.loads(paths.system_turns.read_text())]

    mic_segs = [s for s in mic_segs if s.text.strip()]
    sys_segs = [s for s in sys_segs if s.text.strip()]
    n_mic, n_sys = len(mic_segs), len(sys_segs)
    mic_segs = drop_silent_segments(mic_segs, paths.mic_wav, MIC_MIN_PEAK_DBFS)
    sys_segs = drop_silent_segments(sys_segs, paths.system_wav, SYSTEM_MIN_PEAK_DBFS)
    n_silent_mic = n_mic - len(mic_segs)
    mic_segs = drop_bleed_duplicates(mic_segs, sys_segs)
    mic_segs = drop_echo(mic_segs, sys_segs, paths.mic_wav, paths.mic_raw_wav)
    print(
        f"Dropped {n_silent_mic + n_sys - len(sys_segs)} segments over silence "
        f"(likely hallucinations) and {n_mic - n_silent_mic - len(mic_segs)} mic "
        f"segments that were remote speech heard through the speakers."
    )

    from . import calendar_events
    from .speakers import (
        adopt_live_names,
        apply_speaker_names,
        follow_merges,
        load_merges,
        load_recognized_names,
        load_speaker_names,
        talk_seconds,
    )
    from .people import rejected_voices
    from .voices import VoiceBank, recognize

    meeting_event = _attach_calendar(cfg, paths)
    if meeting_event is not None:
        print(f"Calendar: {meeting_event.title} ({len(meeting_event.attendees)} invited)")
    from . import shared_mic

    # The hints that one microphone was shared (#56), to calibrate them later:
    # a line in the log, never a reason for the transcript to fail.
    try:
        event("shared_mic_signals", **shared_mic.signals(paths, meeting_event, user_name=cfg.user_name),
              marked=shared_mic.meeting_marked(paths))
    except Exception as exc:
        print(f"warning: the shared-microphone signals could not be read: {exc}")
        event("shared_mic_signals_failed", error=str(exc))
    shared = shared_mic.shared_labels(paths)  # several people: no one to recognize
    bank = VoiceBank()
    recognized = recognize(
        {label: v for label, v in json.loads(paths.speaker_embeddings.read_text()).items() if label not in shared},
        talk_seconds(turns),
        bank,
        invited=calendar_events.invited_names(paths, list(bank.names()), user_name=cfg.user_name),
        rejected=rejected_voices(paths.folder.parent),  # "Not Tom", here and for voices like it (#48)
    )
    paths.speakers_auto.write_text(json.dumps(
        {label: {"name": name, "similarity": round(sim, 3)} for label, (name, sim) in recognized.items()},
        indent=2,
        ensure_ascii=False,
    ))
    for label, (name, sim) in recognized.items():
        print(f"Recognized {label} as {name} (voice similarity {sim:.2f})")
    for label, name in adopt_live_names(paths).items():
        print(f"Named {label} {name} (named while recording)")
    names = {label: name for label, (name, _) in load_recognized_names(paths).items()}  # without rejected names
    names.update(load_speaker_names(paths))
    names = follow_merges(names, load_merges(paths))
    names = {label: name for label, name in names.items() if label not in shared}
    names.update(shared_mic.display(paths))
    utterances = apply_speaker_names(merge(mic_segs, sys_segs, turns), names)
    event(
        "merge_done",
        utterances=len(utterances),
        dropped_silent=n_silent_mic + n_sys - len(sys_segs),
        dropped_bleed_duplicates=n_mic - n_silent_mic - len(mic_segs),
    )
    paths.transcript_json.write_text(
        json.dumps([u.to_dict() for u in utterances], indent=2)
    )
    from . import inference

    # Names that follow from the calendar and other meetings, here and in
    # earlier meetings this one tells something about.
    if inference.refresh(paths.folder.parent, user_name=cfg.user_name, bank=bank):
        for label, i in inference.load(paths).items():
            print(f"Inferred {label} = {i['name']}: {i['why']}")
        from .models import Utterance

        utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]

    meta = json.loads(paths.meta.read_text())
    session_start = datetime.fromisoformat(meta["start_time"])
    duration = float(meta["duration_seconds"])

    from .speakers import without_ignored

    paths.transcript_md.write_text(
        render_markdown(shared_mic.shown(paths, without_ignored(paths, utterances)), session_start, duration,
                        meta.get("gaps"))
    )
    print(f"Wrote {paths.transcript_md}")
    if notes and cfg.notes_enabled:
        _write_notes(cfg, paths, utterances, session_start)
    return 0


def _attach_calendar(cfg: Config, paths: RecordingPaths):
    """The recording's calendar event: stored, or looked up once in the macOS
    calendar. Never fails processing — no calendar access means no event."""
    from . import calendar_events

    if paths.calendar.exists() or not getattr(cfg, "calendar_enabled", False):
        return calendar_events.load(paths)
    try:
        from .calendar_eventkit import events_between, has_access

        if not has_access():
            return None
        start, end = calendar_events.recording_span(paths)
        with stage("calendar"):
            return calendar_events.attach(paths, events_between, start, end)
    except Exception as exc:  # a calendar problem must not cost the transcript
        print(f"warning: calendar lookup failed: {exc}")
        event("calendar_failed", error=str(exc))
        return None


# One language model at a time across processes: the daemon's `palaver notes`,
# the window's Write notes and Sort with the model each load a large local
# model. A second run waits for the first.
NOTES_LOCK = Path.home() / "Library" / "Application Support" / "palaver" / "notes.lock"


# Exit code of a run that would not wait for the model (`projects --no-wait`).
EXIT_MODEL_BUSY = 75


class ModelBusy(Exception):
    pass


def notes_lock_free() -> bool:
    """Whether no process is using the language model right now."""
    import fcntl

    NOTES_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(NOTES_LOCK, "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        fcntl.flock(f, fcntl.LOCK_UN)
    return True


@contextmanager
def _one_model_at_a_time(*, wait: bool = True):
    import fcntl

    NOTES_LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(NOTES_LOCK, "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if not wait:
                raise ModelBusy from None
            print("Waiting for the language model: another run is using it…")
            fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _write_notes(
    cfg: Config, paths: RecordingPaths, utterances, session_start: datetime, *, force: bool = False
) -> bool:
    """notes.json for the transcript, unless it is up to date. A failure only
    warns: the transcript is there either way, and notes can be retried."""
    from . import notes
    from .speakers import without_ignored

    utterances = without_ignored(paths, utterances)  # voices removed as noise say nothing
    if not force and not notes.is_stale(paths, utterances):
        print("Notes are up to date")
        return True
    with _one_model_at_a_time():
        if not force and not notes.is_stale(paths, utterances):  # written by the run this one waited for
            print("Notes are up to date")
            return True
        return _write_notes_now(cfg, paths, utterances, session_start)


def _write_notes_now(cfg: Config, paths: RecordingPaths, utterances, session_start: datetime) -> bool:
    import subprocess

    from . import llm, notes

    try:
        engine = llm.engine(cfg, "notes", meetings=[paths.folder])
    except llm.Unavailable as exc:  # never another model instead: the user chose this one
        print(f"Skipping notes: {exc}")
        event("notes_skipped", reason=str(exc))
        return False
    print(f"Writing notes with {engine.label}…")
    from . import usage

    started = time.monotonic()

    def counted(ok: bool) -> bool:
        usage.record("notes", engine=engine.choice, model=engine.model, seconds=time.monotonic() - started, ok=ok)
        return ok

    try:
        with stage("notes", engine=engine.choice, model=engine.model):
            from . import calendar_events, my_notes, shared_mic, titles

            # The user's own notes (#44): images not read yet (the app quit first)
            # are read now. A model gets the text read from an image, never the image.
            my_notes.read_all(paths.folder)
            result = notes.generate(
                utterances, user_name=cfg.user_name, meeting_start=session_start, run=engine.run,
                event=calendar_events.load(paths), my_notes=my_notes.prompt_text(paths.folder),
                shared=shared_mic.display(paths), mic=shared_mic.mic_display(paths),
                title=titles.load(paths) or "",
            )
    except (notes.NotesError, subprocess.TimeoutExpired, OSError) as exc:
        print(f"warning: notes failed: {exc}")
        event("notes_failed", error=str(exc))
        return counted(False)
    notes.save(paths, result)
    print(f"Wrote {paths.notes} — {result['title']}")
    counted(True)
    _sort_into_projects(cfg, paths)
    return True


def _private_meetings(output_dir: Path) -> set[str]:
    """Meetings kept on this Mac: never in what a cloud model is sent."""
    from .llm import local_only_meetings

    return local_only_meetings(output_dir)


def _sort_into_projects(cfg: Config, paths: RecordingPaths) -> None:
    """Put a meeting with fresh notes into its projects: by rules when it
    resembles a project's meetings, else as the model suggests. Never fails
    the notes."""
    from . import projects

    meeting, output_dir = paths.folder.name, paths.folder.parent
    store = projects.ProjectStore()
    try:
        added = projects.assign_by_rules(output_dir, store, user_name=cfg.user_name, meetings=[meeting])
        if not added and not store.of_meeting(meeting):
            from . import llm

            try:
                engine = llm.engine(cfg, "projects", parse=projects.parse_answer, meetings=[paths.folder])
            except llm.Unavailable as exc:
                print(f"Not sorting into projects with a model: {exc}")
                engine = None
            if engine is not None:
                with stage("projects", engine=engine.choice, model=engine.model):
                    added = projects.suggest_with_model(
                        output_dir, store, engine.run, user_name=cfg.user_name, meetings=[meeting],
                        private=_private_meetings(output_dir) if engine.cloud else ())
        store.save()
    except Exception as exc:  # projects are extra; the notes are written
        print(f"warning: sorting into projects failed: {exc}")
        event("projects_failed", error=str(exc))
        return
    for _, pid in added:
        print(f"Project: {store.projects()[pid]['name']}")


def write_notes_for(cfg: Config, paths: RecordingPaths, *, force: bool = False) -> bool:
    """Notes for an already processed recording (the `notes` command, the app)."""
    from .models import Utterance

    utterances = [Utterance.from_dict(d) for d in json.loads(paths.transcript_json.read_text())]
    session_start = datetime.fromisoformat(json.loads(paths.meta.read_text())["start_time"])
    with session_log(paths.session_log):
        return _write_notes(cfg, paths, utterances, session_start, force=force)


def _cmd_notes(args: argparse.Namespace) -> int:
    cfg = _load_cfg(args)
    paths = RecordingPaths(Path(args.folder))
    if not paths.transcript_json.exists():
        print(f"error: {paths.folder} has no transcript yet — run `process` first.")
        return 2
    return 0 if write_notes_for(cfg, paths, force=args.force) else 1


def _cmd_index(args: argparse.Namespace) -> int:
    """Build the search-by-meaning index of meetings without a current one
    (#46); the daemon runs this in the background. Downloads the embedding
    model (~470 MB) the first time."""
    from . import semantic

    cfg = _load_cfg(args)
    if not semantic.enabled():
        print("Search by meaning is switched off in the settings.")
        return 0
    only = [RecordingPaths(Path(f)) for f in args.folders] or None
    done = semantic.index_stale(cfg.output_dir, only=only)
    print(f"Indexed {done} meeting{'s' if done != 1 else ''} for search by meaning.")
    return 0


def _cmd_projects(args: argparse.Namespace) -> int:
    """Sort meetings into projects (all without one, or one folder), or
    write a project's description, with the notes model."""
    cfg = _load_cfg(args)
    try:
        with _one_model_at_a_time(wait=not args.no_wait):  # and the store is read once the model is free
            return _projects_with_model(cfg, args)
    except ModelBusy:
        print("the language model is busy")
        return EXIT_MODEL_BUSY


def _projects_with_model(cfg: Config, args: argparse.Namespace) -> int:
    from . import llm, projects

    store = projects.ProjectStore()
    if args.action == "describe":
        if args.target and args.target not in store.projects():
            print(f"error: no project {args.target}")
            return 2
        # One project, or every project without a description.
        targets = [args.target] if args.target else [pid for pid, p in store.projects().items() if not p["description"]]
        try:
            engine = llm.engine(cfg, "projects", parse=_parse_description)
        except llm.Unavailable as exc:
            print(f"error: {exc}")
            return 1
        private = _private_meetings(cfg.output_dir) if engine.cloud else set()
        for pid in targets:
            text = projects.describe_with_model(cfg.output_dir, store, pid, engine.run, user_name=cfg.user_name,
                                                private=private)
            store.save()
            print(f"{store.projects().get(pid, {}).get('name', pid)}: {text}")
        return 0
    meetings = [Path(args.target).name] if args.target else None
    added = projects.assign_by_rules(cfg.output_dir, store, user_name=cfg.user_name, meetings=meetings)
    folders = [cfg.output_dir / m for m in meetings or []]
    try:
        engine = llm.engine(cfg, "projects", parse=projects.parse_answer, meetings=folders)
    except llm.Unavailable as exc:
        engine, unavailable = None, exc
    if engine is not None:
        print(f"Asking {engine.label}…")
        added += projects.suggest_with_model(cfg.output_dir, store, engine.run, user_name=cfg.user_name,
                                             meetings=meetings,
                                             private=_private_meetings(cfg.output_dir) if engine.cloud else ())
    store.save()
    for meeting, pid in added:
        print(f"{meeting}: {store.projects()[pid]['name']}")
    if engine is None:
        print(f"error: {unavailable}")
        return 1
    return 0


def _cmd_bench(args: argparse.Namespace) -> int:
    """Compare our transcripts with another transcriber's (#36)."""
    from . import bench

    cfg = _load_cfg(args)
    bench.run(Path(args.dir).expanduser(), cfg.output_dir)
    print(f"Wrote {Path(args.dir).expanduser() / 'report.md'}")
    return 0


def _cmd_bench_live(args: argparse.Namespace) -> int:
    """Replay recorded meetings through the live stream; numbers only (#42)."""
    from . import stream_bench
    from .daemon import forwarded_cli_options
    from .dictionary import load_dictionary
    from .transcriber import ParakeetMlxTranscriber

    cfg = _load_cfg(args)
    dictionary_path = Path(args.dictionary).expanduser() if args.dictionary else None

    def terminated(signum, frame):
        raise SystemExit(128 + signum)

    # A memory guard's SIGTERM unwinds the bench like Ctrl-C, so the bench
    # kills `live` and `stream`; they run in their own sessions.
    previous = signal.signal(signal.SIGTERM, terminated)
    try:
        report = stream_bench.run(
            [Path(f).expanduser() for f in args.folder],
            Path(args.out).expanduser(),
            speed=args.speed,
            user_name=cfg.user_name,
            cli_options=forwarded_cli_options(args),
            transcriber=ParakeetMlxTranscriber(cfg.parakeet_repo, load_dictionary(dictionary_path)),
        )
    finally:
        signal.signal(signal.SIGTERM, previous)
    print(f"Wrote {report}")
    return 0


def _cmd_mcp(args: argparse.Namespace) -> int:
    """Serve the meetings to MCP clients over stdio, or add this server to
    Claude Code (--install) or Claude Desktop (--install --desktop)."""
    from . import mcp_server

    if args.install and args.desktop:
        from . import mcp_access

        config = str(Path(args.config).expanduser().resolve()) if args.config else None
        try:
            mcp_access.install_desktop(sys.executable, ["--config", config] if config else [])
        except RuntimeError as exc:
            print(f"Not added to Claude Desktop: {exc}", file=sys.stderr)
            return 1
        print(f"Added \"meetings\" to {mcp_access.DESKTOP_CONFIG} (the previous file is kept as .bak).\n"
              "Quit and reopen Claude Desktop to use it.")
        return 0
    if args.install:
        import subprocess

        cmd = mcp_server.install_command(sys.executable, args.config)
        print(" ".join(cmd))
        return subprocess.run(cmd).returncode
    cfg = _load_cfg(args)
    mcp_server.serve(cfg.output_dir, cfg.user_name)
    return 0


def _parse_description(text: str) -> dict:
    start, end = text.find("{"), text.rfind("}")
    out = json.loads(text[start : end + 1]) if 0 <= start < end else None
    if not isinstance(out, dict) or not isinstance(out.get("description"), str):
        raise ValueError("no description")
    return out


def _cmd_sync(args: argparse.Namespace) -> int:
    cfg = _load_cfg(args)
    folder = Path(args.folder)
    paths = RecordingPaths(folder)

    from .models import Utterance
    from .notion_client import NotionClient, utterances_to_blocks
    from .readable import readable
    from .render import build_meeting_title

    utterances_raw = json.loads(paths.transcript_json.read_text())
    utterances = readable([Utterance.from_dict(d) for d in utterances_raw])

    meta = json.loads(paths.meta.read_text())
    session_start = datetime.fromisoformat(meta["start_time"])
    duration_seconds = float(meta["duration_seconds"])

    client = NotionClient(token=cfg.notion_token)
    blocks = utterances_to_blocks(utterances, session_start)
    n_speakers = len({u.speaker for u in utterances})
    title = build_meeting_title(session_start, duration_seconds, n_speakers)

    print(f"Uploading to Notion ({len(blocks)} blocks)…")
    with session_log(paths.session_log), stage("notion_upload", blocks=len(blocks)) as info:
        if cfg.notion_mode == "database":
            url = client.create_database_page(
                database_id=cfg.notion_database_id,
                title=title,
                blocks=blocks,
                start=session_start,
                duration_minutes=duration_seconds / 60,
                n_speakers=n_speakers,
                source="Teams" if meta.get("trigger") == "teams" else "Manual recording",
            )
        else:
            url = client.create_page(
                parent_page_id=cfg.notion_parent_page_id,
                title=title,
                blocks=blocks,
            )
        info.update(page_url=url)
    paths.notion_info.write_text(
        json.dumps({"page_url": url, "uploaded_at": datetime.now().isoformat()}, indent=2)
    )
    print(f"✓ {url}")
    notify.notify("Uploaded to Notion", url)
    return 0


def _cmd_run(args: argparse.Namespace) -> int:
    rc = _cmd_process(args)
    if rc != 0:
        return rc
    return _cmd_sync(args)


def _cmd_list(args: argparse.Namespace) -> int:
    cfg = _load_cfg(args)
    if not cfg.output_dir.exists():
        print("(no recordings yet)")
        return 0
    rows = []
    for folder in sorted(cfg.output_dir.iterdir()):
        if not folder.is_dir():
            continue
        p = RecordingPaths(folder)
        status = _status(p)
        rows.append((folder.name, status))
    for name, status in rows:
        print(f"{name}  {status}")
    return 0


def _cmd_rename(args: argparse.Namespace) -> int:
    from .speakers import play_clip, run_wizard

    paths = RecordingPaths(Path(args.folder))
    if not paths.transcript_json.exists() or not paths.system_turns.exists():
        print(f"error: {paths.folder} has no transcript yet — run `process` first.")
        return 2
    names = run_wizard(paths, play=None if args.no_audio else play_clip)
    print(f"\nSaved {paths.speakers.name}; rewrote {paths.transcript_md.name}.")
    if names and paths.notion_info.exists():
        print("Already uploaded: `sync` creates a new Notion page with the names.")
    return 0


def _ask(question: str) -> bool:
    """Yes or no on the terminal; no without one."""
    if not sys.stdin.isatty():
        return False
    return input(f"{question} [y/N] ").strip().lower() in ("y", "yes", "j", "ja")


def _cmd_export(args: argparse.Namespace) -> int:
    from . import exchange

    cfg = _load_cfg(args)
    folder = Path(args.meeting) if Path(args.meeting).is_dir() else cfg.output_dir / args.meeting
    paths = RecordingPaths(folder)
    if not paths.meta.exists():
        print(f"error: no meeting {args.meeting} in {cfg.output_dir}")
        return 2
    dest = Path(args.output) if args.output else exchange.free_name(Path.cwd(), exchange.file_name(paths))
    if dest.suffix != exchange.SUFFIX:
        dest = dest.with_name(dest.name + exchange.SUFFIX)
    options = dict(user_name=cfg.user_name, notes=args.notes, voices=args.voices, audio=args.audio,
                   projects=exchange.confirmed_projects(folder.name))
    try:
        try:
            exchange.export_meeting(paths, dest, confirm_local=args.yes, **options)
        except exchange.KeptOnThisMac:
            if not _ask("This meeting is kept on this Mac. Export it anyway?"):
                print("Not exported: the meeting is kept on this Mac (--yes exports it anyway).")
                return 1
            exchange.export_meeting(paths, dest, confirm_local=True, **options)
    except exchange.NotReady as exc:
        print(f"error: {exc}")
        return 2
    parts = ["transcript and names"] + [what for what, on in (("notes", args.notes), ("voices", args.voices),
                                                              ("audio", args.audio)) if on]
    print(f"Exported {', '.join(parts)} to {dest}")
    return 0


def _cmd_import(args: argparse.Namespace) -> int:
    from . import exchange

    cfg = _load_cfg(args)
    try:
        package = exchange.read_package(Path(args.file))
    except exchange.Rejected as exc:
        print(f"Not imported: {exc}")
        return 1
    separate = args.separate
    match = exchange.find_match(cfg.output_dir, package)
    if match is not None and not separate:
        mine = "your own recording" if match.own else "an earlier import"
        print(f"This meeting is here already: {match.id} ({mine}).")
        if not _ask("Import it as a separate meeting beside it?"):
            print("Kept yours; nothing imported (--separate imports it beside it).")
            return 1
        separate = True
    calendar = None
    if getattr(cfg, "calendar_enabled", False):
        try:
            from .calendar_eventkit import events_between, has_access

            calendar = events_between if has_access() else None
        except Exception:  # no calendar: the event in the file is linked
            calendar = None
    cfg.output_dir.mkdir(parents=True, exist_ok=True)
    result = exchange.import_package(cfg.output_dir, Path(args.file), user_name=cfg.user_name, separate=separate,
                                     calendar=calendar, package=package,
                                     after=lambda mid: exchange.settle(cfg.output_dir, mid, user_name=cfg.user_name))
    print(f"Imported {result.id} from {result.sender}"
          + (f", beside {result.matched.id}" if result.matched else "") + ".")
    for warning in result.warnings:
        print(f"  {warning}")
    for label, name in sorted(result.names.items()):
        print(f"  {label}: {name} (named by {result.sender}; confirm it in the window)")
    if result.voices:
        names = ", ".join(v["name"] for v in result.voices)
        paths = RecordingPaths(cfg.output_dir / result.id)
        if _ask(f"It came with the voices of {names}. Add them to your voice bank?"):
            learned = exchange.decide_voices(paths, True, user_name=cfg.user_name)
            print(f"Added the voices of {', '.join(learned) or 'nobody'} to your voice bank.")
        else:
            print("Voices not added; the window asks again on the meeting.")
    return 0


def _cmd_voices(args: argparse.Namespace) -> int:
    from .voices import VoiceBank

    bank = VoiceBank()
    if args.action == "forget":
        if not args.name:
            print("usage: palaver voices forget <name>")
            return 2
        if not bank.forget(args.name):
            print(f"No stored voice for {args.name}.")
            return 1
        print(f"Forgot {args.name}'s voice.")
        return 0
    people = bank.names()
    if not people:
        print("No voices stored. Name speakers with `rename` to add them.")
    for name, samples in sorted(people.items()):
        print(f"{name}  ({samples} sample{'s' if samples != 1 else ''})")
    return 0


def _cmd_prune(args: argparse.Namespace) -> int:
    from .prune import prune

    cfg = _load_cfg(args)
    prune(
        cfg.output_dir,
        cfg.retention_days,
        dry_run=args.dry_run,
        include_unsynced=args.include_unsynced,
    )
    return 0


_LIVE_PART_SECONDS = 60.0


def _status(p: RecordingPaths, now: float | None = None) -> str:
    if p.notion_info.exists():
        return "synced"
    if p.transcript_json.exists():
        return "processed"
    if (p.mic_wav.exists() or p.mic_raw_wav.exists()) and p.system_wav.exists():
        return "recorded"
    parts = [Path(str(f) + ".part") for f in (p.mic_raw_wav, p.system_wav)]
    mtimes = [f.stat().st_mtime for f in parts if f.exists()]
    if mtimes:
        # The writer appends every few hundred ms; a .part file that is
        # still growing belongs to a running recording, not a crashed one.
        if (now if now is not None else time.time()) - max(mtimes) < _LIVE_PART_SECONDS:
            return "recording"
        return "crashed (run `process` to recover)"
    return "incomplete"


def _promote_part_files(paths: RecordingPaths) -> None:
    """Rename `<file>.part` → `<file>` for any captured tracks.

    The streaming writer leaves `.part` on disk if the recording process
    crashed before stop() could call finalize_to(). The file already has a
    valid WAV header reflecting whatever was actually written, so promotion
    is a pure rename — no audio reconstruction needed.

    No-op if the final file already exists (clean stop wrote it directly).
    """
    for final in (paths.mic_raw_wav, paths.system_wav):
        part = Path(str(final) + ".part")
        if part.exists() and not final.exists():
            part.rename(final)


def _synthesize_meta_from_audio(folder: Path, paths: RecordingPaths) -> bool:
    """Reconstruct meta.json from folder name + WAV duration when crash
    recovery left it missing. Returns True on success.

    Folder name is `YYYY-MM-DDTHH-MM-SS` (set by `new_recording_folder`).
    Duration comes from whichever WAV exists.
    """
    audio = paths.mic_raw_wav if paths.mic_raw_wav.exists() else paths.system_wav
    if not audio.exists():
        return False

    try:
        info = sf.info(str(audio))
        duration = info.frames / info.samplerate
    except Exception:
        return False

    try:
        start = datetime.strptime(folder.name, "%Y-%m-%dT%H-%M-%S").astimezone()
    except ValueError:
        return False

    end = start + timedelta(seconds=duration)
    meta = {"start_time": start.isoformat(), "end_time": end.isoformat(), "duration_seconds": duration}
    paths.meta.write_text(json.dumps(meta, indent=2))
    _fold_audio_problems(paths)
    return True


def _fold_audio_problems(paths: RecordingPaths) -> None:
    """The audio problems the recorder kept beside the audio as they
    happened (issue #50), into meta.json, if a crash left them there: one
    still open lasted to the end. meta.json's own, written by a clean stop,
    win. The file is gone afterwards."""
    if not paths.audio_problems.exists() or not paths.meta.exists():
        return
    try:
        kept = json.loads(paths.audio_problems.read_text())
        meta = json.loads(paths.meta.read_text())
    except (OSError, ValueError):
        return
    if not meta.get("audio_problems"):
        duration = float(meta.get("duration_seconds") or 0.0)
        problems = [{**p, "end": duration if p.get("end") is None else p["end"]}
                    for p in kept if isinstance(p, dict) and "start" in p] if isinstance(kept, list) else []
        if problems:
            meta["audio_problems"] = problems
            tmp = paths.meta.with_name(paths.meta.name + ".tmp")
            tmp.write_text(json.dumps(meta, indent=2))
            tmp.replace(paths.meta)
    paths.audio_problems.unlink(missing_ok=True)


def _load_cfg(args: argparse.Namespace) -> Config:
    path = Path(args.config) if args.config else default_config_path()
    return load_config(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="palaver")
    parser.add_argument(
        "--config",
        help="Path to config.toml (defaults to ~/.config/palaver/config.toml)",
    )
    parser.add_argument(
        "--no-notify",
        action="store_true",
        help="Don't show macOS notifications when a transcript is ready or a step fails",
    )
    parser.add_argument(
        "--dictionary",
        help="Path to a dictionary.toml for this run, e.g. a meeting-type "
        "vocabulary (defaults to ~/.config/palaver/dictionary.toml)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_rec = sub.add_parser("record", help="Record a meeting (Ctrl+C to stop)")
    p_rec.add_argument(
        "--run",
        action="store_true",
        help="After stopping, immediately process+sync",
    )
    p_rec.add_argument(
        "--quiet",
        action="store_true",
        help="No live level meter (it is also off when stdout is not a terminal)",
    )
    p_rec.set_defaults(func=_cmd_record)

    p_proc = sub.add_parser(
        "process", help="Transcribe + diarize + merge an existing folder"
    )
    p_proc.add_argument("folder")
    p_proc.add_argument("--no-notes", action="store_true",
                        help="Leave the notes for later (the app writes them when no call is recorded)")
    p_proc.set_defaults(func=_cmd_process)

    p_live = sub.add_parser(
        "live", help="Process a recording while it is being made (the daemon starts this)"
    )
    p_live.add_argument("folder")
    p_live.set_defaults(func=_cmd_live)

    p_stream = sub.add_parser(
        "stream", help="Transcribe a recording in real time (the daemon starts this)"
    )
    p_stream.add_argument("folder")
    p_stream.set_defaults(func=_cmd_stream)

    p_notes = sub.add_parser(
        "notes", help="Write the meeting notes (summary, next steps, decisions) with Claude"
    )
    p_notes.add_argument("folder")
    p_notes.add_argument("--force", action="store_true", help="Rewrite even if up to date")
    p_notes.set_defaults(func=_cmd_notes)

    p_next = sub.add_parser("next-question", help="Suggest the best next question in a meeting (inputs on stdin)")
    p_next.add_argument("folder")
    p_next.set_defaults(func=_cmd_next_question)

    p_index = sub.add_parser("index", help="Index meetings for search by meaning (runs in the background)")
    p_index.add_argument("folders", nargs="*", help="Only these recordings (default: all without a current index)")
    p_index.set_defaults(func=_cmd_index)

    p_projects = sub.add_parser(
        "projects", help="Sort meetings into projects, or describe a project, with the notes model"
    )
    p_projects.add_argument("action", choices=["suggest", "describe"])
    p_projects.add_argument("target", nargs="?", help="suggest: one recording folder (default: all in no "
                            "project); describe: a project id (default: all without a description)")
    p_projects.add_argument("--no-wait", action="store_true",
                            help=f"Exit {EXIT_MODEL_BUSY} at once when another run is using the model")
    p_projects.set_defaults(func=_cmd_projects)

    p_bench = sub.add_parser("bench", help="Compare transcripts with another transcriber's (DIR/notion/<id>.txt)")
    p_bench.add_argument("dir")
    p_bench.set_defaults(func=_cmd_bench)

    p_bench_live = sub.add_parser(
        "bench-live", help="Replay recorded meetings through the live stream and measure it (numbers only)"
    )
    p_bench_live.add_argument("folder", nargs="+")
    p_bench_live.add_argument("--speed", type=float, default=1.0, help="Times real time (latency only at 1)")
    p_bench_live.add_argument("--out", required=True, help="Where the replays and report.md go")
    p_bench_live.set_defaults(func=_cmd_bench_live)

    p_mcp = sub.add_parser("mcp", help="Serve meetings, notes, projects and people to Claude (MCP, stdio)")
    p_mcp.add_argument("--install", action="store_true", help="Add this server to Claude Code (claude mcp add)")
    p_mcp.add_argument("--desktop", action="store_true",
                       help="With --install: add it to Claude Desktop (claude_desktop_config.json) instead")
    p_mcp.set_defaults(func=_cmd_mcp)

    p_sync = sub.add_parser("sync", help="Upload transcript to Notion")
    p_sync.add_argument("folder")
    p_sync.set_defaults(func=_cmd_sync)

    p_run = sub.add_parser("run", help="process + sync")
    p_run.add_argument("folder")
    p_run.set_defaults(func=_cmd_run)

    p_list = sub.add_parser("list", help="Show all recording folders with status")
    p_list.set_defaults(func=_cmd_list)

    p_rename = sub.add_parser(
        "rename", help="Name the remote speakers (plays a sample of each)"
    )
    p_rename.add_argument("folder")
    p_rename.add_argument("--no-audio", action="store_true", help="Don't play samples")
    p_rename.set_defaults(func=_cmd_rename)

    p_export = sub.add_parser("export", help="Save a meeting as a .palaver file to send to a colleague")
    p_export.add_argument("meeting", help="the meeting's id (its folder name) or folder")
    p_export.add_argument("--notes", action=argparse.BooleanOptionalAction, default=True,
                          help="Include the notes (default: yes)")
    p_export.add_argument("--voices", action="store_true",
                          help="Include the voices of the people named (biometric data; default: no)")
    p_export.add_argument("--audio", action="store_true", help="Include the audio (default: no)")
    p_export.add_argument("-o", "--output", help="The file to write (default: '<date> <title>.palaver' here)")
    p_export.add_argument("--yes", action="store_true", help="Export a meeting kept on this Mac without asking")
    p_export.set_defaults(func=_cmd_export)

    p_import = sub.add_parser("import", help="Import a meeting from a .palaver file")
    p_import.add_argument("file")
    p_import.add_argument("--separate", action="store_true",
                          help="When the meeting is here already, import it beside it without asking")
    p_import.set_defaults(func=_cmd_import)

    p_daemon = sub.add_parser(
        "daemon",
        help="Record Teams calls automatically (run in a terminal tab), or show status",
    )
    p_daemon.add_argument("action", nargs="?", choices=["run", "status"], default="run")
    p_daemon.set_defaults(func=_cmd_daemon)

    p_doctor = sub.add_parser("doctor", help="Check setup and permissions, say what to fix")
    p_doctor.add_argument("--offline", action="store_true", help="Skip the Notion API check")
    p_doctor.set_defaults(func=_cmd_doctor)

    p_app = sub.add_parser(
        "app", help="Install Palaver.app (menu bar app) in ~/Applications; restart-web: restart only the window's server"
    )
    p_app.add_argument(
        "action",
        nargs="?",
        choices=["install", "uninstall", "autostart", "build-release", "restart-web"],
        default="install",
    )
    p_app.add_argument("state", nargs="?", choices=["on", "off"], help="for autostart")
    p_app.add_argument("--dest", default="dist", help="for build-release (used by CI)")
    p_app.add_argument("--login", action="store_true", help="Start the app at login")
    p_app.add_argument(
        "--store-tokens",
        action="store_true",
        help="Copy NOTION_TOKEN/HF_TOKEN from this shell into the login Keychain",
    )
    p_app.set_defaults(func=_cmd_app)

    p_menubar = sub.add_parser(
        "menubar", help="Menu bar app: auto-records Teams calls, shows status"
    )
    p_menubar.set_defaults(func=_cmd_menubar)

    p_web = sub.add_parser(
        "webapp-serve", help="The Meetings window's server (started by the menu bar app; `app restart-web`)"
    )
    p_web.add_argument("--listen-fd", type=int, help="a listening socket handed over by the app")
    p_web.add_argument("--ready-fd", type=int, help="written to once the server serves")
    p_web.add_argument("--app-socket", help="the app's socket (default: in the app support folder)")
    p_web.add_argument("--port", type=int, default=0, help="without --listen-fd: the port (0: any free one)")
    p_web.set_defaults(func=_cmd_webapp_serve)

    p_voices = sub.add_parser(
        "voices",
        help="List stored voices used for speaker recognition, or forget one",
    )
    p_voices.add_argument("action", nargs="?", choices=["list", "forget"], default="list")
    p_voices.add_argument("name", nargs="?")
    p_voices.set_defaults(func=_cmd_voices)

    p_prune = sub.add_parser(
        "prune",
        help="Delete synced recordings older than [recording].retention_days",
    )
    p_prune.add_argument("--dry-run", action="store_true", help="Only show what would be deleted")
    p_prune.add_argument(
        "--include-unsynced",
        action="store_true",
        help="Also delete old recordings that were never uploaded to Notion",
    )
    p_prune.set_defaults(func=_cmd_prune)

    p_report = sub.add_parser(
        "report", help="Report a problem: one zip on the Desktop with everything to analyse it (#59); "
        "open / usage: read reports, for the maintainer")
    report_sub = p_report.add_subparsers(dest="action", required=True)
    r_create = report_sub.add_parser("create", help="Write the report zip to the Desktop and show it in Finder")
    r_create.add_argument("--meeting", help="The meeting it is about (default: the latest; \"none\": no meeting)")
    r_create.add_argument("--audio", action="store_true", help="Include that meeting's audio (large)")
    r_create.add_argument("-m", "--message", default="", help="What happened")
    r_create.add_argument("--wish", action="store_true", help="A wish, not a bug")
    r_open = report_sub.add_parser("open", help="Unpack a report and summarize it")
    r_open.add_argument("zip")
    r_open.add_argument("--dir", help="Where to unpack it (default: next to the zip)")
    r_usage = report_sub.add_parser("usage", help="Feature use across reports: users and uses per feature")
    r_usage.add_argument("zips", nargs="+")
    p_report.set_defaults(func=_cmd_report)
    return parser


def command_names() -> list[str]:
    """The CLI's commands, for the usage catalog (#59)."""
    sub = next(a for a in build_parser()._actions if isinstance(a, argparse._SubParsersAction))
    return sorted(sub.choices)


def _cmd_report(args: argparse.Namespace) -> int:
    from . import report

    if args.action == "open":
        _, text = report.open_report(Path(args.zip).expanduser(), Path(args.dir).expanduser() if args.dir else None)
        print(text)
        return 0
    if args.action == "usage":
        print(report.usage_table([Path(z).expanduser() for z in args.zips]))
        return 0
    config_path = Path(args.config).expanduser() if args.config else default_config_path()
    output_dir = report.output_dir_for(config_path)
    meeting = None if args.meeting == "none" else (args.meeting or report.latest_meeting(output_dir))
    form = report.Form("wish" if args.wish else "bug", args.message, meeting, args.audio)
    print("Collecting logs, settings and this Mac's setup…", flush=True)
    try:
        result = report.create(form, output_dir=output_dir, config_path=config_path, via="cli")
    except ValueError as exc:
        print(f"error: {exc}")
        return 2
    report.reveal(Path(result["path"]))
    print(f"Saved {result['path']} ({report.size_text(result['size'])}, {result['files']} files"
          f"{', about ' + meeting if meeting else ''}).\nSend it to the maintainer, e.g. in Slack or Mail.")
    return 0


def main(argv: list[str] | None = None) -> int:
    from . import runlog, usage

    args = build_parser().parse_args(argv)
    runlog.install_crash_log(f"palaver {args.cmd}")
    # A command a person typed is a feature used; the app's own (live, process …) is not (#59).
    typed = bool(sys.stdin and sys.stdin.isatty())
    usage.record("cli", args.cmd, by="user" if typed else "app", action=getattr(args, "action", None))
    migrate.move_old_folders()
    notify.set_enabled(not args.no_notify)
    quiet_cmd = args.cmd in ("live", "stream", "list", "prune", "rename", "voices", "daemon", "menubar", "doctor", "app",
                         "webapp-serve", "export", "import")
    try:
        rc = args.func(args)
    except Exception as exc:
        if not quiet_cmd:
            notify.notify(f"palaver {args.cmd} failed", str(exc) or type(exc).__name__)
        raise
    if rc != 0 and not quiet_cmd:
        notify.notify(f"palaver {args.cmd} failed", f"exit code {rc}; see terminal")
    return rc
