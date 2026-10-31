"""tools/changed_tests.py: which tests `make test-changed` runs for what changed."""
from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("changed_tests", ROOT / "tools" / "changed_tests.py")
changed_tests = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(changed_tests)


def test_a_module_runs_the_tests_that_import_it():
    picked = changed_tests.select({"palaver/model_jobs.py"})
    assert "tests/test_model_jobs.py" in picked
    assert "tests/test_exchange.py" not in picked


def test_a_module_imported_from_its_package_counts():
    picked = changed_tests.select({"palaver/onboarding.py"})  # from palaver import onboarding as ob
    assert {"tests/test_onboarding.py", "tests/test_setup_api.py"} <= picked


def test_the_page_runs_the_window_and_js_tests():
    assert changed_tests.select({"palaver/webapp/static/app.js"}) == {"tests/e2e", "tests/test_js.py"}
    assert changed_tests.select({"tests/js/exchange.test.mjs"}) == {"tests/test_js.py"}


def test_a_test_runs_itself_and_one_in_e2e_is_the_folder():
    assert changed_tests.select({"tests/test_needs.py"}) == {"tests/test_needs.py"}
    assert changed_tests.select({"tests/e2e/test_setup.py", "palaver/webapp/static/app.css"}) == {
        "tests/e2e", "tests/test_js.py"}


def test_install_sh_and_shared_setup():
    assert changed_tests.select({"install.sh"}) >= {"tests/test_install_sh.py"}
    assert changed_tests.select({"pyproject.toml", "palaver/notes.py"}) == {"tests"}
    assert changed_tests.select({"README.md"}) == set()
