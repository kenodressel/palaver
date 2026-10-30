"""Search by meaning (#46): an index per meeting, built in the background,
and a searcher that loads its model on demand and lets it go when idle."""

import json
import os
import re
from datetime import date
from pathlib import Path

import numpy as np
import pytest

from palaver import semantic, settings
from palaver.paths import RecordingPaths
from palaver.webapp import api

from .test_webapp import MEETING, _meeting

# Words of one meaning share a dimension: "pricing" finds "Kosten".
CONCEPTS = [{"pricing", "price", "kosten", "angebot", "cost", "offer"}, {"test", "testphase", "pilot"}]


class FakeEncoder:
    """Stands in for multilingual-e5-small: one dimension per concept, the
    rest hashed, so texts about the same thing point the same way."""
    loaded = 0

    def __init__(self):
        FakeEncoder.loaded += 1

    def _vec(self, text: str) -> np.ndarray:
        v = np.zeros(64, np.float32)
        for w in re.findall(r"\w+", text.casefold()):
            hit = next((i for i, c in enumerate(CONCEPTS) if w in c), None)
            if hit is not None:
                v[hit] += 3.0
        v[2 + len(text) % 60] += 0.1  # something, so nothing is all zeros
        return v / np.linalg.norm(v)

    def query(self, text):
        return self._vec(text)

    def passages(self, texts):
        return np.stack([self._vec(t) for t in texts]) if texts else np.zeros((0, 64), np.float32)


@pytest.fixture
def meeting(tmp_path: Path) -> RecordingPaths:
    paths = _meeting(tmp_path)
    lines = json.loads(paths.transcript_json.read_text())
    lines.append({"speaker": "SPEAKER_00", "start": 16.0, "end": 19.0,
                  "text": "Die Kosten für das Angebot sind noch zu hoch für den Kunden."})
    lines.append({"speaker": "SPEAKER_00", "start": 19.0, "end": 20.0,
                  "text": "Das müssen wir mit dem Einkauf klären, bevor wir zusagen."})
    paths.transcript_json.write_text(json.dumps(lines))
    return paths


def test_a_meeting_is_cut_into_notes_pieces_and_runs_of_one_speaker(meeting):
    chunks = semantic.chunks(meeting)
    kinds = [c["kind"] for c in chunks]
    assert kinds[:3] == ["summary", "decision", "step"]
    assert {"kind": "step", "text": "Send the offer", "owner": "SPEAKER_01"} in chunks
    [line] = [c for c in chunks if c["kind"] == "line"]  # the short lines say too little
    assert line == {"kind": "line", "speaker": "SPEAKER_00", "start": 16.0,
                    "text": "Die Kosten für das Angebot sind noch zu hoch für den Kunden. "
                            "Das müssen wir mit dem Einkauf klären, bevor wir zusagen."}


def test_long_runs_are_split(meeting):
    lines = [{"speaker": "Timo", "start": float(i), "end": i + 1.0, "text": " ".join(f"w{chr(97 + j % 26)}{chr(97 + j // 26)}" for j in range(30)) + "."}
             for i in range(10)]
    meeting.transcript_json.write_text(json.dumps(lines))
    runs = [c for c in semantic.chunks(meeting) if c["kind"] == "line"]
    assert [c["start"] for c in runs] == [0.0, 2.0, 4.0, 6.0, 8.0]  # two lines of 30 words, never over CHUNK_WORDS


def test_an_index_is_written_once_and_again_when_the_meeting_changes(meeting, tmp_path):
    assert semantic.stale(tmp_path) == [meeting]
    assert semantic.index_stale(tmp_path, FakeEncoder) == 1
    assert semantic.stale(tmp_path) == []
    assert semantic.index_stale(tmp_path, FakeEncoder) == 0
    index = json.loads((meeting.folder / semantic.INDEX_JSON).read_text())
    assert index["model"] == semantic.embeddings.MODEL and len(index["chunks"]) == 4
    assert np.load(meeting.folder / semantic.INDEX_NPY).dtype == np.float16
    later = meeting.notes.stat().st_mtime_ns + 10**9
    os.utime(meeting.notes, ns=(later, later))  # new notes
    assert semantic.stale(tmp_path) == [meeting]


def test_meetings_still_recorded_or_processed_are_not_indexed(tmp_path: Path):
    folder = tmp_path / "2026-10-28T09-00-00"
    folder.mkdir()
    (folder / "meta.json").write_text("{}")
    assert semantic.stale(tmp_path) == []


