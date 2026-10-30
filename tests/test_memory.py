"""Memory budgets per worker (issue #49): what a process costs, measured as
macOS counts it, and what the watchdog does when a worker passes its budget."""

import os
from pathlib import Path

import pytest

from palaver import memory
from palaver.memory import GB, Budgets, Watchdog


def test_footprint_of_this_process_is_its_phys_footprint():
    used = memory.footprint(os.getpid())
    assert used is not None and used > 10 * 2**20  # a Python with numpy loaded
    assert memory.footprint(2**22 + 12345) is None  # no such process


def test_tree_footprint_adds_the_children():
    sizes = {1: 100, 2: 20, 3: 3, 4: 4000}
    kids = {1: [2], 2: [3], 3: [], 4: []}
    assert memory.tree_footprint(1, sample=sizes.get, children=kids.get) == 123
    assert memory.tree_footprint(9, sample=sizes.get, children=kids.get) is None
    # A child that exited in between counts nothing (its own children went to launchd).
    assert memory.tree_footprint(1, sample=lambda pid: None if pid == 2 else sizes[pid], children=kids.get) == 100


def test_children_of_this_process_lists_a_started_child():
    import subprocess
    import sys

    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(5)"])
    try:
        assert child.pid in memory.children(os.getpid())
    finally:
        child.kill()
        child.wait()


@pytest.mark.parametrize("used, text", [(5.44 * GB, "5.4 GB"), (0.31 * GB, "317 MB"), (12 * GB, "12 GB"),
                                        (None, "—")])
def test_size_text(used, text):
    assert memory.size_text(used) == text


def test_cost_text_is_the_status_line_part():
    assert memory.cost_text({"total": int(5.4 * GB)}) == "Palaver 5.4 GB"
    assert memory.cost_text({"total": None}) is None
    assert memory.cost_text(None) is None


def _cfg(memory_table=None, *, sync=False, engine="local", model="mlx-community/gemma-4-12B-it-OptiQ-4bit"):
    """A config as load_config makes it: ``memory`` holds the parsed table."""
    class Cfg:
        memory = memory_table or {}
        notes_engine, notes_local_model, notion_auto_sync, notes_enabled = engine, model, sync, True
        notes_model, claude_path = "sonnet", None
    return Cfg()


def test_budgets_from_config_with_defaults_and_overrides():
    b = memory.budgets_for(_cfg({"live": 4.0, "process": 9.0}, model="some/unknown-model"))
    assert (b.live, b.stream, b.process) == (4.0, 3.5, 9.0)
    assert b.notes == 20.0  # an unknown notes model gets the most, as the free-memory gate does
    assert memory.budgets_for(_cfg()).notes == 14.0
    assert memory.budgets_for(_cfg(engine="claude")).notes == 2.0  # the model runs elsewhere


def test_budgets_take_the_table_load_config_parsed(tmp_path):
    """The table is parsed once, in load_config; the daemon and doctor take it as it is."""
    from palaver.config import load_config

    path = tmp_path / "config.toml"
    path.write_text('[notion]\ntoken = "t"\nparent_page_id = "p"\n[memory]\nlive_gb = 4\nnotes_gb = 9\n')
    b = memory.budgets_for(load_config(path))
    assert (b.live, b.notes) == (4.0, 9.0)


def test_notes_budget_follows_the_model_of_each_meeting(monkeypatch):
    from palaver import llm

    needs = {"a": 14.0, "b": 0.0}
    monkeypatch.setattr(llm, "notes_memory_gb", lambda cfg, folder=None: needs[folder.name] if folder else 14.0)
    hook = memory.budget_hook(_cfg())
    assert hook("notes", Path("/r/a")) == 14.0
    assert hook("notes", Path("/r/b")) == 2.0  # a cloud model: the process only waits for it
    assert hook("live", Path("/r/a")) is None
    assert hook("process", Path("/r/a")) is None
    # An explicit notes_gb wins over the model's need.
    assert memory.budget_hook(_cfg({"notes": 9.0}))("notes", Path("/r/a")) is None


