"""Tests for "Uninstall Palaver…" (#60): what goes, what stays."""

import subprocess
from pathlib import Path

import pytest

from palaver import install_layout, uninstall


@pytest.fixture
def home(tmp_path) -> Path:
    h = tmp_path / "home"
    (install_layout.app_path(h) / "Contents").mkdir(parents=True)
    (install_layout.runtime_dir("rt-1", h) / "bin").mkdir(parents=True)
    (install_layout.models_dir(h) / "pyannote-community-1").mkdir(parents=True)
    install_layout.launch_agent(h).parent.mkdir(parents=True)
    install_layout.launch_agent(h).write_text("<plist/>")
    install_layout.cli_link(h).parent.mkdir(parents=True)
    install_layout.cli_link(h).symlink_to(install_layout.app_path(h) / "Contents" / "Resources" / "bin" / "palaver")
    (install_layout.support_dir(h) / "voices.json").write_text("{}")
    (install_layout.support_dir(h) / "updates").mkdir()
    install_layout.update_state_path(h).write_text("{}")
    (h / ".config" / "palaver").mkdir(parents=True)
    rec = h / "Meetings" / "Recordings"
    (rec / "2026-10-30T10-00-00").mkdir(parents=True)
    (rec / "2026-10-30T11-00-00-2").mkdir()
    (rec / "notes about the folder.txt").write_text("mine")
    (rec / ".trash" / "2026-10-29T09-00-00").mkdir(parents=True)
    (rec / ".trash" / "my own thing").mkdir()
    (rec / ".jobs").mkdir()
    (rec / ".jobs" / "notes-x.json").write_text("{}")
    return h


def names(paths, home):
    return sorted(str(p.relative_to(home)) for p in paths)


def test_by_default_the_app_runtime_login_item_and_command_go_and_everything_else_stays(home):
    plan = uninstall.plan(home, output_dir=home / "Meetings" / "Recordings")
    assert names(plan, home) == [
        ".local/bin/palaver",
        "Applications/Palaver.app",
        "Library/Application Support/palaver/runtime",
        "Library/Application Support/palaver/update.json",
        "Library/Application Support/palaver/updates",
        "Library/LaunchAgents/com.kenodressel.meeting-transcribe.plist",
    ]


def test_the_models_go_when_asked(home):
    plan = uninstall.plan(home, output_dir=home / "Meetings" / "Recordings", models=True)
    assert "Library/Application Support/palaver/models" in names(plan, home)


def test_recordings_go_only_when_ticked_and_only_palavers_own_folders(home):
    plan = uninstall.plan(home, output_dir=home / "Meetings" / "Recordings", recordings=True,
                          config_home=home / ".config")
    got = names(plan, home)
    assert "Meetings/Recordings/2026-10-30T10-00-00" in got
    assert "Meetings/Recordings/2026-10-30T11-00-00-2" in got
    assert "Meetings/Recordings/notes about the folder.txt" not in got
    assert "Meetings/Recordings/.trash/2026-10-29T09-00-00" in got  # deleted meetings, not yet emptied
    assert "Meetings/Recordings/.trash/my own thing" not in got
    assert "Meetings/Recordings/.jobs" in got
    assert "Library/Application Support/palaver/voices.json" in got  # Palaver's data
    assert ".config/palaver" in got
    assert "Library/Application Support/palaver/models" not in got  # not ticked: the models stay
    assert "Library/Application Support/palaver" not in got


def test_a_command_link_that_is_not_palavers_stays(home):
    link = install_layout.cli_link(home)
    link.unlink()
    link.symlink_to("/usr/local/bin/something-else")
    plan = uninstall.plan(home, output_dir=home / "Meetings" / "Recordings")
    assert ".local/bin/palaver" not in names(plan, home)


def test_a_recordings_folder_that_is_the_home_folder_itself_is_never_emptied(home):
    (home / "2026-10-30T09-00-00").mkdir()
    plan = uninstall.plan(home, output_dir=home, recordings=True, config_home=home / ".config")
    assert "2026-10-30T09-00-00" not in names(plan, home)


def test_the_script_waits_for_palaver_to_quit_then_removes_exactly_the_plan(home, tmp_path):
    keep = home / "Meetings" / "Recordings" / "notes about the folder.txt"
    plan = uninstall.plan(home, output_dir=home / "Meetings" / "Recordings", recordings=True, models=True,
                          config_home=home / ".config")
    assert all(p.is_relative_to(home) for p in plan)  # never anything outside the test's home
    script = tmp_path / "uninstall.sh"
    script.write_text(uninstall.script(plan, wait_for=[]))
    subprocess.run(["/bin/sh", str(script)], check=True, timeout=10)
    assert not install_layout.app_path(home).exists()
    assert not install_layout.runtimes_dir(home).exists()
    assert not install_layout.cli_link(home).is_symlink()
    assert keep.read_text() == "mine"


def test_a_path_with_quotes_is_quoted_for_the_shell(tmp_path):
    odd = tmp_path / "it's here"
    odd.mkdir()
    assert odd.is_relative_to(tmp_path)
    script = tmp_path / "u.sh"
    script.write_text(uninstall.script([odd], wait_for=[]))
    subprocess.run(["/bin/sh", str(script)], check=True, timeout=10)
    assert not odd.exists()


def test_with_everything_ticked_palavers_folder_goes_whole(home):
    plan = uninstall.plan(home, output_dir=home / "Meetings" / "Recordings", recordings=True, models=True,
                          config_home=home / ".config")
    assert "Library/Application Support/palaver" in names(plan, home)


def test_the_folders_emptied_go_too_when_nothing_else_is_in_them(home, tmp_path):
    rec = home / "Meetings" / "Recordings"
    (rec / ".trash" / "my own thing").rmdir()
    plan = uninstall.plan(home, output_dir=rec, recordings=True, config_home=home / ".config")
    script = tmp_path / "u.sh"
    script.write_text(uninstall.script(plan, wait_for=[], then_if_empty=uninstall.emptied(home, output_dir=rec)))
    subprocess.run(["/bin/sh", str(script)], check=True, timeout=10)
    assert not (rec / ".trash").exists()
    assert (rec / "notes about the folder.txt").exists()  # the recordings folder stays: it holds the user's file
    assert (install_layout.models_dir(home) / "pyannote-community-1").exists()
