"""Tests for where an installed Palaver keeps its layers (#60)."""

from palaver import install_layout


def test_the_hosts_python_variables_are_not_handed_to_other_programs():
    """The app's host sets PYTHONHOME and PYTHONPATH for itself; a program
    Palaver starts (claude, osascript, another Python) must not get them.
    Palaver's own helpers are the host again, which sets them anew."""
    env = {"PALAVER_APP": "/A/Palaver.app", "PYTHONHOME": "/rt", "PYTHONPATH": "/A/code", "PATH": "/usr/bin"}
    install_layout.clean_environment(env)
    assert env == {"PALAVER_APP": "/A/Palaver.app", "PATH": "/usr/bin"}
    checkout = {"PYTHONPATH": "/mine", "PATH": "/usr/bin"}
    install_layout.clean_environment(checkout)
    assert checkout == {"PYTHONPATH": "/mine", "PATH": "/usr/bin"}  # a checkout's are the user's own
