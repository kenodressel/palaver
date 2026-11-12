"""The tests for what changed since master (committed on this branch, staged, unstaged or new): what `make test`
runs. `make test-all` runs everything.

    tools/changed_tests.py            the Python tests, one path per line (nothing printed: none to run)
    tools/changed_tests.py --swift    the Swift test bundles, one per line, with its suites when only some of its
                                      tests changed ("PalaverServerTests=SearchRoutesTests,ReviewSpeedTests")
    --base REF                        compare with REF instead of master

Python:
- a test file runs itself; a helper of the end-to-end tests runs them (tests/e2e);
- the window's page (web/) runs the page's own tests (tests/js through tests/test_js.py, tests/test_css_scale.py) and
  the end-to-end tests of its area: a file of one page (my notes, the exchange) its file, the stylesheet and the fonts
  the page tour (test_pages.py), anything else all of tests/e2e;
- a file of the window's server that serves one area of the window runs the e2e tests of that area
  (SERVER_AREAS); any other Swift target palaver-server or palaver-lm is built from runs tests/e2e, one
  palaver-worker is built from the test that starts palaver-worker (PY_STARTED_BY);
- install.sh, a tool or a fixture runs the tests that name it;
- anything else that tests depend on (pyproject.toml, uv.lock, conftest.py, the Makefile) runs everything: "tests".

Swift (native/Package.swift's targets):
- a source file of a target runs every test bundle that depends on it, directly or through others, and the bundles
  that start a program built from it (STARTED_BY);
- a test file runs its bundle: only the suites it declares when every changed file of that bundle declares suites,
  the whole bundle when a shared helper changed;
- native/Package.swift, Package.resolved, the Makefile or the test tooling run every bundle.
"""
from __future__ import annotations

import functools
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
EVERYTHING = {"pyproject.toml", "uv.lock", "Makefile", "tests/conftest.py", "tests/e2e/conftest.py"}
SWIFT_EVERYTHING = {"native/Package.swift", "native/Package.resolved", "Makefile", "tools/changed_tests.py",
                    "tools/swift_tests_parallel.sh"}
# The page's files that belong to one area of the window, and the end-to-end tests of that area.
WEB_AREAS = {
    "web/mynotes.js": {"tests/e2e/test_my_notes.py"},
    "web/mynotes-logic.js": {"tests/e2e/test_my_notes.py"},
    "web/exchange.js": {"tests/e2e/test_exchange.py"},
    "web/app.css": {"tests/e2e/test_pages.py"},
}
E2E_PROGRAMS = {"palaver-server", "palaver-lm"}
# The window's server's files that serve one area of the window, and the e2e tests of that area (the longest
# prefix wins). Any other file of the server, or of a target it is built from, runs all of tests/e2e.
SERVER = "native/Sources/PalaverServer/"
SERVER_AREAS = {
    "CLI/": set(),  # palaver-cli's commands: the Swift tests', not the window's
    "Mcp/": {"tests/e2e/test_mcp.py"},
    "API/Mcp.swift": {"tests/e2e/test_mcp.py", "tests/e2e/test_setup.py"},
    "Report/": {"tests/e2e/test_report.py"},
    "Setup/": {"tests/e2e/test_setup.py"},
    "Doctor/": {"tests/e2e/test_setup.py"},
    "API/Setup.swift": {"tests/e2e/test_setup.py"},
    "API/Providers.swift": {"tests/e2e/test_setup.py", "tests/e2e/test_pages.py"},
    "API/ExchangeRoutes.swift": {"tests/e2e/test_exchange.py"},
    "API/MyNotesRoutes.swift": {"tests/e2e/test_my_notes.py"},
    "API/NextQuestion.swift": {"tests/e2e/test_live_coach.py"},
    "API/LivePage.swift": {"tests/e2e/test_live_coach.py", "tests/e2e/test_my_notes.py", "tests/e2e/test_today.py"},
    "API/Glossary.swift": {"tests/e2e/test_stores.py", "tests/e2e/test_transcript.py"},
    "API/Projects.swift": {"tests/e2e/test_stores.py", "tests/e2e/test_attribution.py"},
    "API/People.swift": {"tests/e2e/test_speakers.py", "tests/e2e/test_stores.py", "tests/e2e/test_line_speaker.py"},
}
# The bundles whose tests start a built program (native/.build/debug/<program>), and the Python tests that do.
STARTED_BY = {"palaver-server": {"PalaverServerTests", "PalaverDaemonTests"}, "palaver-cli": {"PalaverServerTests"},
              "palaver-lm": {"PalaverLMTests"}}
PY_STARTED_BY = {"palaver-worker": {"tests/test_worker_helpers.py"}}


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


# --- the package's targets ----------------------------------------------------------------------------------------

