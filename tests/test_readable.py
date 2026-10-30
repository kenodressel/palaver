"""Tests for the clean-verbatim transcript (issue #26)."""

import pytest

from palaver.models import Utterance
from palaver.readable import clean_text, readable


@pytest.mark.parametrize(
    "raw, clean",
    [
        ("Um, so we, uh, need a plan.", "So we need a plan."),
        ("Und dann, ähm, machen wir das.", "Und dann machen wir das."),
        ("Das passt, äh.", "Das passt."),
        ("Das passt, äh. und dann weiter", "Das passt. Und dann weiter"),
        ("I think uh we can also quickly go over the last point.",
         "I think we can also quickly go over the last point."),
        ("Mm-hmm, that's right.", "That's right."),
        # Austrian "eh" means "anyway" — a word, not a filler.
        ("Das ist eh klar.", "Das ist eh klar."),
        # German "um" is a word ("um zu", "damit um"), English "um" a filler.
        ("Wie gehen wir damit um.", "Wie gehen wir damit um."),
        ("Wir brauchen Zeit, um da zu einem Ergebnis zu kommen.",
         "Wir brauchen Zeit, um da zu einem Ergebnis zu kommen."),
        ("Let's think about this um I also don't know.", "Let's think about this I also don't know."),
        ("Um, wir starten den Rollout am Montag.", "Wir starten den Rollout am Montag."),
        ("Wie gehen wir damit um, wenn das passiert?", "Wie gehen wir damit um, wenn das passiert?"),
        (", äh, also wo stehen wir gerade?", "Also wo stehen wir gerade?"),
    ],
)
def test_filler_words_are_removed(raw, clean):
    assert clean_text(raw) == clean


@pytest.mark.parametrize(
    "raw, clean",
    [
        ("If the the the tax ministry comes", "If the tax ministry comes"),
        ("I think uh we we can do that.", "I think we can do that."),
        ("And, and that was it.", "And that was it."),
        ("the uh the thing", "the thing"),
        ("Mm -hmm.", ""),
        ("oder seit seit vier Monaten", "oder seit vier Monaten"),
        # Repeated phrases, not just words.
        ("I'm happy we made we made it in the end", "I'm happy we made it in the end"),
        ("not sure if you remember when I when I told you", "not sure if you remember when I told you"),
        ("Yeah, I remember, I remember and I was also sick.", "Yeah, I remember and I was also sick."),
        ("Sorry, we have a Facebook, this one, this one.", "Sorry, we have a Facebook, this one."),
        ("Wie gesagt, wie gesagt, das passt.", "Wie gesagt, das passt."),
        ("I would say I would say we start.", "I would say we start."),
    ],
)
def test_stutters_collapse(raw, clean):
    assert clean_text(raw) == clean


@pytest.mark.parametrize(
    "text",
    ["Ja, ja.", "Ja, ja, ja.", "Ciao, ciao.", "Okay, bye bye.", "Das ist sehr sehr gut.",
     "Absolut, absolut, absolut.", "bla bla",
     # German "der, der" / "die, die" is grammar ("those who"), "echt, echt" emphasis.
     "Und ich glaube die, die Bescheid wussten, waren dabei.", "Das war echt, echt chill.",
     "Das wird nach und nach besser.", "Okay, bye bye.", "Ja, ja, ja, ja.", "bla bla bla bla bla."],
)
def test_deliberate_repeats_stay(text):
    assert clean_text(text) == text


def test_readable_drops_filler_only_turns_and_keeps_short_answers():
    utterances = [
        Utterance("Anna", 0.0, 2.0, "Wir starten am Montag."),
        Utterance("Timo", 2.0, 2.5, "Mm-hmm."),
        Utterance("Timo", 3.0, 3.5, "Um"),
        Utterance("Timo", 4.0, 4.5, "Genau."),
        Utterance("Anna", 5.0, 7.0, "Und, äh, dann der Rollout."),
    ]
    out = readable(utterances)
    assert [(u.speaker, u.start, u.text) for u in out] == [
        ("Anna", 0.0, "Wir starten am Montag."),
        ("Timo", 4.0, "Genau."),
        ("Anna", 5.0, "Und dann der Rollout."),
    ]
    assert utterances[4].text == "Und, äh, dann der Rollout."  # input untouched


def test_numbers_glued_to_words_get_their_space():
    assert clean_text("Wir zahlen aktuell1040 für150 Millionen bis Ende2030.") == \
        "Wir zahlen aktuell 1040 für 150 Millionen bis Ende 2030."
    assert clean_text("H100, MP3, GPT4, COVID19 und S3 bleiben.") == "H100, MP3, GPT4, COVID19 und S3 bleiben."
