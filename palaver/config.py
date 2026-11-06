"""Config loader. Reads TOML, resolves env-var overrides, validates."""

from __future__ import annotations

import logging
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from ._xdg import xdg_config_home
from .memory import parse_budgets


@dataclass(frozen=True)
class Config:
    user_name: str
    notion_token: str  # "": Notion is not used
    notion_parent_page_id: str | None
    hf_token: str | None
    output_dir: Path
    retention_days: int
    max_session_hours: int
    grace_period_seconds: int
    transcriber: str
    whisper_repo: str
    language: str
    # "page": child page under parent_page_id; "database": row in database_id.
    notion_mode: str = "page"
    notion_database_id: str | None = None
    # Transcribe while recording, so little is left to do after the call.
    live_processing: bool = True
    # Record Slack huddles too, like Teams calls.
    record_slack: bool = True
    # Upload each recording after the call; off: transcribe locally only.
    notion_auto_sync: bool = True
    # Notes (summary, topics, next steps): "local" (MLX model on this Mac) or
    # "claude" (Claude Code CLI, sends the transcript to Anthropic).
    notes_enabled: bool = True
    notes_engine: str = "local"
    notes_local_model: str = "mlx-community/gemma-4-12B-it-OptiQ-4bit"
    notes_model: str = "sonnet"
    claude_path: str | None = None
    # Match recordings to events in the macOS calendar (title, invitees).
    calendar_enabled: bool = True
    # Memory budgets per worker, in GB ([memory] live_gb, stream_gb,
    # process_gb, notes_gb), parsed once here; see memory.py (#49).
    memory: dict = field(default_factory=dict)


KEYCHAIN_SERVICE = "palaver"
OLD_KEYCHAIN_SERVICE = "meeting-transcribe"  # tokens stored under the app's old name


def _token(env_name: str, configured: str | None, *, keychain: bool = True) -> str | None:
    """Environment, then config.toml, then the macOS Keychain — apps started
    from Finder or at login don't see the shell's environment. ``keychain``
    False: never the Keychain (each read can be a prompt)."""
    value = os.environ.get(env_name) or configured
    if value:
        return value
    if not keychain:
        return None
    try:
        import keyring

        return (keyring.get_password(KEYCHAIN_SERVICE, env_name)
                or keyring.get_password(OLD_KEYCHAIN_SERVICE, env_name))
    except Exception:
        return None


_IGNORED_REPOS = ("diarizer_repo", "parakeet_repo")
_ignored_said = False


def _note_ignored_repos(model: dict) -> None:
    """``[model].diarizer_repo`` and ``parakeet_repo`` named Hugging Face
    repos for the old speech models. The engine has its own; the keys are
    accepted and ignored, said once per process."""
    global _ignored_said
    found = [k for k in _IGNORED_REPOS if k in model]
    if found and not _ignored_said:
        _ignored_said = True
        logging.getLogger(__name__).info(
            "config.toml [model] %s ignored: speech and speakers come from the engine's own models",
            " and ".join(found))


def _notes_engine(value: str) -> str:
    if value not in ("local", "claude"):
        raise ValueError('[notes].engine must be "local" or "claude"')
    return value


def default_config_path() -> Path:
    """Location of the user-facing TOML config."""
    return xdg_config_home() / "palaver" / "config.toml"


def load_config(path: Path | None = None, *, secrets: bool = True) -> Config:
    """config.toml, or the defaults without one: an installed Palaver runs
    without a config file (#60); Notion is used only with a token.
    ``secrets`` False: the tokens only from the environment or config.toml,
    never the Keychain — for the app's frequent questions, which need none
    (each Keychain read can be a prompt for palaver-python)."""
    path = path or default_config_path()
    if path.exists():
        with path.open("rb") as fh:
            data = tomllib.load(fh)
    elif path != default_config_path():  # one asked for by name must be there
        raise FileNotFoundError(f"Config file not found: {path}")
    else:
        data = {}

    user = data.get("user", {})
    notion = data.get("notion", {})
    hf = data.get("hf", {})
    recording = data.get("recording", {})
    model = data.get("model", {})
    _note_ignored_repos(model)
    processing = data.get("processing", {})
    notes = data.get("notes", {})

    # Notion is optional: without a token meetings stay on this Mac.
    notion_token = _token("NOTION_TOKEN", notion.get("token"), keychain=secrets) or ""
    notion_mode = notion.get("mode", "page")
    if notion_mode not in ("page", "database"):
        raise ValueError('[notion].mode must be "page" or "database"')
    parent_page_id = notion.get("parent_page_id")
    database_id = notion.get("database_id")
    if notion_token and notion_mode == "page" and not parent_page_id:
        raise ValueError("[notion].parent_page_id is required")
    if notion_token and notion_mode == "database" and not database_id:
        raise ValueError('[notion].database_id is required when mode = "database"')

    hf_token = _token("HF_TOKEN", hf.get("token"), keychain=secrets)

    output_dir_str = recording.get("output_dir", "~/Meetings/Recordings")
    output_dir = Path(output_dir_str).expanduser()

    from .settings import user_name as chosen_name

    return Config(
        user_name=chosen_name() or user.get("name", "User"),
        notion_token=notion_token,
        notion_parent_page_id=parent_page_id,
        hf_token=hf_token,
        output_dir=output_dir,
        retention_days=int(recording.get("retention_days", 14)),
        max_session_hours=int(recording.get("max_session_hours", 4)),
        grace_period_seconds=int(recording.get("grace_period_seconds", 10)),
        transcriber=model.get("transcriber", "parakeet"),
        whisper_repo=model.get("whisper_repo", "mlx-community/whisper-large-v3-turbo"),
        language=model.get("language", "auto"),
        notion_mode=notion_mode,
        notion_database_id=database_id,
        live_processing=bool(processing.get("live", True)),
        record_slack=bool(data.get("recording", {}).get("slack", True)),
        notion_auto_sync=bool(notion_token) and bool(notion.get("auto_sync", True)),
        notes_enabled=bool(notes.get("enabled", True)),
        notes_engine=_notes_engine(notes.get("engine", "local")),
        notes_local_model=str(notes.get("local_model", Config.notes_local_model)),
        notes_model=str(notes.get("model", "sonnet")),
        claude_path=notes.get("claude"),
        calendar_enabled=bool(data.get("calendar", {}).get("enabled", True)),
        memory=parse_budgets(data.get("memory", {})),
    )
