"""tools/changed_tests.py: which tests `make test` runs for what changed."""
from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("changed_tests", ROOT / "tools" / "changed_tests.py")
changed_tests = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(changed_tests)


def test_the_window_s_server_runs_the_end_to_end_tests_and_the_worker_its_own():
    assert changed_tests.select({"native/Sources/PalaverServer/ServerApp.swift"}) == {"tests/e2e"}
    assert changed_tests.select({"native/Sources/PalaverWorker/Stream.swift"}) == {"tests/test_worker_helpers.py"}
    assert changed_tests.select({"native/Sources/PalaverCapture/AVMic.swift"}) == set()


def test_a_file_of_the_server_that_serves_one_area_runs_that_area_s_e2e_tests():
    assert changed_tests.select({"native/Sources/PalaverServer/API/MyNotesRoutes.swift"}) == {"tests/e2e/test_my_notes.py"}
    assert changed_tests.select({"native/Sources/PalaverServer/Setup/Probe.swift"}) == {"tests/e2e/test_setup.py"}
    assert changed_tests.select({"native/Sources/PalaverServer/CLI/CLIMain.swift"}) == set()
    assert changed_tests.select({"native/Sources/PalaverServer/API/Meetings.swift"}) == {"tests/e2e"}
    assert "tests/e2e" in changed_tests.select({"native/Sources/PalaverDomain/Files/Storage.swift"})


def test_the_page_runs_its_own_tests_and_the_e2e_tests_of_its_area():
    assert changed_tests.select({"web/app.js"}) == {"tests/e2e", "tests/test_js.py", "tests/test_css_scale.py"}
    assert changed_tests.select({"web/mynotes.js"}) == {"tests/e2e/test_my_notes.py", "tests/test_js.py",
                                                         "tests/test_css_scale.py"}
    assert changed_tests.select({"tests/js/exchange.test.mjs"}) == {"tests/test_js.py"}


def test_a_test_runs_itself_and_an_e2e_helper_the_folder():
    assert changed_tests.select({"tests/test_release.py"}) == {"tests/test_release.py"}
    assert changed_tests.select({"tests/e2e/test_setup.py"}) == {"tests/e2e/test_setup.py"}
    assert changed_tests.select({"tests/e2e/test_setup.py", "tests/e2e/fake_app.py"}) == {"tests/e2e"}


def test_install_sh_tools_and_shared_setup():
    assert changed_tests.select({"install.sh"}) >= {"tests/test_install_sh.py"}
    assert changed_tests.select({"tools/build_release.py"}) >= {"tests/test_release_compat.py"}
    assert changed_tests.select({"pyproject.toml", "web/app.js"}) == {"tests"}
    assert changed_tests.select({"README.md"}) == set()


def test_a_swift_target_runs_the_bundles_built_from_it_or_starting_its_programs():
    sel = changed_tests.select_swift
    assert sel({"native/Sources/PalaverCapture/AVMic.swift"}) == {"PalaverCaptureTests": None, "PalaverDaemonTests": None}
    assert set(sel({"native/Sources/PalaverServer/ServerApp.swift"})) == {"PalaverServerTests", "PalaverDaemonTests"}
    assert set(sel({"native/Sources/PalaverLM/Prompt.swift"})) == {"PalaverLMTests", "PalaverMLXTests"}
    assert len(sel({"native/Sources/PalaverCore/Paths.swift"})) >= 9  # everything is built from it
    assert sel({"web/app.js", "README.md"}) == {}


def test_a_swift_test_file_runs_its_suites_and_a_helper_its_bundle():
    sel = changed_tests.select_swift
    assert sel({"native/Tests/PalaverServerTests/ReviewSpeedTests.swift"}) == {"PalaverServerTests": ["ReviewSpeedTests"]}
    assert sel({"native/Tests/PalaverServerTests/ReviewSpeedTests.swift",
                "native/Tests/PalaverServerTests/ServerTestSupport.swift"}) == {"PalaverServerTests": None}
    assert sel({"native/Tests/PalaverServerTests/ReviewSpeedTests.swift",
                "native/Sources/PalaverServer/ServerApp.swift"})["PalaverServerTests"] is None
    assert len(sel({"native/Package.swift"})) == len(changed_tests.bundles())
