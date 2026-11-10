"""Is the phase 3 ledger complete? (Task 69)

For every Python test file of a module phase 3 ported (the files Tasks 5–66 of
docs/superpowers/plans/2026-11-04-swift-server-phase3.md name, and every
tests/test_webapp*.py and tests/test_*_api.py), each ``def test_…`` is either a
Swift test (``native/Tests``: ``func test_…`` of the same name, or the same words in
camelCase as the phase 2 suites name them) or named in the ledger
(docs/superpowers/specs/2026-11-04-phase3-ledger.md), with its reason there.

Not checked: tests/e2e/ (they run against palaver-server itself) and
``*_swift_contract.py`` (Python tests of a Swift program).

    uv run python tools/parity/ledger_check.py

Exit 0 when nothing is missing; 1 with the missing ``file::test`` names listed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEDGER = ROOT / "docs" / "superpowers" / "specs" / "2026-11-04-phase3-ledger.md"
SWIFT_TESTS = ROOT / "native" / "Tests"

# The Python test files Tasks 5–66 name (their briefs' "Ports" and test lists).
FILES = (
    "test_aec.py", "test_app_query.py", "test_attribution.py", "test_calendar_events.py", "test_cleanup.py",
    "test_cli.py", "test_cloud_transcribe.py", "test_coach.py", "test_coach_review.py", "test_coach_worker.py",
    "test_continuation.py", "test_cutting.py", "test_dictionary.py", "test_embeddings.py", "test_exchange.py",
    "test_glossary.py", "test_inference.py", "test_lifecycle.py", "test_live.py", "test_live_coach.py",
    "test_live_coach_api.py", "test_llm.py", "test_mcp_server.py", "test_memory_api.py", "test_merger.py",
    "test_model_jobs.py", "test_models.py", "test_my_notes.py", "test_needs.py", "test_notes.py",
    "test_onboarding.py", "test_organizations.py", "test_paths.py", "test_people.py", "test_pipeline_e2e.py",
    "test_prep.py", "test_projects.py", "test_provider_helper.py", "test_readable.py", "test_render.py",
    "test_report.py", "test_report_api.py", "test_search.py", "test_search_api.py", "test_semantic.py",
    "test_settings.py", "test_setup_api.py", "test_shared_mic.py", "test_speakers.py", "test_storage.py",
    "test_store_lock.py", "test_stream.py", "test_stream_engine.py", "test_titles.py", "test_transcription.py",
    "test_undo.py", "test_update_api.py", "test_usage.py", "test_voice_activity.py", "test_voices.py",
    "test_web_process.py", "test_webapp.py", "test_webapp_remote.py",
)

DEF = re.compile(r"^(?:async )?def (test_\w+)", re.M)
SWIFT_FUNC = re.compile(r"\bfunc (\w+)\s*\(")
NAME = re.compile(r"\btest_\w+")


def python_files(root: Path = ROOT) -> list[Path]:
    tests = root / "tests"
    found = {tests / name for name in FILES}
    found |= set(tests.glob("test_webapp*.py")) | set(tests.glob("test_*_api.py"))
    return sorted(p for p in found if not p.name.endswith("_swift_contract.py"))


def _words(name: str) -> str:
    """A test's name without its ``test`` prefix, underscores and case: ``test_a_b`` and ``aB`` are alike."""
    return re.sub(r"^test_?", "", name).replace("_", "").lower()


def swift_tests(folder: Path = SWIFT_TESTS) -> tuple[set[str], set[str]]:
    """The names of the Swift tests (the first ``func`` after an ``@Test``, whose arguments may take lines), and
    their words."""
    names: set[str] = set()
    for file in folder.rglob("*.swift"):
        attributed = False
        for line in file.read_text(encoding="utf-8").splitlines():
            line = line.split("//")[0]  # not in a comment
            if "@Test" in line:
                attributed = True
            m = SWIFT_FUNC.search(line)
            if m:
                if attributed:
                    names.add(m.group(1))
                attributed = False
    return names, {_words(n) for n in names}


def missing(root: Path = ROOT, ledger: Path = LEDGER, swift: Path = SWIFT_TESTS) -> list[str]:
    """``tests/test_x.py::test_y`` for each Python test that is neither a Swift test nor named in the ledger."""
    names, words = swift_tests(swift)
    written = set(NAME.findall(ledger.read_text(encoding="utf-8")))
    out = []
    for file in python_files(root):
        if not file.exists():
            out.append(f"{file.relative_to(root)} (the file is gone: take it out of FILES)")
            continue
        for test in DEF.findall(file.read_text(encoding="utf-8")):
            if test not in names and _words(test) not in words and test not in written:
                out.append(f"{file.relative_to(root)}::{test}")
    return out


def main() -> int:
    gone = missing()
    if gone:
        print(f"{len(gone)} Python tests are neither Swift tests nor in the ledger ({LEDGER.relative_to(ROOT)}):")
        for line in gone:
            print(f"  {line}")
        return 1
    print(f"the ledger is complete: {len(python_files())} Python test files checked")
    return 0


if __name__ == "__main__":
    sys.exit(main())
