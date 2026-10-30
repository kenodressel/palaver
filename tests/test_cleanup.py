"""Tests for transcript cleanup filters."""

from pathlib import Path

import numpy as np
import soundfile as sf

from palaver.cleanup import drop_bleed_duplicates, drop_echo, echoes_remote, drop_silent_segments
from palaver.models import Segment, Word

SR = 16_000


def _seg(start: float, end: float, text: str) -> Segment:
    return Segment(start=start, end=end, text=text, speaker=None, words=[])


def _wav(tmp_path: Path, regions: list[tuple[float, float, float]], seconds: float = 10.0) -> Path:
    """Silent WAV with sine bursts at (start, end, amplitude)."""
    x = np.zeros(int(seconds * SR), dtype=np.float32)
    for start, end, amp in regions:
        t = np.arange(int(start * SR), int(end * SR))
        x[t] = amp * np.sin(2 * np.pi * 220 * t / SR)
    path = tmp_path / "track.wav"
    sf.write(str(path), x, SR, subtype="PCM_16")
    return path


def test_drop_silent_segments_removes_hallucinations_on_silence(tmp_path: Path):
    """Whisper invents "Thank you." / "Yeah." at 30 s window starts over the
    near-silent AEC'd mic; real speech is far louder."""
    wav = _wav(tmp_path, [(1.0, 2.0, 0.2), (5.0, 6.0, 0.003)])  # -17 dBFS, -53 dBFS
    segs = [_seg(1.0, 2.0, "Real words here."), _seg(5.0, 6.0, "Thank you."), _seg(8.0, 9.0, "Yeah.")]

    kept = drop_silent_segments(segs, wav, min_peak_dbfs=-35.0)

    assert [s.text for s in kept] == ["Real words here."]


def test_drop_silent_segments_uses_loudest_frame(tmp_path: Path):
    """A short loud word inside a long, mostly quiet segment is speech."""
    wav = _wav(tmp_path, [(3.0, 3.2, 0.2)])
    kept = drop_silent_segments([_seg(1.0, 6.0, "Okay.")], wav, min_peak_dbfs=-35.0)
    assert len(kept) == 1


def test_drop_silent_segments_handles_segment_past_end(tmp_path: Path):
    wav = _wav(tmp_path, [], seconds=2.0)
    assert drop_silent_segments([_seg(5.0, 6.0, "ghost")], wav, min_peak_dbfs=-35.0) == []


def test_drop_bleed_duplicates_removes_mic_copies_of_remote_speech():
    mic = [
        _seg(10.0, 13.0, "I believe that one feedback from my side"),
        _seg(20.0, 22.0, "Let me share my screen now"),
        _seg(30.0, 30.5, "Yeah."),
    ]
    system = [
        _seg(9.5, 13.5, "I believe that one feedback from my side for you guys"),
        _seg(29.8, 30.6, "Yeah."),
    ]

    kept = drop_bleed_duplicates(mic, system)

    # Short acknowledgements are kept even when the remote side says the same.
    assert [s.text for s in kept] == ["Let me share my screen now", "Yeah."]


def test_drop_bleed_duplicates_ignores_same_words_at_other_times():
    mic = [_seg(100.0, 103.0, "we should ship the release today")]
    system = [_seg(10.0, 13.0, "we should ship the release today")]
    assert drop_bleed_duplicates(mic, system) == mic


def test_drop_bleed_duplicates_when_mic_merges_several_remote_segments():
    """One transcriber may join what the other split: a long mic segment can
    repeat three short remote segments at once."""
    mic = [_seg(5.0, 15.0, "Die nehmen jetzt viel einfach aus Martins Erfahrungen und "
                           "Martins Blueprints, nachdem aber deren Flow ein anderer ist")]
    system = [
        _seg(4.8, 8.0, "die nehmen jetzt viel einfach aus Martins Erfahrungen"),
        _seg(8.1, 11.0, "und Martins Blueprints,"),
        _seg(11.2, 15.2, "nachdem aber deren Flow ein anderer ist,"),
    ]
    assert drop_bleed_duplicates(mic, system) == []


def test_own_speech_sharing_only_common_words_is_kept():
    """Remote speech nearby shares function words with the user's own
    sentence; that alone must not make it a duplicate."""
    mic = [_seg(5.0, 9.0, "ich glaube das ist für den Kunden nicht so wichtig")]
    system = [
        _seg(3.0, 6.0, "das ist ja auch nicht so einfach für uns"),
        _seg(6.5, 10.0, "ich glaube wir müssen den Plan anpassen"),
    ]
    assert drop_bleed_duplicates(mic, system) == mic


