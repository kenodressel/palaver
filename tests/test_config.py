"""Tests for config loading."""

from pathlib import Path

import pytest

from palaver.config import Config, load_config


def _write(path: Path, content: str) -> None:
    path.write_text(content)


def test_load_minimal_config(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(
        cfg_path,
        """
        [user]
        name = "Timo"

        [notion]
        token = "ntn_test"
        parent_page_id = "abc-123"
        """,
    )
    cfg = load_config(cfg_path)
    assert cfg.user_name == "Timo"
    assert cfg.notion_token == "ntn_test"
    assert cfg.notion_parent_page_id == "abc-123"
    # Defaults
    assert cfg.output_dir == Path.home() / "Meetings" / "Recordings"
    assert cfg.retention_days == 14
    assert cfg.language == "auto"
    assert cfg.whisper_repo == "mlx-community/whisper-large-v3-turbo"
    assert cfg.transcriber == "parakeet"
    assert cfg.notion_auto_sync is True


def test_env_var_overrides(tmp_path: Path, monkeypatch):
    cfg_path = tmp_path / "config.toml"
    _write(
        cfg_path,
        """
        [user]
        name = "Timo"
        [notion]
        parent_page_id = "abc-123"
        """,
    )
    monkeypatch.setenv("NOTION_TOKEN", "ntn_from_env")
    monkeypatch.setenv("HF_TOKEN", "hf_from_env")
    cfg = load_config(cfg_path)
    assert cfg.notion_token == "ntn_from_env"
    assert cfg.hf_token == "hf_from_env"


def test_missing_parent_page_raises(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, '[user]\nname = "Timo"\n[notion]\ntoken = "x"\n')
    with pytest.raises(ValueError, match="parent_page_id"):
        load_config(cfg_path)


def test_a_config_file_named_but_missing_raises(tmp_path: Path):
    with pytest.raises(FileNotFoundError):
        load_config(tmp_path / "nope.toml")


def test_custom_output_dir(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(
        cfg_path,
        f"""
        [user]
        name = "Timo"
        [notion]
        token = "x"
        parent_page_id = "y"
        [recording]
        output_dir = "{tmp_path / "rec"}"
        retention_days = 7
        """,
    )
    cfg = load_config(cfg_path)
    assert cfg.output_dir == tmp_path / "rec"
    assert cfg.retention_days == 7


class TestConfig:
    def test_default_config_path(self):
        from palaver.config import default_config_path

        p = default_config_path()
        assert p.name == "config.toml"
        assert p.parent.name == "palaver"


def test_notion_database_mode(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [notion]
        token = "ntn_test"
        mode = "database"
        database_id = "db-1"
        """)
    cfg = load_config(cfg_path)
    assert cfg.notion_mode == "database"
    assert cfg.notion_database_id == "db-1"


def test_notion_database_mode_requires_database_id(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [notion]
        token = "ntn_test"
        mode = "database"
        """)
    with pytest.raises(ValueError, match="database_id"):
        load_config(cfg_path)


def test_notion_mode_defaults_to_page(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [notion]
        token = "ntn_test"
        parent_page_id = "abc"
        """)
    assert load_config(cfg_path).notion_mode == "page"


def test_tokens_fall_back_to_keychain(tmp_path: Path, monkeypatch):
    """Apps started from Finder/login don't inherit the shell's environment."""
    import keyring

    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    stored = {("palaver", "NOTION_TOKEN"): "ntn_kc", ("palaver", "HF_TOKEN"): "hf_kc"}
    monkeypatch.setattr(keyring, "get_password", lambda service, name: stored.get((service, name)))
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [notion]
        parent_page_id = "abc"
        """)
    cfg = load_config(cfg_path)
    assert cfg.notion_token == "ntn_kc"
    assert cfg.hf_token == "hf_kc"


def test_env_token_wins_over_keychain(tmp_path: Path, monkeypatch):
    import keyring

    monkeypatch.setenv("NOTION_TOKEN", "ntn_env")
    monkeypatch.setattr(keyring, "get_password", lambda *_: "ntn_kc")
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [notion]
        parent_page_id = "abc"
        """)
    assert load_config(cfg_path).notion_token == "ntn_env"


def test_auto_sync_can_be_turned_off(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [notion]
        token = "ntn_test"
        parent_page_id = "abc"
        auto_sync = false
        """)
    assert load_config(cfg_path).notion_auto_sync is False


GEMMA = "mlx-community/gemma-4-12B-it-OptiQ-4bit"


def test_notes_default_to_gemma_but_keep_a_chosen_model(tmp_path: Path):
    from palaver import notes

    assert notes.DEFAULT_LOCAL_MODEL == GEMMA and Config.notes_local_model == GEMMA
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [user]
        name = "Timo"

        [notion]
        token = "ntn_test"
        parent_page_id = "abc"
        """)
    assert load_config(cfg_path).notes_local_model == GEMMA
    _write(cfg_path, """
        [user]
        name = "Timo"

        [notion]
        token = "ntn_test"
        parent_page_id = "abc"

        [notes]
        local_model = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
        """)
    assert load_config(cfg_path).notes_local_model == "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"


def test_the_name_chosen_in_the_app_wins(tmp_path: Path):
    """#55: the setup assistant saves the name in settings.json (the app never rewrites config.toml)."""
    from palaver import settings

    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, '[user]\nname = "Timo"\n[notion]\ntoken = "t"\nparent_page_id = "p"\n')
    assert load_config(cfg_path).user_name == "Timo"
    settings.update({"user_name": "Timo Strauß"})
    assert load_config(cfg_path).user_name == "Timo Strauß"