def test_run_with_notes_gets_the_notes_models_need(monkeypatch):
    """With Notion upload on, the daemon runs `run`, which writes the notes in
    the same process: its budget is the notes model's need."""
    from palaver import llm

    monkeypatch.setattr(llm, "notes_memory_gb", lambda cfg, folder=None: 14.0)
    hook = memory.budget_hook(_cfg(sync=True))
    assert hook("process", Path("/r/a")) == 14.0
    monkeypatch.setattr(llm, "notes_memory_gb", lambda cfg, folder=None: 0.0)
    assert hook("process", Path("/r/a")) == 8.0


def test_budgets_refuse_nonsense():
    with pytest.raises(ValueError):
        memory.parse_budgets({"live_gb": -1})
    with pytest.raises(ValueError):
        memory.parse_budgets({"live_gb": "lots"})
    with pytest.raises(ValueError):
        memory.parse_budgets({"stream": 3})  # an unknown key is a typo
    with pytest.raises(ValueError):
        memory.parse_budgets({"process_ceiling_gb": 12})  # there is no hard ceiling any more
    assert memory.parse_budgets({}) == {}


class _Proc:
    def __init__(self, pid):
        self.pid = pid


class _Watch:
    """A watchdog over fake samples, fake free memory and a fake clock."""

    def __init__(self, budgets=Budgets(live=5.0), **kwargs):
        self.used: dict[int, float] = {}  # pid → GB
        self.free = 30.0
        self.now = 0.0
        self.dog = Watchdog(budgets, sample=lambda pid: None if pid not in self.used else int(self.used[pid] * GB),
                            own=lambda: int(0.3 * GB), others=lambda known: 0, clock=lambda: self.now,
                            free_gb=lambda: self.free, **kwargs)

    def check(self, *workers, after=0.0):
        self.now += after
        self.last = self.dog.check(list(workers))
        return [(a.what, a.kind, a.folder.name) for a in self.last]

    def sustain(self, *workers):
        """Samples over OVER_SECONDS: OVER_SAMPLES of them, the actions of the last."""
        step = memory.OVER_SECONDS / (memory.OVER_SAMPLES - 1)
        out = self.check(*workers)
        for _ in range(memory.OVER_SAMPLES - 1):
            out = self.check(*workers, after=step)
        return out


def test_the_live_budget_leaves_room_above_a_whole_meetings_peak():
    """Replaying a 60-min call, the live worker stays at 2.4–3.7 GB with
    peaks up to 4.8 GB (#49); a restart loses its work, so the default sits
    a GB above that."""
    assert Budgets().live == 6.0


def test_a_worker_under_budget_is_left_alone_and_shown():
    w, live = _Watch(), _Proc(11)
    w.used[11] = 3.6
    assert w.check(("live", Path("/r/m1"), live)) == []
    status = w.dog.status()
    assert status["total"] == int(0.3 * GB) + int(3.6 * GB)
    assert status["workers"] == [{"kind": "live", "label": "Live transcription", "meeting": "m1", "pid": 11,
                                  "used": int(3.6 * GB), "budget": 5.0, "state": "running"}]
    assert status["budgets"] == {"live": 5.0, "stream": 3.5, "process": 8.0, "notes": 14.0, "index": 1.0}


def test_live_over_budget_for_a_while_is_restarted_once_notified_once(caplog):
    w, live = _Watch(), _Proc(11)
    w.used[11] = 5.5
    folder = ("live", Path("/r/m1"), live)
    assert w.check(folder) == []  # a short spike passes
    assert w.dog.status()["workers"][0]["state"] == "over budget"
    assert w.check(folder, after=5) == []
    w.used[11] = 4.0
    assert w.check(folder, after=5) == []  # back under: the count starts again
    w.used[11] = 5.5
    assert w.check(folder, after=5) == []
    assert w.check(folder, after=memory.OVER_SECONDS) == []  # 10 s, but only two samples
    assert w.check(folder, after=1) == [("restart", "live", "m1")]
    assert w.check(folder, after=5) == []  # asked once; it is on its way out
    assert "over its 5 GB budget" in caplog.text
    # The new worker goes over too: restarted again, without a second notification.
    new = ("live", Path("/r/m1"), _Proc(12))
    w.used[12] = 5.5
    assert w.sustain(new) == [("restart", "live", "m1")]
    assert w.dog.check([new]) == []


