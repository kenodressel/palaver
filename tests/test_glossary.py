"""Tests for the glossary and its suggestions (issues #23, #33)."""

import json
from pathlib import Path

import pytest

from palaver import glossary as G
from palaver.models import Utterance
from palaver.readable import readable


@pytest.fixture
def g(tmp_path: Path) -> G.Glossary:
    return G.Glossary(tmp_path / "glossary.json")


def test_variants_are_written_as_their_term(g):
    g.add("Attakring", ["Atterkring"])
    g.add("Unit 214", ["Unit zu14"])
    g.add("Unit", ["Junit"])
    assert g.apply("Im Atterkring-Raum? Nein, atterkring. Merger von Unit zu14, Junit.") == \
        "Im Attakring-Raum? Nein, Attakring. Merger von Unit 214, Unit."


def test_a_variant_belongs_to_one_term(g, tmp_path):
    a = g.add("Karel", ["CAREL"])
    b = g.add("Carelle", ["carel"])  # moves it
    assert g.terms()[a]["variants"] == [] and g.terms()[b]["variants"] == ["carel"]
    g.add("Carel")  # the right spelling after all: no longer a variant of anything
    assert g.terms()[b]["variants"] == []
    g.save()
    assert G.Glossary(tmp_path / "glossary.json").find("karel") == a
    with pytest.raises(ValueError):
        g.update(a, term="Carelle")


def test_the_user_glossary_applies_to_readable_transcripts(tmp_path):
    glossary = G.Glossary()  # the user's (tests have their own config folder)
    glossary.add("Databricks", ["Data Bricks"])
    glossary.save()
    [u] = readable([Utterance("SPEAKER_00", 0, 1, "Wir nutzen äh Data Bricks.")])
    assert u.text == "Wir nutzen Databricks."
    assert readable([Utterance("S", 0, 1, "Data Bricks")], glossary=G.Glossary(tmp_path / "none.json"))[0].text \
        == "Data Bricks"


def test_cologne_phonetics():
    assert G.cologne("Wasti") == G.cologne("Vasti") == "382"
    assert G.cologne("Müller") == G.cologne("Mueller") == "657"
    assert G.cologne("Wikipedia") == "3412"


def _transcripts(**meetings):
    return {m: [(float(i), line) for i, line in enumerate(lines)] for m, lines in meetings.items()}


def test_suggestions_from_known_names_sound_alikes_and_recurring_terms(g):
    t = _transcripts(
        m1=["Wir sind im Atterkring-Raum.", "Das macht Wasti.", "Databricks läuft.", "Wir müssen schedulen."],
        m2=["Vasti meint, Databricks ist teuer.", "Wasti sagt ja.", "Die Kita ist zu."],
        m3=["Databricks again, said CAREL."],
    )
    s = G.suggest(t, ["Attakring", "Karel Kralek", "Lead Engineer"], g)
    by_kind = {(x["kind"], x["term"]): x for x in s}

    assert by_kind[("variant", "Karel")]["variants"] == ["CAREL"]
    assert by_kind[("cluster", "Wasti")]["variants"] == ["Wasti", "Vasti"]
    term = by_kind[("term", "Databricks")]
    assert term["count"] == 3 and term["meetings"] == ["m1", "m2", "m3"]
    assert term["examples"][0] == {"meeting": "m1", "start": 2.0, "text": "Databricks läuft."}
    words = {w for x in s for w in [x["term"], *x["variants"]]}
    assert not words & {"schedulen", "Kita", "Lead"}  # ordinary words, lower case, too common


def test_accepted_and_rejected_suggestions_are_not_suggested_again(g):
    t = _transcripts(m1=["Databricks", "Wasti"], m2=["Databricks", "Vasti"])
    s = {x["kind"]: x for x in G.suggest(t, [], g)}
    g.add("Databricks")
    g.reject(s["cluster"]["key"])
    assert G.suggest(t, [], g) == []