_BASE = '[notion]\ntoken = "ntn_test"\nparent_page_id = "abc"\n'


def test_memory_budgets_are_read_from_the_memory_table(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, _BASE)
    assert load_config(cfg_path).memory == {}
    _write(cfg_path, _BASE + "[memory]\nlive_gb = 4\nprocess_gb = 16.5\n")
    assert load_config(cfg_path).memory == {"live": 4.0, "process": 16.5}


def test_a_wrong_memory_budget_says_which(tmp_path: Path):
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, _BASE + "[memory]\nlive_gb = 0\n")
    with pytest.raises(ValueError, match="live_gb"):
        load_config(cfg_path)


def _no_tokens(monkeypatch):
    import keyring

    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setattr(keyring, "get_password", lambda service, name: None)


def test_without_a_notion_token_meetings_stay_on_this_mac(tmp_path: Path, monkeypatch):
    _no_tokens(monkeypatch)
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, '[user]\nname = "Timo"\n')
    cfg = load_config(cfg_path)
    assert cfg.notion_token == "" and cfg.notion_auto_sync is False
    assert cfg.hf_token is None


def test_an_installed_palaver_runs_without_a_config_file(tmp_path: Path, monkeypatch, isolated_config_home):
    _no_tokens(monkeypatch)
    cfg = load_config()  # ~/.config/palaver/config.toml was never written
    assert cfg.output_dir == Path.home() / "Meetings" / "Recordings"
    assert cfg.notion_auto_sync is False


def test_the_old_model_repos_are_accepted_and_ignored_with_one_log_line(tmp_path: Path, monkeypatch, caplog):
    from palaver import config as config_module

    _no_tokens(monkeypatch)
    monkeypatch.setattr(config_module, "_ignored_said", False)
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, _BASE + '[model]\ndiarizer_repo = "x/y"\nparakeet_repo = "a/b"\n')
    with caplog.at_level("INFO", logger="palaver.config"):
        cfg = load_config(cfg_path)
        load_config(cfg_path)
    assert not hasattr(cfg, "diarizer_repo") and not hasattr(cfg, "parakeet_repo")
    said = [r for r in caplog.records if "ignored" in r.getMessage()]
    assert len(said) == 1 and "diarizer_repo" in said[0].getMessage() and "parakeet_repo" in said[0].getMessage()


def test_a_config_without_secrets_never_asks_the_keychain(tmp_path: Path, monkeypatch):
    """`palaver app query`/`update` load it often: the Keychain is not read, a token from the
    environment or config.toml still counts."""
    import keyring

    asked = []
    monkeypatch.setattr(keyring, "get_password", lambda service, name: asked.append(name) or "ntn_kc")
    monkeypatch.delenv("NOTION_TOKEN", raising=False)
    monkeypatch.delenv("HF_TOKEN", raising=False)
    cfg_path = tmp_path / "config.toml"
    _write(cfg_path, """
        [notion]
        parent_page_id = "abc"
        """)
    cfg = load_config(cfg_path, secrets=False)
    assert asked == [] and cfg.notion_token == "" and cfg.hf_token is None and cfg.notion_auto_sync is False
    monkeypatch.setenv("NOTION_TOKEN", "ntn_env")
    assert load_config(cfg_path, secrets=False).notion_token == "ntn_env" and asked == []
    assert load_config(cfg_path).notion_token == "ntn_env"
    monkeypatch.delenv("NOTION_TOKEN")
    assert load_config(cfg_path).notion_token == "ntn_kc" and "NOTION_TOKEN" in asked