def test_many_samples_in_a_moment_are_not_enough():
    w, live = _Watch(), _Proc(11)
    w.used[11] = 5.5
    for _ in range(10):
        assert w.check(("live", Path("/r/m1"), live), after=0.5) == []


def test_first_action_carries_the_notification_text():
    w, live = _Watch(), _Proc(11)
    w.used[11] = 5.5
    w.check(("live", Path("/r/m1"), live))
    w.now += memory.OVER_SECONDS
    w.check(("live", Path("/r/m1"), live))
    [a] = w.dog.check([("live", Path("/r/m1"), live)])
    assert a.title == "Live transcription restarted"
    assert "5.5 GB" in a.message and "5 GB" in a.message and "recording goes on" in a.message


def test_live_that_keeps_passing_its_budget_is_stopped_for_good():
    w = _Watch()
    folder = Path("/r/m1")
    whats = []
    for pid in range(20, 20 + memory.MAX_RESTARTS + 1):
        w.used[pid] = 6.0
        whats += w.sustain(("live", folder, _Proc(pid)))
    assert [x[0] for x in whats] == ["restart"] * memory.MAX_RESTARTS + ["stop"]


def test_restarts_count_per_meeting():
    w = _Watch()
    for n, folder in enumerate([Path("/r/a"), Path("/r/b")]):
        w.used[30 + n] = 4.0
        assert w.sustain(("stream", folder, _Proc(30 + n))) == [("restart", "stream", folder.name)]


def test_process_over_budget_is_left_to_finish_and_said_once():
    w, proc = _Watch(), _Proc(40)
    w.used[40] = 13.0  # budget 8; plenty free
    assert w.check(("process", Path("/r/m1"), proc)) == []  # one sample is no reason
    assert w.sustain(("process", Path("/r/m1"), proc)) == [("warn", "process", "m1")]
    assert w.sustain(("process", Path("/r/m1"), proc)) == []  # said once
    assert w.dog.status()["workers"][0]["state"] == "over budget"


@pytest.mark.parametrize("kind", ["process", "notes"])
def test_over_budget_under_memory_pressure_is_stopped_and_tried_again_then_given_up(kind):
    w = _Watch()
    folder = Path("/r/m1")
    w.free = 1.0  # below PRESSURE_GB
    whats = []
    for pid in range(50, 50 + memory.MAX_REQUEUES + 1):
        w.used[pid] = 20.0
        whats += [x for x in w.sustain((kind, folder, _Proc(pid))) if x[0] != "warn"]
    assert whats == [("requeue", kind, "m1")] * memory.MAX_REQUEUES + [("drop", kind, "m1")]


def test_low_memory_without_a_worker_over_budget_stops_nothing():
    w = _Watch()
    w.free = 0.5
    w.used[60] = 3.0
    assert w.sustain(("notes", Path("/r/m1"), _Proc(60))) == []


def test_pressure_must_last_too():
    w, proc = _Watch(), ("notes", Path("/r/m1"), _Proc(61))
    w.used[61] = 20.0
    w.sustain(proc)  # over budget, plenty free: said
    w.free = 1.0
    assert w.check(proc, after=1) == []
    w.free = 8.0
    assert w.check(proc, after=20) == []  # the pressure passed
    w.free = 1.0
    assert w.sustain(proc) == [("requeue", "notes", "m1")]


def test_free_memory_is_only_asked_when_a_worker_is_over_budget():
    asked = []
    w = _Watch()
    w.dog._free_gb = lambda: asked.append(1) or 30.0
    w.used[62] = 3.0
    w.sustain(("process", Path("/r/m1"), _Proc(62)))
    assert asked == []


def test_dropping_says_what_to_do():
    w = _Watch()
    w.free = 1.0
    acts = []
    for pid in range(70, 70 + memory.MAX_REQUEUES + 1):
        w.used[pid] = 20.0
        w.sustain(("process", Path("/r/m1"), _Proc(pid)))
        acts += [a for a in w.last if a.what == "drop"]
    [drop] = acts
    assert drop.title == "Transcription stopped: the Mac kept running low on memory"
    assert "palaver process" in drop.message and "m1" in drop.message and "3 times" in drop.message


