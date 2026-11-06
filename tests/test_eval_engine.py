"""tools/eval_engine.py: the local gate for the Swift engine (synthetic data only)."""
from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("eval_engine", ROOT / "tools" / "eval_engine.py")
eval_engine = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eval_engine)


def test_refuses_without_eval_dir(capsys, tmp_path):
    assert eval_engine.main([], env={}) == 2
    assert "PALAVER_EVAL_DIR" in capsys.readouterr().err
    assert eval_engine.main([], env={"PALAVER_EVAL_DIR": str(tmp_path)}) == 2  # no eval.json in it
    assert "PALAVER_EVAL_DIR" in capsys.readouterr().err


def test_make_target_refuses_before_building_the_engine():
    out = subprocess.run(["make", "eval-engine"], cwd=ROOT, capture_output=True, text=True, timeout=30,
                         env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"})
    assert out.returncode != 0
    assert "PALAVER_EVAL_DIR" in out.stderr
    assert "swift build" not in out.stdout + out.stderr  # the check comes before the engine build


def test_confusion_on_toy_annotations():
    ref = [(0, 10, "A"), (10, 20, "B")]
    hyp = [(0, 12, "X"), (12, 20, "Y")]
    c = eval_engine.confusion(ref, hyp, collar=0)
    assert round(c["confusion"], 2) == 2.0
    assert round(c["total"], 2) == 20.0
    assert round(eval_engine.confusion_pct(ref, hyp, collar=0), 1) == 10.0
    assert (c["ref_speakers"], c["hyp_speakers"]) == (2, 2)


def test_confusion_ignores_labels_names_collar_and_ignored_regions():
    ref = [(0, 10, "A"), (10, 20, "B")]
    swapped = [(0, 10, "Y"), (10, 20, "X")]  # other names, same people
    assert eval_engine.confusion(ref, swapped)["confusion"] == 0
    off = [(0, 12, "X"), (12, 20, "Y")]
    assert eval_engine.confusion(ref, off, collar=0.25)["confusion"] < 2.0  # the boundary's forgiven
    assert round(eval_engine.confusion(ref, off, ignored=[(10, 12)], collar=0)["confusion"], 2) == 0.0
    silent = eval_engine.confusion(ref, [], collar=0)
    assert round(silent["missed"], 2) == 20.0 and silent["confusion"] == 0


def test_wer_on_synthetic_strings():
    e, n = eval_engine.word_errors("Der KLOUD Bericht ist fertig.", "der kloud bericht ist")
    assert (e, n) == (1, 5)
    e, n = eval_engine.word_errors("Straße", "strasse")
    assert e == 0  # ß and case are not errors
    assert eval_engine.word_errors("a b c d", "a x c d") == (1, 4)


def test_lost_passage_counter_counts_runs_of_eight():
    common = "northwind contoso " * 3
    lost = "one two three four five six seven eight nine"
    stored = f"{common} {lost} {common}"
    engine = f"{common} {common}"
    assert eval_engine.lost_passages(stored, engine) == (9, 0)
    assert eval_engine.lost_passages(engine, stored) == (0, 9)
    short = "one two three four five six seven"
    assert eval_engine.lost_passages(f"{common} {short} {common}", engine) == (0, 0)  # below the run length
    assert eval_engine.lost_passages(stored, stored) == (0, 0)


def test_lost_passage_replace_with_unequal_sides_counts_the_net_run():
    common = "northwind contoso " * 3
    nine = "one two three four five six seven eight nine"
    other = "alpha beta"
    # stored has 9 words where the engine has 2: a net run of 7 is too short; 10 vs 2 is 8, enough
    assert eval_engine.lost_passages(f"{common} {nine} {common}", f"{common} {other} {common}") == (0, 0)
    ten = nine + " ten"
    assert eval_engine.lost_passages(f"{common} {ten} {common}", f"{common} {other} {common}") == (8, 0)
    assert eval_engine.lost_passages(f"{common} {other} {common}", f"{common} {ten} {common}") == (0, 8)
