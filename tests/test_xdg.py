from pathlib import Path

from palaver._xdg import xdg_config_home
from palaver.config import default_config_path
from palaver.dictionary import default_dictionary_path


def test_xdg_config_home_respects_env(monkeypatch, tmp_path: Path):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    assert xdg_config_home() == tmp_path
    assert default_config_path() == tmp_path / "palaver" / "config.toml"
    assert default_dictionary_path() == tmp_path / "palaver" / "dictionary.toml"


def test_xdg_config_home_falls_back_to_dot_config(monkeypatch):
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    assert xdg_config_home() == Path.home() / ".config"


def test_empty_xdg_config_home_is_ignored(monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", "")
    assert xdg_config_home() == Path.home() / ".config"
