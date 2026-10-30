"""Tests for the manual speaker-rename wizard (issue #12)."""

import json
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from palaver.models import SpeakerTurn, Utterance
from palaver.paths import RecordingPaths
from palaver.speakers import (
    apply_speaker_names,
    load_speaker_names,
    longest_turns,
    run_wizard,
    save_speaker_names,
)


def test_longest_turns_picks_longest_per_speaker():
    turns = [
        SpeakerTurn("SPEAKER_00", 0.0, 2.0),
        SpeakerTurn("SPEAKER_01", 2.0, 9.0),
        SpeakerTurn("SPEAKER_00", 10.0, 15.0),
    ]
    picked = longest_turns(turns)
    assert picked["SPEAKER_00"] == SpeakerTurn("SPEAKER_00", 10.0, 15.0)
    assert picked["SPEAKER_01"] == SpeakerTurn("SPEAKER_01", 2.0, 9.0)


def test_apply_speaker_names_keeps_unmapped_labels():
    utts = [Utterance("SPEAKER_00", 0, 1, "a"), Utterance("Timo", 1, 2, "b")]
    out = apply_speaker_names(utts, {"SPEAKER_00": "Anna"})
    assert [u.speaker for u in out] == ["Anna", "Timo"]


def _folder(tmp_path: Path) -> RecordingPaths:
    paths = RecordingPaths(tmp_path)
    sf.write(str(paths.system_wav), np.zeros(16_000 * 20, dtype=np.float32), 16_000, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 20}))
    paths.system_turns.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 0.0, "end": 4.0},
        {"speaker": "SPEAKER_01", "start": 5.0, "end": 9.0},
        {"speaker": "SPEAKER_02", "start": 10.0, "end": 12.0},
    ]))
    paths.transcript_json.write_text(json.dumps([
        {"speaker": "Timo", "start": 0.0, "end": 1.0, "text": "Hi all."},
        {"speaker": "SPEAKER_00", "start": 0.5, "end": 4.0, "text": "Welcome to the review."},
        {"speaker": "SPEAKER_01", "start": 5.0, "end": 9.0, "text": "Numbers look good."},
        {"speaker": "SPEAKER_02", "start": 10.0, "end": 12.0, "text": "Agreed."},
    ]))
    return paths


def test_wizard_renames_merges_and_rewrites_transcripts(tmp_path: Path):
    paths = _folder(tmp_path)
    answers = iter(["r", "Anna", "", "Anna"])  # replay, name, keep, merge into Anna
    played: list[tuple[float, float]] = []

    run_wizard(paths, ask=lambda _prompt: next(answers), play=lambda wav, s, e: played.append((s, e)),
               say=lambda *_: None)

    assert load_speaker_names(paths) == {"SPEAKER_00": "Anna", "SPEAKER_02": "Anna"}
    transcript = json.loads(paths.transcript_json.read_text())
    assert [u["speaker"] for u in transcript] == ["Timo", "Anna", "SPEAKER_01", "Anna"]
    assert "**Anna** [14:35:17]  Welcome to the review." in paths.transcript_md.read_text()
    assert played[:2] == [(0.0, 4.0), (0.0, 4.0)]  # initial play + replay


def test_wizard_offers_previous_names_as_defaults(tmp_path: Path):
    paths = _folder(tmp_path)
    paths.speakers.write_text(json.dumps({"SPEAKER_01": "Ben"}))
    prompts: list[str] = []
    answers = iter(["", "", ""])

    run_wizard(paths, ask=lambda p: prompts.append(p) or next(answers), play=None, say=lambda *_: None)

    assert "[Ben]" in prompts[1]
    assert load_speaker_names(paths) == {"SPEAKER_01": "Ben"}


def test_playback_clip_is_capped(tmp_path: Path):
    from palaver.speakers import MAX_SAMPLE_SECONDS

    paths = _folder(tmp_path)
    paths.system_turns.write_text(json.dumps([{"speaker": "SPEAKER_00", "start": 0.0, "end": 19.0}]))
    played = []
    run_wizard(paths, ask=lambda _p: "", play=lambda wav, s, e: played.append((s, e)), say=lambda *_: None)
    assert played == [(0.0, MAX_SAMPLE_SECONDS)]


def test_process_applies_saved_speaker_names(tmp_path: Path, monkeypatch):
    from palaver import cli
    from palaver.models import Segment, Word

    from .test_cli import _fake_models, _ns

    paths = RecordingPaths(tmp_path)
    tone = 0.3 * np.sin(2 * np.pi * 220 * np.arange(32_000) / 16_000)
    for wav in (paths.mic_wav, paths.system_wav):
        sf.write(str(wav), tone.astype(np.float32), 16_000, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 2}))
    paths.speakers.write_text(json.dumps({"SPEAKER_00": "Anna"}))
    _fake_models(
        monkeypatch,
        segments_for=lambda name: [] if name == "mic.wav" else [
            Segment(0.0, 1.0, "Hello there.", None, [Word("Hello", 0.0, 0.5), Word("there.", 0.5, 1.0)])
        ],
        turns=[SpeakerTurn("SPEAKER_00", 0.0, 1.5)],
    )

    assert cli._cmd_process(_ns(tmp_path)) == 0

    transcript = json.loads(paths.transcript_json.read_text())
    assert transcript == [
        {"speaker": "Anna", "start": 0.0, "end": 1.0, "text": "Hello there.", "label": "SPEAKER_00"}
    ]


