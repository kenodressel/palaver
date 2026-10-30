"""Tests for moving the old name's folders (meeting-transcribe → palaver)."""

from pathlib import Path

from palaver import migrate


def test_old_folders_move_to_the_new_name(tmp_path: Path):
    old, new = tmp_path / "meeting-transcribe", tmp_path / "palaver"
    (old / "voices").mkdir(parents=True)
    (old / "voices" / "anna.json").write_text("{}")
    (old / "glossary.json").write_text("{}")

    assert migrate.move(old, new) == [new / "glossary.json", new / "voices"]
    assert (new / "voices" / "anna.json").exists() and not old.exists()
    assert migrate.move(old, new) == []  # once


def test_what_the_new_folder_has_or_a_venv_stays(tmp_path: Path):
    old, new = tmp_path / "old", tmp_path / "new"
    (old / "venv").mkdir(parents=True)
    (old / "app.log").write_text("old")
    (old / "daemon.json").write_text("{}")
    new.mkdir()
    (new / "app.log").write_text("new")  # the launcher started it already

    assert migrate.move(old, new) == [new / "daemon.json"]
    assert (new / "app.log").read_text() == "new"
    assert sorted(p.name for p in old.iterdir()) == ["app.log", "venv"]