@functools.cache
def targets() -> dict[str, dict]:
    """name -> {"type": regular|executable|test, "deps": {target names}} from `swift package dump-package`."""
    out = subprocess.run(["swift", "package", "--package-path", str(NATIVE), "dump-package"], capture_output=True,
                         text=True, check=True).stdout
    found = {}
    for t in json.loads(out)["targets"]:
        deps = set()
        for d in t["dependencies"]:
            for kind in ("byName", "target"):
                if kind in d:
                    deps.add(d[kind][0])
        found[t["name"]] = {"type": t["type"], "deps": deps}
    return found


def closure(name: str) -> set[str]:
    """`name` and every target it is built from."""
    seen, todo = set(), [name]
    while todo:
        n = todo.pop()
        if n in seen or n not in targets():
            continue
        seen.add(n)
        todo.extend(targets()[n]["deps"])
    return seen


def bundles() -> list[str]:
    return sorted(n for n, t in targets().items() if t["type"] == "test")


def programs() -> list[str]:
    return sorted(n for n, t in targets().items() if t["type"] == "executable")


def programs_of(target: str) -> set[str]:
    return {p for p in programs() if target in closure(p)}


def users_of(target: str) -> set[str]:
    """The test bundles a change to `target` can break: those built from it, and those that start a program built
    from it."""
    out = {b for b in bundles() if target in closure(b)}
    for program in programs_of(target):
        out |= STARTED_BY.get(program, set())
    return out


def suites(path: Path) -> list[str] | None:
    """The suites (and free test functions) a test file declares, or None when it declares none (a helper)."""
    text = path.read_text(errors="replace") if path.exists() else ""
    names = re.findall(r"^@Suite[^\n]*?(?:struct|final class|class|enum|actor)\s+(\w+)", text, re.M)
    names += re.findall(r"^(?:struct|final class|class|enum|actor)\s+(\w+Tests)\b", text, re.M)
    names += re.findall(r"^@Test[^\n]*?func\s+(\w+)", text, re.M)
    return sorted(set(names)) or None


# --- what to run ----------------------------------------------------------------------------------------------------

def select(paths: set[str]) -> set[str]:
    """The Python tests to run for `paths`."""
    tests = test_files()
    out: set[str] = set()
    for path in paths:
        p = Path(path)
        if path in EVERYTHING:
            return {"tests"}
        if path.startswith("tests/e2e/") and p.suffix == ".py":
            if p.name.startswith("test_"):
                if (ROOT / path).exists():
                    out.add(path)
            else:
                out.add("tests/e2e")
        elif path.startswith("tests/") and p.name.startswith("test_") and p.suffix == ".py":
            if (ROOT / path).exists():
                out.add(path)
        elif path.startswith("web/"):
            out |= {"tests/test_js.py", "tests/test_css_scale.py"}
            out |= WEB_AREAS.get(path, {"tests/e2e/test_pages.py"} if path.startswith("web/fonts/") else {"tests/e2e"})
        elif path.startswith("tests/js/"):
            out.add("tests/test_js.py")
        elif path.startswith(SERVER):
            area = [k for k in SERVER_AREAS if path[len(SERVER):].startswith(k)]
            out |= SERVER_AREAS[max(area, key=len)] if area else {"tests/e2e"}
        elif path.startswith("native/Sources/") and len(p.parts) > 3:
            built = programs_of(p.parts[2])
            if built & E2E_PROGRAMS:
                out.add("tests/e2e")
            for program in built:
                out |= PY_STARTED_BY.get(program, set())
        elif path in {"native/Package.swift", "native/Package.resolved"}:
            out |= {"tests/e2e", *PY_STARTED_BY["palaver-worker"]}
        elif path == "install.sh" or path.startswith(("tools/", "tests/fixtures/")):
            out |= mentions(p.name if path.startswith("tools/") or path == "install.sh" else p.parts[2], tests)
    if "tests/e2e" in out:  # the folder covers its files
        out = {t for t in out if not t.startswith("tests/e2e/")} | {"tests/e2e"}
    return out


def select_swift(paths: set[str]) -> dict[str, list[str] | None]:
    """The Swift bundles to run for `paths`: bundle -> the suites to run, or None for all of it."""
    whole: set[str] = set()
    some: dict[str, set[str]] = {}
    for path in paths:
        p = Path(path)
        if path in SWIFT_EVERYTHING:
            return {b: None for b in bundles()}
        if path.startswith("native/Sources/") and len(p.parts) > 3:
            whole |= users_of(p.parts[2])
        elif path.startswith("native/Tests/") and len(p.parts) > 3 and p.parts[2] in targets():
            bundle = p.parts[2]
            names = suites(ROOT / path) if p.suffix == ".swift" else None
            if names is None:
                whole.add(bundle)
            else:
                some.setdefault(bundle, set()).update(names)
    return {**{b: sorted(n) for b, n in some.items() if b not in whole}, **{b: None for b in whole}}


def main(argv: list[str]) -> int:
    base = argv[argv.index("--base") + 1] if "--base" in argv else "master"
    paths = changed(base)
    if "--swift" in argv:
        for bundle, names in sorted(select_swift(paths).items()):
            print(bundle + ("=" + ",".join(names) if names else ""))
    else:
        for test in sorted(select(paths)):
            print(test)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
