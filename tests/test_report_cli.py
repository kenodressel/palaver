"""`palaver report create | open | usage` (#59): the same zip as the window's,
for testers without the window, and the maintainer's reading of reports."""

import json
import zipfile

from palaver import usage
from palaver.cli import command_names, main


def _setup(tmp_path, isolated_config_home):
    rec = tmp_path / "Recordings"
    for mid in ("2026-10-29T10-00-00", "2026-10-30T09-00-00"):
        (rec / mid).mkdir(parents=True)
        (rec / mid / "transcript.json").write_text("[]")
    config = isolated_config_home / "palaver" / "config.toml"
    config.parent.mkdir(parents=True)
    config.write_text(f'[notion]\ntoken = "secret_abcdef_12345"\nparent_page_id = "p"\n'
                      f'[recording]\noutput_dir = "{rec}"\n')
    return rec, config


def test_report_create_writes_the_zip_about_the_latest_meeting_and_shows_it(tmp_path, isolated_config_home,
                                                                            report_home, capsys):
    _setup(tmp_path, isolated_config_home)
    assert main(["report", "create", "-m", "Notes never came", "--wish"]) == 0
    [zip_path] = report_home.desktop.glob("Palaver report *.zip")
    assert report_home.revealed == [zip_path]
    with zipfile.ZipFile(zip_path) as z:
        form = json.loads(z.read("report.json"))["form"]
        assert "meetings/2026-10-30T09-00-00/transcript.json" in z.namelist()
    assert form == {"kind": "wish", "text": "Notes never came", "meeting": "2026-10-30T09-00-00", "audio": False}
    out = capsys.readouterr().out
    assert str(zip_path) in out and "about 2026-10-30T09-00-00" in out


def test_report_create_without_a_meeting_and_with_an_unknown_one(tmp_path, isolated_config_home, report_home, capsys):
    _setup(tmp_path, isolated_config_home)
    assert main(["report", "create", "--meeting", "none"]) == 0
    [zip_path] = report_home.desktop.glob("*.zip")
    with zipfile.ZipFile(zip_path) as z:
        assert json.loads(z.read("report.json"))["form"]["meeting"] is None
    assert main(["report", "create", "--meeting", "2020-01-01T00-00-00"]) == 2
    assert "error: no meeting" in capsys.readouterr().out


def test_report_open_and_usage_read_what_create_wrote(tmp_path, isolated_config_home, report_home, capsys):
    _setup(tmp_path, isolated_config_home)
    usage.record("action", "meeting.trash")
    main(["report", "create", "-m", "It froze"])
    [zip_path] = report_home.desktop.glob("*.zip")
    capsys.readouterr()
    assert main(["report", "open", str(zip_path), "--dir", str(tmp_path / "unpacked")]) == 0
    out = capsys.readouterr().out
    assert "It froze" in out and (tmp_path / "unpacked" / "report.json").is_file()
    assert main(["report", "usage", str(zip_path)]) == 0
    assert "action:meeting.trash" in capsys.readouterr().out


def test_every_command_is_counted_as_typed_or_started_by_the_app(tmp_path, isolated_config_home):
    _setup(tmp_path, isolated_config_home)
    main(["list"])
    last = usage.read()[-1]
    assert last["kind"] == "cli" and last["id"] == "list" and last["by"] == "app"  # pytest's stdin is no terminal


def test_the_cli_catalog_has_every_command():
    names = command_names()
    assert {"report", "doctor", "process", "menubar"} <= set(names)
