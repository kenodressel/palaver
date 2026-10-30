"""The page guard itself: a test whose page reported a problem fails, however
late the page reported it. Each case runs a small test in a pytester session
and asserts on its outcome."""

import os
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.e2e

CONFTEST = "from tests.e2e.conftest import browser, page, pytest_runtest_call  # noqa: F401\n"


# Playwright looks for its browsers under HOME, which pytester changes.
_HOME = Path.home()
_BROWSERS = os.environ.get("PLAYWRIGHT_BROWSERS_PATH") or str(
    _HOME / ("Library/Caches/ms-playwright" if sys.platform == "darwin" else ".cache/ms-playwright"))


def _run(pytester, monkeypatch, body: str):
    monkeypatch.setenv("PLAYWRIGHT_BROWSERS_PATH", _BROWSERS)
    pytester.makeconftest(CONFTEST)
    pytester.makepyfile(f"import time\n\n{body}")
    return pytester.runpytest_inprocess("-rs", "-p", "no:cacheprovider", "-m", "e2e or not e2e")


def test_a_console_error_fails_the_test(pytester, monkeypatch):
    result = _run(pytester, monkeypatch, '''
def test_it(page):
    page.set_content("<script>console.error('deliberate')</script>")
''')
    result.assert_outcomes(failed=1)
    result.stdout.fnmatch_lines(["*the page reported:*", "*console.error: deliberate*"])


def test_a_late_console_error_fails_the_test(pytester, monkeypatch):
    """Dispatched after the test's last Playwright call, while Python sleeps."""
    result = _run(pytester, monkeypatch, '''
def test_it(page):
    page.set_content("<script>setTimeout(() => console.error('late one'), 50)</script>")
    time.sleep(0.5)
''')
    result.assert_outcomes(failed=1)
    result.stdout.fnmatch_lines(["*console.error: late one*"])


def test_a_late_page_error_fails_the_test(pytester, monkeypatch):
    result = _run(pytester, monkeypatch, '''
def test_it(page):
    page.set_content("<script>setTimeout(() => { throw new Error('late throw'); }, 50)</script>")
    time.sleep(0.5)
''')
    result.assert_outcomes(failed=1)
    result.stdout.fnmatch_lines(["*page error:*late throw*"])


def test_an_allowed_error_and_a_quiet_page_pass(pytester, monkeypatch):
    result = _run(pytester, monkeypatch, '''
def test_quiet(page):
    page.set_content("<p>fine</p>")
    time.sleep(0.2)

def test_allowed(page):
    page.guard.allow("expected")
    page.set_content("<script>setTimeout(() => console.error('expected'), 50)</script>")
    time.sleep(0.3)
''')
    result.assert_outcomes(passed=2)
