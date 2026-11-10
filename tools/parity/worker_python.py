"""``python -m tools.parity.worker_python ARGS``: ``palaver ARGS`` (cli.main) as a parity worker step runs it on the
Python side when the step names an engine (``"engine"``, written to ``$PALAVER_TEST_ENGINE``): palaver-engine is
then ``fake_engine.py`` answering from that file, and the speech models count as downloaded unless it says
``"models_ready": false`` — what palaver-worker's ``FakeEngine`` does on the Swift side. Its ``"cloud"``
(``{"segments": [...], "language", "model", "sent_seconds"}``) is what the chosen transcription service hears
(``transcription._cloud``): no service, no key, no network is ever reached. palaver-worker's own helpers come here
too (``fake_python``, its PALAVER_PYTHON).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    spec_file = os.environ.get("PALAVER_TEST_ENGINE")
    if spec_file:
        spec = json.loads(Path(spec_file).read_text())
        ready = bool(spec.get("models_ready", True))
        os.environ["PALAVER_ENGINE"] = str(Path(__file__).with_name("fake_engine.py"))
        from palaver import process_state, transcription
        from palaver.models import Segment

        process_state._here = lambda cfg, m: ready
        cloud = spec.get("cloud") or {}

        def heard(cfg, paths, pid, **_):
            return transcription.Outcome([Segment.from_dict(d) for d in cloud.get("segments", [])], cloud.get("language"),
                                         float(cloud.get("sent_seconds", 0.0)), cloud.get("model", "fake"))

        transcription._cloud = heard
    from palaver import cli

    return cli.main(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
