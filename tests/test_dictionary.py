"""Tests for dictionary loader and replacement logic."""

from pathlib import Path

from palaver.dictionary import Dictionary, load_dictionary


def _write(path: Path, content: str) -> None:
    path.write_text(content)


def test_missing_file_returns_empty(tmp_path: Path):
    d = load_dictionary(tmp_path / "nope.toml")
    assert d.initial_prompt == ""
    assert d.replacements == {}


def test_load_initial_prompt(tmp_path: Path):
    p = tmp_path / "dict.toml"
    _write(p, '[initial_prompt]\ntext = "Sprint Planning OKRs KPIs"\n')
    d = load_dictionary(p)
    assert d.initial_prompt == "Sprint Planning OKRs KPIs"


def test_load_replacements(tmp_path: Path):
    p = tmp_path / "dict.toml"
    _write(
        p,
        """
        [replacements]
        "kay pee eye" = "KPI"
        "oh kay are" = "OKR"
        """,
    )
    d = load_dictionary(p)
    assert d.replacements == {"kay pee eye": "KPI", "oh kay are": "OKR"}


def test_apply_replacements_case_insensitive():
    d = Dictionary(initial_prompt="", replacements={"kay pee eye": "KPI"})
    assert d.apply("Our Kay Pee Eye is great") == "Our KPI is great"


def test_apply_replacements_leaves_unmatched_text():
    d = Dictionary(initial_prompt="", replacements={"foo": "bar"})
    assert d.apply("nothing to replace here") == "nothing to replace here"


def test_apply_with_empty_replacements():
    d = Dictionary(initial_prompt="hint", replacements={})
    assert d.apply("hello world") == "hello world"
