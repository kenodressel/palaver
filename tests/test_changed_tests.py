"""tools/changed_tests.py: which tests `make test-changed` runs for what changed."""
from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("changed_tests", ROOT / "tools" / "changed_tests.py")
changed_tests = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(changed_tests)


def test_the_swift_programs_run_the_end_to_end_tests():
    picked = changed_tests.select({"native/Sources/PalaverServer/ServerApp.swift"})
    assert "tests/e2e" in picked and "tests/test_worker_helpers.py" in picked


def test_the_page_runs_the_window_and_js_tests():
    assert changed_tests.select({"web/app.js"}) == {"tests/e2e", "tests/test_js.py", "tests/test_css_scale.py"}
    assert changed_tests.select({"tests/js/exchange.test.mjs"}) == {"tests/test_js.py"}


def test_a_test_runs_itself_and_one_in_e2e_is_the_folder():
    assert changed_tests.select({"tests/test_release.py"}) == {"tests/test_release.py"}
    assert changed_tests.select({"tests/e2e/test_setup.py", "tests/e2e/fake_app.py"}) == {"tests/e2e"}


def test_install_sh_tools_and_shared_setup():
    assert changed_tests.select({"install.sh"}) >= {"tests/test_install_sh.py"}
    assert changed_tests.select({"tools/build_release.py"}) >= {"tests/test_release_compat.py"}
    assert changed_tests.select({"pyproject.toml", "web/app.js"}) == {"tests"}
    assert changed_tests.select({"README.md"}) == set()