def test_short_own_sentence_with_two_shared_pairs_is_kept():
    """Real case: 'Ja, ich habe es mitbekommen.' shares 'ich habe' and
    'habe es' with remote speech — half its word pairs, still the user's."""
    mic = [_seg(10.0, 11.5, "Ja, ich habe es mitbekommen.")]
    system = [_seg(9.0, 12.0, "habe ich ich habe es dann versucht ein bisschen zu proben, aber")]
    assert drop_bleed_duplicates(mic, system) == mic


def _timed(start: float, text: str, step: float = 0.4) -> Segment:
    """Segment with one word every ``step`` seconds from ``start``."""
    words = [Word(w, start + i * step, start + (i + 1) * step) for i, w in enumerate(text.split())]
    return Segment(start=start, end=words[-1].end, text=text, speaker=None, words=words)


def _tracks(tmp_path: Path, raw_regions, out_regions, seconds: float = 20.0) -> tuple[Path, Path]:
    raw = _wav(tmp_path, raw_regions, seconds).rename(tmp_path / "mic_raw.wav")
    out = _wav(tmp_path, out_regions, seconds).rename(tmp_path / "mic.wav")
    return out, raw


def test_drop_echo_catches_garbled_echo_of_remote_speech(tmp_path: Path):
    """Real case: quiet speaker echo left after AEC comes out garbled, so few
    word pairs match — but the words that do match land at the same moment."""
    system = [_timed(2.0, "you can have your health insurance claim after the initial processing")]
    mic = [_timed(2.05, "you can have your health and shooting job after the initial process")]
    assert drop_bleed_duplicates(mic, system) == mic  # what slipped through before
    out, raw = _tracks(tmp_path, [(2, 7, 0.1)], [(2, 7, 0.1)])  # AEC removed nothing
    assert drop_echo(mic, system, out, raw) == []


def test_drop_echo_keeps_the_user_repeating_remote_words_later(tmp_path: Path):
    system = [_timed(2.0, "we should ship the release today")]
    mic = [_timed(5.0, "we should ship the release today")]
    out, raw = _tracks(tmp_path, [(5, 8, 0.1)], [(5, 8, 0.1)])
    assert drop_echo(mic, system, out, raw) == mic


def test_drop_echo_when_aec_removed_most_of_what_the_mic_heard(tmp_path: Path):
    """Echo transcribed into words the remote side never said: the audio
    shows it — the mic heard the speakers, and AEC took that out."""
    mic = [_timed(3.0, "think those are not three"), _timed(10.0, "that is my point")]
    out, raw = _tracks(tmp_path, [(3, 5, 0.1), (10, 12, 0.1)], [(3, 5, 0.02), (10, 12, 0.1)])
    assert drop_echo(mic, [], out, raw) == [mic[1]]


def test_drop_echo_short_words_said_at_once_need_audio_evidence(tmp_path: Path):
    """Both sides say "Genau." at once: the user's own if AEC found no echo."""
    system = [_timed(2.0, "Genau."), _timed(10.0, "Ja.")]
    mic = [_timed(2.1, "Genau."), _timed(10.1, "Ja.")]
    out, raw = _tracks(tmp_path, [(2, 3, 0.1), (10, 11, 0.1)], [(2, 3, 0.1), (10, 11, 0.05)])
    assert drop_echo(mic, system, out, raw) == [mic[0]]


def test_drop_echo_without_the_raw_mic_uses_text_only(tmp_path: Path):
    system = [_timed(2.0, "you can have your health insurance claim after the initial processing")]
    mic = [_timed(2.05, "you can have your health and shooting job after the initial process"),
           _timed(10.0, "that is my point")]
    out = _wav(tmp_path, [(2, 7, 0.01), (10, 12, 0.1)], 20.0)
    assert drop_echo(mic, system, out, tmp_path / "missing.wav") == [mic[1]]


def test_echoes_remote_needs_half_and_three_words():
    remote = [Word("wann", 10.0, 10.2), Word("ist", 10.2, 10.3), Word("der", 10.3, 10.4), Word("go-live", 10.4, 10.9)]
    echo = Segment(10.05, 10.9, "wann ist der go-live", words=[Word("wann", 10.05, 10.2), Word("ist", 10.2, 10.3),
                                                                 Word("der", 10.3, 10.4), Word("go-live", 10.4, 10.9)])
    mine = Segment(10.0, 10.9, "ich glaube im März", words=[Word("ich", 10.0, 10.2), Word("glaube", 10.2, 10.4),
                                                              Word("im", 10.4, 10.5), Word("März", 10.5, 10.9)])
    short = Segment(10.0, 10.3, "wann ist", words=[Word("wann", 10.0, 10.2), Word("ist", 10.2, 10.3)])
    assert echoes_remote(echo, remote)
    assert not echoes_remote(mine, remote)
    assert not echoes_remote(short, remote)  # fewer than three aligned words
