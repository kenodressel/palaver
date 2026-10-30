"""When reopening the Meetings window loads the page again (no window server needed)."""

from palaver.webapp.window import needs_load

BASE = "http://127.0.0.1:8765/"


def test_a_new_window_loads():
    assert needs_load(None, BASE)


def test_reopening_from_the_menu_bar_keeps_the_page_and_its_history():
    # The menu bar passes the bare address; the page is somewhere under it.
    assert not needs_load(BASE + "#/people", BASE)
    assert not needs_load(BASE + "#/2026-10-21T16-29-29", BASE)
    assert not needs_load(BASE, BASE)


def test_a_notification_opens_its_meeting():
    assert needs_load(BASE + "#/people", BASE + "#/2026-10-21T16-29-29")
    assert not needs_load(BASE + "#/2026-10-21T16-29-29", BASE + "#/2026-10-21T16-29-29")


def test_another_server_loads():
    assert needs_load("http://127.0.0.1:9999/#/people", BASE)


def test_a_restarted_server_reloads_its_own_page_only():
    from palaver.webapp.window import reloads_after_restart

    assert reloads_after_restart(BASE + "#/people", BASE)
    assert reloads_after_restart(BASE, BASE)
    assert not reloads_after_restart(None, BASE)  # nothing loaded yet: the next open loads it
    assert not reloads_after_restart("http://127.0.0.1:9999/#/people", BASE)
    assert not reloads_after_restart("about:blank", BASE)
