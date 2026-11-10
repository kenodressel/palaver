"""tools/memcap.sh: the cap every model run goes under. It adds up the memory footprint (phys_footprint, which counts
MLX's GPU buffers that resident memory misses) of the command's processes and kills them above the cap."""

import subprocess
import sys
from pathlib import Path

MEMCAP = Path(__file__).resolve().parent.parent / "tools" / "memcap.sh"


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["sh", str(MEMCAP), *args], capture_output=True, text=True, timeout=60)


def test_under_the_cap_the_commands_exit_status_is_memcaps():
    done = run("1", "sh", "-c", "echo hi; exit 3")
    assert done.returncode == 3 and done.stdout == "hi\n" and done.stderr == ""


def test_above_the_cap_the_command_is_killed_and_memcap_says_so():
    # 300 MB written (counted in the footprint), against a cap of 0.1 GB.
    done = run("0.1", sys.executable, "-c", "x = b'x' * (300 << 20); import time; time.sleep(20)")
    assert done.returncode == 137
    assert "more than the cap of 0.1 GB: killed" in done.stderr and "RSS" not in done.stderr


def test_a_child_that_leaves_the_group_is_counted_too():
    script = ("import subprocess, sys, time; "
              "subprocess.Popen([sys.executable, '-c', \"x = b'x' * (300 << 20); import time; time.sleep(20)\"], "
              "start_new_session=True); time.sleep(20)")
    done = run("0.1", sys.executable, "-c", script)
    assert done.returncode == 137


def test_a_bad_cap_is_a_usage_error():
    for cap in ("", "x", "1.2.3", "."):
        assert run(cap, "true").returncode == 2