def _with_embeddings(paths: RecordingPaths) -> None:
    paths.system_turns.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 0.0, "end": 30.0},
        {"speaker": "SPEAKER_01", "start": 30.0, "end": 31.0},  # too short to enrol
    ]))
    paths.speaker_embeddings.write_text(json.dumps({
        "SPEAKER_00": [1.0, 0.0, 0.0], "SPEAKER_01": [0.0, 1.0, 0.0],
    }))


def test_wizard_enrols_named_speakers_once(tmp_path: Path):
    from palaver.voices import VoiceBank

    paths = _folder(tmp_path)
    _with_embeddings(paths)
    say = []
    run_wizard(paths, ask=lambda _p: "Anna", play=None, say=say.append)
    run_wizard(paths, ask=lambda _p: "", play=None, say=lambda *_: None)  # rerun: no duplicates

    assert VoiceBank().names() == {"Anna": 1}  # SPEAKER_01 named too, but only 1 s of speech
    assert any("Remembered 1 voice" in line for line in say)


def test_wizard_prefills_recognized_name_and_enter_confirms(tmp_path: Path):
    from palaver.voices import VoiceBank

    paths = _folder(tmp_path)
    _with_embeddings(paths)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_00": {"name": "Anna", "similarity": 0.83}}))
    prompts = []

    run_wizard(paths, ask=lambda p: prompts.append(p) or "", play=None, say=lambda *_: None)

    assert "[Anna — recognized by voice, 0.83]" in prompts[0]
    assert load_speaker_names(paths) == {"SPEAKER_00": "Anna"}
    assert VoiceBank().names() == {"Anna": 1}


def test_process_recognizes_enrolled_voices(tmp_path: Path, monkeypatch):
    from palaver import cli
    from palaver.models import Segment, Word
    from palaver.voices import VoiceBank

    from .test_cli import _fake_models, _ns

    paths = RecordingPaths(tmp_path)
    tone = 0.3 * np.sin(2 * np.pi * 220 * np.arange(16_000 * 40) / 16_000)
    for wav in (paths.mic_wav, paths.system_wav):
        sf.write(str(wav), tone.astype(np.float32), 16_000, subtype="PCM_16")
    paths.meta.write_text(json.dumps({"start_time": "2026-10-20T14:35:17+02:00", "duration_seconds": 40}))
    VoiceBank().add("Anna", [1.0, 0.0, 0.0], source="earlier:SPEAKER_03")
    VoiceBank().add("Ben", [0.0, 1.0, 0.0], source="earlier:SPEAKER_01")
    _fake_models(
        monkeypatch,
        segments_for=lambda name: [] if name == "mic.wav" else [
            Segment(1.0, 2.0, "Hello.", None, [Word("Hello.", 1.0, 2.0)]),
            Segment(21.0, 22.0, "Hi.", None, [Word("Hi.", 21.0, 22.0)]),
        ],
        turns=[SpeakerTurn("SPEAKER_00", 0.0, 20.0), SpeakerTurn("SPEAKER_01", 20.0, 40.0)],
        embeddings={"SPEAKER_00": [0.9, 0.1, 0.0], "SPEAKER_01": [0.1, 0.9, 0.0]},
    )
    paths.speakers.write_text(json.dumps({"SPEAKER_01": "Benjamin"}))  # manual wins

    assert cli._cmd_process(_ns(tmp_path)) == 0

    assert [u["speaker"] for u in json.loads(paths.transcript_json.read_text())] == ["Anna", "Benjamin"]
    auto = json.loads(paths.speakers_auto.read_text())
    assert auto["SPEAKER_00"]["name"] == "Anna" and auto["SPEAKER_01"]["name"] == "Ben"


def test_process_rediarizes_when_embeddings_missing(tmp_path: Path, monkeypatch):
    from palaver import cli

    from .test_cli import _fake_models, _ns, _recording_folder

    paths = _recording_folder(tmp_path)
    paths.system_turns.write_text("[]")  # diarized before embeddings were kept
    _fake_models(monkeypatch, embeddings={"SPEAKER_00": [1.0, 0.0]})

    assert cli._cmd_process(_ns(tmp_path)) == 0
    assert json.loads(paths.speaker_embeddings.read_text()) == {"SPEAKER_00": [1.0, 0.0]}