def test_a_per_meeting_budget_hook_decides():
    w = _Watch(budget_for=lambda kind, folder: 20.0 if kind == "notes" else None)
    w.used[80] = 16.0
    assert w.sustain(("notes", Path("/r/m1"), _Proc(80))) == []
    assert w.dog.status()["workers"][0]["budget"] == 20.0


def test_a_worker_without_a_pid_or_gone_is_skipped():
    w = _Watch()
    assert w.check(("live", Path("/r/m1"), object()), ("stream", Path("/r/m1"), _Proc(99))) == []
    assert w.dog.status()["workers"] == []


def test_status_forgets_workers_that_are_gone():
    w = _Watch()
    w.used[11] = 1.0
    w.check(("live", Path("/r/m1"), _Proc(11)))
    w.check()
    assert w.dog.status()["workers"] == []


class _Sampler:
    def __init__(self, values):
        self.values = list(values)

    def __call__(self, pid):
        return int(self.values.pop(0) * GB) if self.values else None


def test_peak_tracker_keeps_the_peak_and_the_median():
    peak = memory.PeakTracker(sample=_Sampler([1.0, 3.0, 2.0]))
    for _ in range(3):
        peak.sample("live", 7)
    assert peak.peak("live") == int(3.0 * GB)
    assert peak.median("live") == int(2.0 * GB)
    assert peak.peak("stream") == 0


def test_signal_group_stops_a_worker_and_what_it_started():
    import signal
    import subprocess
    import sys
    import time

    worker = subprocess.Popen([sys.executable, "-c", "import subprocess, time; "
                               "subprocess.Popen(['sleep', '30']); time.sleep(30)"], start_new_session=True)
    try:
        for _ in range(100):
            helpers = memory.children(worker.pid)
            if helpers:
                break
            time.sleep(0.05)
        [helper] = helpers
        memory.signal_group(worker, signal.SIGTERM)
        worker.wait(5)
        for _ in range(100):
            if memory.footprint(helper) is None:
                break
            time.sleep(0.05)
        assert memory.footprint(helper) is None  # the helper went with it
    finally:
        if worker.poll() is None:
            worker.kill()
            worker.wait()


def test_signal_group_falls_back_to_the_process_itself():
    import signal

    class Fake:
        pid, calls = None, []

        def poll(self):
            return None

        def terminate(self):
            self.calls.append("term")

        def kill(self):
            self.calls.append("kill")

    f = Fake()
    memory.signal_group(f, signal.SIGTERM)
    memory.signal_group(f, signal.SIGKILL)
    assert f.calls == ["term", "kill"]


def test_the_search_index_has_a_small_budget_enforced_only_when_the_mac_runs_low():
    assert Budgets().index == 1.0 and memory.parse_budgets({"index_gb": 2}) == {"index": 2.0}
    w = _Watch()
    w.used[90] = 1.5
    index = ("index", memory.INDEX_FOLDER, _Proc(90))
    assert w.sustain(index) == [("warn", "index", "search index")]
    w.free = 1.0
    assert w.sustain(index) == [("requeue", "index", "search index")]
    whats = []
    for pid in (91, 92):
        w.used[pid] = 1.5
        whats += [x[0] for x in w.sustain(("index", memory.INDEX_FOLDER, _Proc(pid))) if x[0] != "warn"]
    assert whats == ["requeue", "drop"]
    assert w.last[0].title == "Search index paused: the Mac kept running low on memory"


def test_other_children_count_the_window_server_without_its_known_helpers():
    """The window's server is the app's child (#57); a best-next-question helper
    it started is a known worker and counted once, as that worker."""
    sizes = {10: 100, 11: 1000, 12: 5}  # 10: the server, 11: its helper (a known worker), 12: another of its children
    kids = {1: [10, 20], 10: [11, 12], 20: []}
    sizes[20] = 7  # 20: a known worker of the app itself
    total = memory._other_children({11, 20}, own=1, sample=sizes.get, children=lambda pid: kids.get(pid, []))
    assert total == 105
