"""What the release runtime installs: the locked set `build_release.py
requirements` exports (the same call `make runtime` builds from)."""

import importlib.util
import shutil
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("build_release", ROOT / "tools" / "build_release.py")
build_release = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build_release)


def _installed(text: str) -> list[str]:
    """The package names pip would install: lines whose marker never holds
    (the override that keeps mlx-whisper's unused torch out) do not count."""
    names = []
    for line in text.splitlines():
        line = line.split("#")[0].strip()
        if not line or "sys_platform == 'never'" in line:
            continue
        names.append(line.split("==")[0].split(";")[0].strip().lower())
    return names


@pytest.mark.skipif(shutil.which("uv") is None, reason="uv is not installed")
def test_runtime_has_no_torch(tmp_path: Path):
    names = _installed(build_release.requirements(tmp_path))
    assert names, "the export is empty"
    banned = [n for n in names if n.startswith(("torch", "pyannote", "parakeet"))]
    assert banned == []
    assert "mlx-whisper" in names and "mlx-lm" in names  # MLX stays: Whisper and the notes model