def test_indexing_stops_when_asked_between_meetings(meeting, tmp_path):
    assert semantic.index_stale(tmp_path, FakeEncoder, should_stop=lambda: True) == 0


def test_the_searcher_finds_by_meaning_and_lets_the_model_go(meeting):
    semantic.index_stale(meeting.folder.parent, FakeEncoder)
    clock = [0.0]
    searcher = semantic.Searcher(FakeEncoder, idle_seconds=60, clock=lambda: clock[0], timer=False)
    FakeEncoder.loaded = 0
    found = searcher.search([meeting], "pricing")
    hits = found[MEETING]
    assert {h["kind"] for h in hits} == {"decision", "step", "line"}  # "offer" and "Angebot" too
    line = next(h for h in hits if h["kind"] == "line")
    assert line["start"] == 16.0 and line["score"] > semantic.SMALL_SCORE
    assert searcher.search([meeting], "pricing", kinds={"summary"}) == {}
    assert searcher.search([meeting], "pilot") == {}  # nothing about a test phase
    assert FakeEncoder.loaded == 1
    clock[0] = 59
    searcher.release_if_idle()
    assert searcher.loaded
    clock[0] = 120
    searcher.release_if_idle()
    assert not searcher.loaded
    searcher.search([meeting], "pricing")
    assert FakeEncoder.loaded == 2


def test_the_searcher_keeps_to_one_speaker(meeting):
    semantic.index_stale(meeting.folder.parent, FakeEncoder)
    searcher = semantic.Searcher(FakeEncoder, timer=False)
    assert searcher.search([meeting], "pricing", kinds={"line"}, speaker=lambda paths, s: s == "SPEAKER_01") == {}
    assert searcher.search([meeting], "pricing", kinds={"line"}, speaker=lambda paths, s: s == "SPEAKER_00")


def test_a_stale_index_is_not_used(meeting):
    semantic.index_stale(meeting.folder.parent, FakeEncoder)
    later = meeting.transcript_json.stat().st_mtime_ns + 10**9
    os.utime(meeting.transcript_json, ns=(later, later))
    assert semantic.Searcher(FakeEncoder, timer=False).search([meeting], "pricing") == {}


def test_without_the_model_nothing_is_loaded(meeting, monkeypatch):
    monkeypatch.setattr(semantic.embeddings, "model_folder", lambda download: None)
    semantic.index_stale(meeting.folder.parent, FakeEncoder)
    assert not semantic.ready(meeting.folder.parent)
    assert semantic.Searcher(timer=False).search([meeting], "pricing") == {}


def test_search_by_meaning_in_the_window(meeting, monkeypatch, tmp_path):
    api.name_speaker(tmp_path, MEETING, "SPEAKER_00", "Mara")
    semantic.index_stale(tmp_path, FakeEncoder)
    monkeypatch.setattr(semantic.embeddings, "model_folder", lambda download: tmp_path)
    assert semantic.ready(tmp_path)
    searcher = semantic.Searcher(FakeEncoder, timer=False)
    [r] = api.search_meaning(tmp_path, "where did Mara talk about pricing", user_name="Timo", searcher=searcher)
    assert r["id"] == MEETING
    assert [(h["kind"], h["speaker"], h["start"]) for h in r["meaning"]] == [("line", "Mara", 16.0)]
    [r] = api.search_meaning(tmp_path, "pricing", user_name="Timo", searcher=searcher)
    step = next(h for h in r["meaning"] if h["kind"] == "step")
    assert step["owner"] == "Speaker 2"  # names are put in when shown
    assert api.search_meaning(tmp_path, "where did Timo talk about pricing", user_name="Timo",
                              searcher=searcher) == []
    assert api.search_meaning(tmp_path, "pricing since 2026-11-01", user_name="Timo", searcher=searcher,
                              today=date(2026, 12, 1)) == []
    page = api.search_page(tmp_path, "pricing", user_name="Timo")
    assert page["meaning"] == "ready"


def test_search_by_meaning_can_be_switched_off(meeting, monkeypatch, tmp_path):
    monkeypatch.setattr(semantic.embeddings, "model_folder", lambda download: tmp_path)
    semantic.index_stale(tmp_path, FakeEncoder)
    settings.update({"search_meaning": False})
    assert not semantic.ready(tmp_path)
    assert api.search_meaning(tmp_path, "pricing", user_name="Timo",
                              searcher=semantic.Searcher(FakeEncoder, timer=False)) == []


