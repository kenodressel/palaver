"""Tests for the voice bank and automatic speaker recognition (issue #13)."""

import json
from pathlib import Path

import numpy as np
import pytest

from palaver.voices import VoiceBank, recognize


def _unit(*v) -> list[float]:
    a = np.array(v, dtype=float)
    return list(a / np.linalg.norm(a))


def test_bank_lives_in_config_dir_one_file_per_person(isolated_config_home: Path):
    bank = VoiceBank()
    bank.add("Anna Müller", _unit(1, 0, 0), source="2026-10-20T14-35-17:SPEAKER_00")
    files = list((isolated_config_home / "palaver" / "voices").glob("*.json"))
    assert len(files) == 1
    data = json.loads(files[0].read_text())
    assert data["name"] == "Anna Müller"
    assert data["samples"][0]["source"] == "2026-10-20T14-35-17:SPEAKER_00"
    assert VoiceBank().names() == {"Anna Müller": 1}


def test_add_ignores_duplicate_source():
    bank = VoiceBank()
    bank.add("Anna", _unit(1, 0, 0), source="m1:SPEAKER_00")
    bank.add("Anna", _unit(1, 0, 0), source="m1:SPEAKER_00")
    assert bank.names() == {"Anna": 1}


def test_match_requires_threshold_and_margin():
    bank = VoiceBank()
    bank.add("Anna", _unit(1, 0, 0), source="a")
    bank.add("Ben", _unit(0, 1, 0), source="b")

    assert bank.match(_unit(1, 0.2, 0))[0] == "Anna"
    assert bank.match(_unit(0.2, 0.2, 1)) is None  # nobody similar enough
    assert bank.match(_unit(1, 1, 0)) is None  # Anna and Ben too close to call


def test_match_uses_best_sample_per_person():
    bank = VoiceBank()
    bank.add("Anna", _unit(0, 0, 1), source="old-room")
    bank.add("Anna", _unit(1, 0, 0), source="new-room")
    assert bank.match(_unit(1, 0.1, 0))[0] == "Anna"


def test_forget_removes_person():
    bank = VoiceBank()
    bank.add("Anna", _unit(1, 0, 0), source="a")
    assert bank.forget("anna") is True  # case-insensitive
    assert bank.names() == {}
    assert bank.forget("Anna") is False


def test_recognize_skips_short_talkers():
    bank = VoiceBank()
    bank.add("Anna", _unit(1, 0, 0), source="a")
    found = recognize(
        {"SPEAKER_00": _unit(1, 0, 0), "SPEAKER_01": _unit(1, 0, 0)},
        {"SPEAKER_00": 60.0, "SPEAKER_01": 3.0},
        bank,
    )
    assert list(found) == ["SPEAKER_00"]
    assert found["SPEAKER_00"][0] == "Anna"
    assert found["SPEAKER_00"][1] == pytest.approx(1.0)


def test_remove_source_takes_a_sample_away_from_whoever_has_it():
    bank = VoiceBank()
    bank.add("Anna", _unit(1, 0, 0), source="m1:SPEAKER_00")
    bank.add("Anna", _unit(1, 0.1, 0), source="m2:SPEAKER_03")
    bank.add("Bob", _unit(0, 1, 0), source="m1:SPEAKER_01")
    assert bank.owner("m1:SPEAKER_01") == "Bob"
    assert bank.remove_source("m1:SPEAKER_01")
    assert bank.remove_source("m1:SPEAKER_00")
    assert bank.names() == {"Anna": 1}  # Bob had no samples left
    assert bank.owner("m1:SPEAKER_00") is None
    assert not bank.remove_source("m1:SPEAKER_00")


def test_recognize_among_invitees_is_less_strict():
    bank = VoiceBank()
    bank.add("Anna", _unit(1, 0, 0), source="a")
    bank.add("Ben", _unit(0, 1, 0), source="b")
    near_anna = _unit(1, 0.9, 0.2)  # 0.73 Anna, 0.66 Ben: too close to call, below 0.75
    talk = {"SPEAKER_00": 60.0}
    assert recognize({"SPEAKER_00": near_anna}, talk, bank) == {}
    found = recognize({"SPEAKER_00": near_anna}, talk, bank, invited=["Anna"])
    assert found["SPEAKER_00"][0] == "Anna"  # only Anna was invited
    assert recognize({"SPEAKER_00": near_anna}, talk, bank, invited=["Anna", "Ben"]) == {}  # margin


def test_recognize_falls_back_to_everyone_when_no_invitee_matches():
    bank = VoiceBank()
    bank.add("Anna", _unit(1, 0, 0), source="a")
    bank.add("Ben", _unit(0, 1, 0), source="b")
    found = recognize({"SPEAKER_00": _unit(0, 1, 0.05)}, {"SPEAKER_00": 60.0}, bank, invited=["Anna"])
    assert found["SPEAKER_00"][0] == "Ben"  # uninvited, but unmistakable
