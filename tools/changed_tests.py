"""The Python tests for what changed since master (committed on this branch, staged,
unstaged or new): printed for `make test-changed`, one path per line. The Swift
tests are `make swift-test FILTER=…` (or `make engine-test` for all).

- a test file runs itself; a helper of the end-to-end tests runs them (tests/e2e);
- the window's page (web/) runs the window's tests (tests/e2e) and the page's own
  (tests/js through tests/test_js.py, tests/test_css_scale.py);
- the Swift programs (native/) run the end-to-end tests, which drive palaver-server
  and palaver-lm, and the tests that start palaver-worker;
- install.sh, a tool or a fixture runs the tests that name it;
- anything else that tests depend on (pyproject.toml, uv.lock, conftest.py,
  the Makefile) runs everything: "tests".

Nothing printed: nothing to run.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVERYTHING = {"pyproject.toml", "uv.lock", "Makefile", "tests/conftest.py", "tests/e2e/conftest.py"}


def changed(base: str = "master") -> set[str]:
    def git(*args: str) -> list[str]:
        out = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=False).stdout
        return [line for line in out.splitlines() if line]

    return {*git("diff", "--name-only", f"{base}...HEAD"), *git("diff", "--name-only", "HEAD"),
            *git("ls-files", "--others", "--exclude-standard")}


def test_files() -> list[Path]:
    return sorted(p for p in (ROOT / "tests").rglob("test_*.py"))


def mentions(word: str, tests: list[Path]) -> set[str]:
    return {str(t.relative_to(ROOT)) for t in tests if word in t.read_text(errors="replace")}


def select(paths: set[str]) -> set[str]:
    tests = test_files()
    out: set[str] = set()
    for path in paths:
        p = Path(path)
        if path in EVERYTHING:
            return {"tests"}
        if path.startswith("tests/e2e/") and p.suffix == ".py":
            out.add("tests/e2e")
        elif path.startswith("tests/") and p.name.startswith("test_") and p.suffix == ".py":
            if (ROOT / path).exists():
                out.add(path)
        elif path.startswith("web/"):
            out |= {"tests/e2e", "tests/test_js.py", "tests/test_css_scale.py"}
        elif path.startswith("tests/js/"):
            out.add("tests/test_js.py")
        elif path.startswith("native/Sources/"):
            out |= {"tests/e2e"} | mentions("palaver-worker", tests)
        elif path == "install.sh" or path.startswith(("tools/", "tests/fixtures/")):
            out |= mentions(p.name if path.startswith("tools/") or path == "install.sh" else p.parts[2], tests)
    if "tests/e2e" in out:  # the folder covers its files
        out = {t for t in out if not t.startswith("tests/e2e/")} | {"tests/e2e"}
    return out


def main(argv: list[str]) -> int:
    base = argv[0] if argv else "master"
    for test in sorted(select(changed(base))):
        print(test)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
