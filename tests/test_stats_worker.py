"""Runs the usage numbers' Worker tests (stats/, #6) with node: node:sqlite stands in for Cloudflare's D1."""

import shutil
import subprocess
from pathlib import Path

import pytest

STATS = Path(__file__).resolve().parent.parent / "stats"


def _has_sqlite() -> bool:
    probe = subprocess.run(["node", "-e", "require('node:sqlite')"], capture_output=True, text=True, timeout=30)
    return probe.returncode == 0


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_the_worker_tests_pass():
    if not _has_sqlite():
        pytest.skip("this node has no node:sqlite (22.5 or later has)")
    # In the folder: its package.json makes src/index.js an ES module, and `node --test` finds test/*.test.js.
    result = subprocess.run(["node", "--test"], cwd=STATS, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