def test_voices_cli_lists_and_forgets(capsys):
    from palaver import cli
    from palaver.voices import VoiceBank

    VoiceBank().add("Anna", [1.0, 0.0], source="m:SPEAKER_00")
    assert cli.main(["voices"]) == 0
    assert "Anna" in capsys.readouterr().out
    assert cli.main(["voices", "forget", "anna"]) == 0
    assert VoiceBank().names() == {}
    assert cli.main(["voices", "forget", "Nobody"]) == 1


def test_save_speaker_names_moves_a_corrected_voice_to_the_right_person(tmp_path: Path):
    from palaver.speakers import save_speaker_names
    from palaver.voices import VoiceBank

    paths = _folder(tmp_path)
    _with_embeddings(paths)
    save_speaker_names(paths, {"SPEAKER_00": "Anna"})
    assert VoiceBank().names() == {"Anna": 1}

    save_speaker_names(paths, {"SPEAKER_00": "Bea"})  # it was Bea all along
    assert VoiceBank().names() == {"Bea": 1}
    transcript = json.loads(paths.transcript_json.read_text())
    assert transcript[1]["speaker"] == "Bea" and transcript[1]["label"] == "SPEAKER_00"
    assert "**Bea**" in paths.transcript_md.read_text()

    save_speaker_names(paths, {})  # unnamed again
    assert VoiceBank().names() == {}
    assert json.loads(paths.transcript_json.read_text())[1]["speaker"] == "SPEAKER_00"


def test_save_speaker_names_keeps_recognized_names_unless_rejected(tmp_path: Path):
    from palaver.speakers import save_speaker_names

    paths = _folder(tmp_path)
    paths.speakers_auto.write_text(json.dumps({"SPEAKER_01": {"name": "Carl", "similarity": 0.8}}))
    save_speaker_names(paths, {"SPEAKER_00": "Anna"})
    speakers = [u["speaker"] for u in json.loads(paths.transcript_json.read_text())]
    assert speakers == ["Timo", "Anna", "Carl", "SPEAKER_02"]

    save_speaker_names(paths, {"SPEAKER_00": "Anna", "SPEAKER_01": "SPEAKER_01"})  # not Carl
    speakers = [u["speaker"] for u in json.loads(paths.transcript_json.read_text())]
    assert speakers == ["Timo", "Anna", "SPEAKER_01", "SPEAKER_02"]


def test_merging_a_split_speaker_and_splitting_it_off_again(tmp_path: Path):
    from palaver.speakers import load_merges, merge_speakers
    from palaver.voices import VoiceBank

    paths = _folder(tmp_path)
    paths.speaker_embeddings.write_text(json.dumps({
        "SPEAKER_00": [1.0, 0.0, 0.0], "SPEAKER_01": [0.0, 1.0, 0.0], "SPEAKER_02": [0.0, 0.0, 1.0],
    }))
    paths.system_turns.write_text(json.dumps([
        {"speaker": "SPEAKER_00", "start": 0.0, "end": 30.0},
        {"speaker": "SPEAKER_01", "start": 30.0, "end": 60.0},
        {"speaker": "SPEAKER_02", "start": 60.0, "end": 90.0},
    ]))

    def speakers():
        return [u["speaker"] for u in json.loads(paths.transcript_json.read_text())]

    merge_speakers(paths, "SPEAKER_01", "SPEAKER_00")  # both unnamed yet
    assert speakers() == ["Timo", "SPEAKER_00", "SPEAKER_00", "SPEAKER_02"]
    assert json.loads(paths.transcript_json.read_text())[2]["label"] == "SPEAKER_01"  # kept, to split again

    merge_speakers(paths, "SPEAKER_00", "SPEAKER_02")  # its merged label follows it
    assert load_merges(paths) == {"SPEAKER_00": "SPEAKER_02", "SPEAKER_01": "SPEAKER_02"}
    with pytest.raises(ValueError):
        merge_speakers(paths, "SPEAKER_02", "SPEAKER_01")

    save_speaker_names(paths, {"SPEAKER_02": "Konrad"})
    assert speakers() == ["Timo", "Konrad", "Konrad", "Konrad"]
    assert VoiceBank().names() == {"Konrad": 1}  # only the voice it was merged into

    merge_speakers(paths, "SPEAKER_00", None)
    merge_speakers(paths, "SPEAKER_01", None)
    assert speakers() == ["Timo", "SPEAKER_00", "SPEAKER_01", "Konrad"]
    assert not paths.speakers_merged.exists()


def test_merging_moves_a_name_given_only_to_the_merged_speaker(tmp_path: Path):
    from palaver.speakers import merge_speakers

    paths = _folder(tmp_path)
    save_speaker_names(paths, {"SPEAKER_01": "Konrad"})
    merge_speakers(paths, "SPEAKER_01", "SPEAKER_00")
    assert json.loads(paths.speakers.read_text()) == {"SPEAKER_00": "Konrad"}
    assert [u["speaker"] for u in json.loads(paths.transcript_json.read_text())][1:3] == ["Konrad", "Konrad"]