def test_a_name_heard_as_two_words_is_a_variant(g):
    g.add("Databricks")
    t = _transcripts(m1=["Wir laden das in Data Bricks hoch."], m2=["Data Bricks ist teuer, sagt Zabek Hollmer."])
    s = {x["term"]: x for x in G.suggest(t, ["Sebastian Zabek-Hollmer"], g) if x["kind"] == "variant"}
    assert s["Databricks"]["variants"] == ["Data Bricks"] and s["Databricks"]["count"] == 2
    assert s["Zabek-Hollmer"]["variants"] == ["Zabek Hollmer"]
    g.add("Databricks", ["Data Bricks"])
    assert g.apply("in Data Bricks hoch") == "in Databricks hoch"


def test_the_glossary_applies_to_notes_too(g):
    g.add("Attakring", ["Atterkring"])
    notes = {"summary": "Meeting in Atterkring.", "next_steps": [{"owner": "Anna", "task": "Book Atterkring"}], "n": 3}
    assert g.apply_to(notes) == {"summary": "Meeting in Attakring.",
                                 "next_steps": [{"owner": "Anna", "task": "Book Attakring"}], "n": 3}


def test_an_ordinary_word_heard_unsure_can_be_a_known_name(g):
    """"Cloud" is ordinary English, so it never counted as a name; heard
    unsure and sounding like KLOUD, it is suggested as KLOUD's variant."""
    transcripts = {"m1": [(1.0, "Willkommen bei Cloud, wir machen das Projekt.")],
                   "m2": [(2.0, "Bei Cloud arbeiten wir anders.")]}
    assert not [s for s in G.suggest(transcripts, ["KLOUD"], g) if "Cloud" in s["variants"]]
    found = G.suggest(transcripts, ["KLOUD"], g, unsure={"cloud", "projekt"})
    [variant] = [s for s in found if s["kind"] == "variant"]
    assert variant["term"] == "KLOUD" and variant["variants"] == ["Cloud"] and variant["count"] == 2
    assert variant["unsure"]  # the card says why an ordinary word is suggested
    assert not [s for s in found if "Projekt" in (s["term"], *s["variants"])]  # ordinary, no known name near


def test_an_ordinary_word_heard_unsure_only_now_and_then_is_no_name(g):
    """"Teil" is said everywhere; the transcriber doubting it once does not
    make it a mishearing of Theil, nor does a lower-case "teile" ever."""
    transcripts = {f"m{i}": [(1.0, "Ein Teil davon ist fertig."), (2.0, "Das teile ich gerne.")] for i in range(5)}
    found = G.suggest(transcripts, ["Anna Theil"], g, unsure={"teil": 1, "teile": 5})
    assert not [s for s in found if s["kind"] == "variant"]
    # Doubted most of the times it was said, a capitalized one still is.
    found = G.suggest(transcripts, ["Anna Theil"], g, unsure={"teil": 4})
    [variant] = [s for s in found if s["kind"] == "variant"]
    assert variant["variants"] == ["Teil"]


def test_unsure_words_of_the_recordings(tmp_path):
    folder = tmp_path / "2026-10-27T16-03-07"
    folder.mkdir()
    (folder / "transcript.json").write_text(json.dumps([
        {"speaker": "A", "start": 0, "end": 1, "text": "bei Cloud", "unsure": ["Cloud"]},
        {"speaker": "B", "start": 1, "end": 2, "text": "ja", "heard": "jo", "unsure": ["jo"]},  # edited: sure
    ]))
    assert G.unsure_words(tmp_path) == {"cloud": 1}


def test_the_glossary_says_where_it_respelled(g):
    g.add("Zini", ["Tini", "Genie"])
    g.add("KLOUD", ["Cloud"])
    text, marks = g.apply_marked("Wir lösen Tini ab, sagt Cloud, mit Genie.")
    assert text == "Wir lösen Zini ab, sagt KLOUD, mit Zini."
    assert [(text[a:b], heard) for a, b, heard in marks] == [("Zini", "Tini"), ("KLOUD", "Cloud"), ("Zini", "Genie")]
    assert g.apply_marked("nichts davon") == ("nichts davon", [])


def test_readable_lines_carry_where_the_glossary_respelled(g):
    g.add("Zini", ["Tini"])
    [u] = readable([Utterance("A", 0.0, 1.0, "Äh, wir lösen Tini ab.")], glossary=g)
    assert u.text == "Wir lösen Zini ab." and [(u.text[a:b], h) for a, b, h in u.glossed] == [("Zini", "Tini")]
    assert "glossed" not in u.to_dict()  # worked out when shown, never stored
