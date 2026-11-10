"""`palaver cloud-transcribe <folder>`: the system track of a recording through the transcription service
the user chose (#54), for the Swift pipeline (`palaver-worker process`, which runs this as its child: the
cloud and the Keychain stay Python until phase 4).

It does what `process` does for that track: retry the deletions a service still owes (`sweep_pending`),
then `transcription.system_track` — silence cut, chunks, stitching, the access log, and on a failure this
Mac's speech engine (palaver-engine) with the "Transcribed on this Mac" notification. It writes only what
`system_track` writes in the folder (system_segments.json, transcription.json, language.txt) and its lines
in session.log. The meeting's calendar event (the invitees are keyterms) is attached by the caller first.

Exit codes: 0 done (also when no service is chosen, or the track needs none: nothing is written); 3 the
fallback's speech models are missing; 4 any other error, its reason on the last line of stderr.
"""

from __future__ import annotations

import sys
from pathlib import Path

EXIT_MODELS = 3
EXIT_ERROR = 4


def _reason(exc: BaseException) -> str:
    """One line: an engine error's summary, else the last line of the message, else the type's name."""
    reason = getattr(exc, "reason", None)
    text = str(reason or exc).strip()
    return text.splitlines()[-1] if text else type(exc).__name__


def run(cfg, folder: Path, dictionary_path: Path | None = None, *, engine=None) -> int:
    """``engine``: palaver-engine's client for the fallback (tests pass a fake); one is started when needed."""
    from . import transcription
    from .dictionary import load_dictionary
    from .engine import ModelsMissing
    from .paths import RecordingPaths
    from .session_log import session_log, stage
    from .transcriber import EngineTranscriber, holds_audio

    folder = Path(folder)
    if not folder.is_dir():
        print(f"{folder} is not a recording folder", file=sys.stderr)
        return EXIT_ERROR
    paths = RecordingPaths(folder)
    dictionary = load_dictionary(dictionary_path)
    transcriber = EngineTranscriber(dictionary, engine=engine)

    def local():
        """The fallback on this Mac, as `process` transcribes the system track."""
        if not holds_audio(paths.system_wav):
            return [], None
        print("Transcribing system track…")
        with stage("transcribe", track="system") as info:
            segments = transcriber.transcribe(paths.system_wav)
            info.update(segments=len(segments), language=transcriber.last_language)
        return segments, transcriber.last_language

    try:
        with session_log(paths.session_log):
            transcription.sweep_pending(folder.parent)  # what a service could not delete before
            if transcription.cloud_choice(cfg, folder) is None:
                return 0
            transcription.system_track(cfg, paths, local=local, dictionary=dictionary)
    except ModelsMissing as exc:
        print(_reason(exc), file=sys.stderr)
        return EXIT_MODELS
    except Exception as exc:  # noqa: BLE001 - the caller reads the reason from stderr
        print(_reason(exc), file=sys.stderr)
        return EXIT_ERROR
    finally:
        close = getattr(transcriber._engine, "close", None)
        if engine is None and callable(close):
            close()
    return 0