def test_a_hit_has_to_stand_out_from_the_rest():
    """multilingual-e5 scores a short German word ~0.80 against most pieces:
    over many pieces, a hit needs MARGIN above their median."""
    many = np.full(200, 0.80, np.float32)
    assert semantic.floor(many) == pytest.approx(0.80 + semantic.MARGIN)
    low = np.full(200, 0.70, np.float32)
    assert semantic.floor(low) == semantic.MIN_SCORE  # never below it
    assert semantic.floor(np.full(10, 0.85, np.float32)) == semantic.SMALL_SCORE  # too few to judge


def test_a_cut_can_be_undone_after_the_index_was_rewritten(meeting, tmp_path):
    """The index is derived: the background indexer rewriting it after a cut
    is no change that blocks ⌘Z, and an undo leaves no index of the cut."""
    semantic.index_stale(tmp_path, FakeEncoder)
    r = api.split_meeting(tmp_path, MEETING, 13.0, user_name="Timo")
    assert semantic.index_stale(tmp_path, FakeEncoder) == 2  # both halves, in the background
    api.undo_change(tmp_path, r["undo"], user_name="Timo")
    assert not (tmp_path / r["rest"]).exists()
    assert semantic.stale(tmp_path) == [meeting]  # indexed again, whole


def test_the_model_goes_five_minutes_after_the_last_search(meeting):
    """The release timer is armed at the first search and again while the
    model was used since: the model and the indexes go IDLE after the last."""
    semantic.index_stale(meeting.folder.parent, FakeEncoder)
    clock, timers = [0.0], []
    searcher = semantic.Searcher(FakeEncoder, idle_seconds=300, clock=lambda: clock[0],
                                 timer=lambda delay, run: timers.append((clock[0] + delay, run)))

    def fire():
        at, run = timers.pop(0)
        clock[0] = at
        run()

    searcher.search([meeting], "pricing")
    clock[0] = 200
    searcher.search([meeting], "pricing")  # used again: no second timer
    assert len(timers) == 1
    fire()  # 300 s after the first search, 100 after the last: kept, armed again
    assert searcher.loaded and len(timers) == 1 and timers[0][0] >= 500
    fire()
    assert not searcher.loaded and timers == [] and searcher._indexes == {}
    searcher.search([meeting], "pricing")
    assert searcher.loaded and len(timers) == 1  # armed again for the next round


def test_deleted_notes_and_removed_speakers_make_the_index_stale(meeting, tmp_path):
    semantic.index_stale(tmp_path, FakeEncoder)
    meeting.notes.unlink()
    assert semantic.stale(tmp_path) == [meeting]
    semantic.index_stale(tmp_path, FakeEncoder)
    assert semantic.stale(tmp_path) == []
    meeting.speakers_ignored.write_text('["SPEAKER_00"]')  # a speaker removed as noise
    assert semantic.stale(tmp_path) == [meeting]


def test_an_index_of_a_meeting_that_changed_while_it_was_built_is_not_current(meeting, tmp_path):
    class Changing(FakeEncoder):
        def passages(self, texts):
            later = meeting.transcript_json.stat().st_mtime_ns + 10**9
            os.utime(meeting.transcript_json, ns=(later, later))  # a line edited meanwhile
            return super().passages(texts)

    assert semantic.index_stale(tmp_path, Changing) == 1
    assert semantic.stale(tmp_path) == [meeting]  # built again next time


def test_one_bad_meeting_does_not_stop_the_rest(meeting, tmp_path):
    import shutil

    other = RecordingPaths(tmp_path / "2026-10-20T09-00-00")
    shutil.copytree(meeting.folder, other.folder)
    meeting.notes.write_text('{"summary": 1}')  # a summary that is no text

    class Picky(FakeEncoder):
        def passages(self, texts):
            if any(not isinstance(t, str) for t in texts):
                raise TypeError("not a text")
            return super().passages(texts)

    assert semantic.index_stale(tmp_path, Picky) == 1  # the other one
    assert semantic.stale(tmp_path) == []  # the bad one waits for its files to change
    later = meeting.notes.stat().st_mtime_ns + 10**9
    meeting.notes.write_text('{"summary": "Fixed."}')
    os.utime(meeting.notes, ns=(later, later))
    assert semantic.stale(tmp_path) == [meeting]
