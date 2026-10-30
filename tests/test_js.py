"""Runs the page's JavaScript unit tests (tests/js/) with node."""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.mark.skipif(shutil.which("node") is None, reason="node is not installed")
def test_node_tests_pass():
    # node expands the glob itself; a bare directory is taken for a module.
    result = subprocess.run(
        ["node", "--test", "tests/js/*.test.mjs"],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_no_confirm_or_alert_left():
    # Changes are undone, not confirmed; errors go to a toast or in place.
    calls = re.compile(r"(?<![\w.])(confirm|alert)\(")
    found = []
    for name in ("app.js", "ui.js", "mynotes.js"):
        text = (ROOT / "palaver" / "webapp" / "static" / name).read_text()
        found += [f"{name}:{text.count(chr(10), 0, m.start()) + 1}: {m.group(0)}" for m in calls.finditer(text)]
    assert not found, "\n".join(found)


def test_elements_hidden_in_the_page_stay_hidden():
    # A class rule with `display: flex` beats the `hidden` attribute: each
    # element the page hides by attribute needs a `[hidden]` rule too.
    static = ROOT / "palaver" / "webapp" / "static"
    css = re.sub(r"/\*.*?\*/", "", (static / "app.css").read_text(), flags=re.S)
    rules = [(sel.strip(), body) for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css)]
    page = (static / "index.html").read_text()
    missing = []
    for tag in re.findall(r"<[a-z]+[^>]*\bhidden\b[^>]*>", page):
        cls = re.search(r'class="([^"]+)"', tag)
        if not cls:
            continue
        name = cls.group(1).split()[0]
        shows = any(f".{name}" in [x.strip() for x in sel.split(",")] and re.search(r"display:\s*(?!none)", body)
                    for sel, body in rules)
        hides = any(f".{name}[hidden]" in [x.strip() for x in sel.split(",")] and re.search(r"display:\s*none", body)
                    for sel, body in rules)
        if shows and not hides:
            missing.append(name)
    assert not missing, f"add .X[hidden] {{ display: none; }} for: {missing}"
