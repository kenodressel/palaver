"""App settings: settings.json next to config.toml, never inside it (#42)."""

from palaver import settings
from palaver._xdg import xdg_config_home


def test_settings_default_and_roundtrip():
    assert settings.load().realtime is True
    settings.save(settings.Settings(realtime=False))
    assert settings.load().realtime is False
    assert settings.load().record_teams is True
    (xdg_config_home() / "palaver" / "settings.json").write_text("{broken")
    assert settings.load() == settings.Settings()


def test_a_missing_key_takes_the_default_and_wrong_types_are_ignored():
    path = xdg_config_home() / "palaver" / "settings.json"
    path.parent.mkdir(parents=True)
    path.write_text('{"realtime": false, "record_teams": "no"}')
    s = settings.load(settings.Settings(record_slack=False))
    assert (s.realtime, s.record_teams, s.record_slack) == (False, True, False)


def test_live_processing_is_a_setting_the_app_changes():
    """#55: the setup assistant turns live processing off on a small Mac;
    config.toml's [processing].live stays its default."""
    assert settings.load().live_processing is True
    assert settings.load(settings.Settings(live_processing=False)).live_processing is False
    settings.update({"live_processing": False})
    assert settings.load(settings.Settings(live_processing=True)).live_processing is False


def test_user_name_from_settings():
    assert settings.user_name() is None
    settings.update({"user_name": "  Anna Huber "})
    assert settings.user_name() == "Anna Huber"
    settings.update({"user_name": ""})
    assert settings.user_name() is None


def test_the_name_is_read_again_by_long_running_parts():
    """#55: the menu bar app and the MCP server read the name per use, so a
    change in the setup assistant applies without a restart."""
    assert settings.current_user_name("Timo") == "Timo"
    settings.update({"user_name": "Timo Strauß"})
    assert settings.current_user_name("Timo") == "Timo Strauß"


def test_the_mcp_server_follows_a_new_name(tmp_path):
    from palaver.mcp_server import Meetings

    s = Meetings(tmp_path, "Timo")
    settings.update({"user_name": "Timo Strauß"})
    assert s.user_name == "Timo Strauß"


def test_two_processes_updating_at_once_lose_no_change(tmp_path):
    """The window's server and the menu bar app are two processes (#57):
    each update reads, merges and writes under a lock, so none is lost."""
    import os
    import subprocess
    import sys

    script = (
        "import sys\n"
        "from palaver import settings\n"
        "who = sys.argv[1]\n"
        "for i in range(40):\n"
        "    settings.update({f'{who}{i}': True})\n"
    )
    env = {**os.environ}
    procs = [subprocess.Popen([sys.executable, "-c", script, who], env=env) for who in ("a", "b", "c")]
    for p in procs:
        assert p.wait(60) == 0
    raw = settings.read_raw()
    assert all(raw.get(f"{who}{i}") is True for who in "abc" for i in range(40))
    assert not list(settings.path().parent.glob("*.tmp*"))  # no temp files left
