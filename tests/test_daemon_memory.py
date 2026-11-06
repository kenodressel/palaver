"""The daemon's memory watchdog (issue #49): the workers it started keep to
their budgets, and the recording never stops because of them."""

from pathlib import Path

from palaver.memory import GB, OVER_SECONDS, Budgets, Watchdog
from tests.test_daemon import _daemon


class _Worker:
    """A worker process with a pid: it exits on SIGTERM unless ``stubborn``."""

    def __init__(self, pid, *, stubborn=False, rc=None):
        self.pid, self.stubborn, self.rc = pid, stubborn, rc
        self.terminated = self.killed = False

    def poll(self):
        return self.rc

    def terminate(self):
        self.terminated = True
        if not self.stubborn:
            self.rc = -15

    def kill(self):
        self.killed, self.rc = True, -9


def _watched(tmp_path, activity=lambda now: 10 <= now < 700, budgets=Budgets(), free=None, **kwargs):
    """A daemon whose workers report ``used[pid]`` GB; ``free[0]``: GB free."""
    used: dict[int, float] = {}
    free = free if free is not None else [30.0]
    dog = Watchdog(budgets, sample=lambda pid: int(used[pid] * GB) if pid in used else None,
                   own=lambda: int(0.25 * GB), others=lambda known: 0, free_gb=lambda: free[0])
    kwargs.setdefault("memory_free_gb", lambda: free[0])
    d, sessions, launched = _daemon(tmp_path, activity, watchdog=dog, **kwargs)
    workers: dict[str, list[_Worker]] = {"live": [], "stream": [], "process": [], "notes": []}
    pids = iter(range(100, 10_000))

    def starter(kind, gb=1.0, **worker):
        def start(folder):
            w = _Worker(next(pids), **worker)
            w.folder = folder
            workers[kind].append(w)
            used[w.pid] = gb
            if kind == "process":
                launched.append(folder)
            return w
        return start

    d._launch_live = starter("live", 1.2)
    d._launch_stream = starter("stream", 1.0)
    d._realtime = lambda: True
    d._live_running = lambda folder: any(w.rc is None for w in workers["live"] if w.folder == folder)
    return d, sessions, launched, workers, used, starter


def test_a_live_worker_over_budget_is_restarted_and_the_recording_goes_on(tmp_path, sent_notifications):
    d, sessions, _, workers, used, _ = _watched(tmp_path)
    d.run(until=lambda: d.now() > 30)
    [first] = workers["live"]
    used[first.pid] = 3.0  # over its 2 GB
    d.run(until=lambda: d.now() > 30 + OVER_SECONDS + 10)
    assert first.terminated
    assert len(workers["live"]) == 2 and workers["live"][1].folder == sessions[0].folder
    assert not sessions[0].stopped  # capture runs in the recorder, not in the worker
    assert d.status()["state"] == "recording"
    assert [t for t, _ in sent_notifications].count("Live transcription restarted") == 1
    assert len(workers["stream"]) == 1  # the other worker is left alone


def test_a_stream_over_budget_is_restarted(tmp_path, sent_notifications):
    d, sessions, _, workers, used, _ = _watched(tmp_path)
    d.run(until=lambda: d.now() > 30)
    used[workers["stream"][0].pid] = 4.0  # over its 3.5 GB
    d.run(until=lambda: d.now() > 30 + OVER_SECONDS + 10)
    assert workers["stream"][0].terminated and len(workers["stream"]) == 2
    assert "Realtime transcription restarted" in [t for t, _ in sent_notifications]


def test_a_worker_that_ignores_sigterm_is_killed_then_restarted(tmp_path):
    d, _, _, workers, used, starter = _watched(tmp_path)
    d._launch_live = starter("live", 1.2, stubborn=True)
    d.run(until=lambda: d.now() > 30)
    first = workers["live"][0]
    used[first.pid] = 3.0
    d.run(until=lambda: d.now() > 30 + OVER_SECONDS + 4)
    assert first.terminated and not first.killed and len(workers["live"]) == 1  # given time to exit
    d.run(until=lambda: d.now() > 30 + OVER_SECONDS + 30)
    assert first.killed and len(workers["live"]) == 2


def test_a_worker_is_not_restarted_once_the_recording_stopped(tmp_path, sent_notifications):
    """After the stop, `process` does what a live worker did not; nobody is
    told of a restart that did not happen."""
    d, sessions, _, workers, used, starter = _watched(tmp_path, activity=lambda now: 10 <= now < 40)
    d._launch_live = starter("live", 1.2, stubborn=True)
    d.run(until=lambda: d.now() > 30)
    used[workers["live"][0].pid] = 3.0
    d.run(until=lambda: d.now() > 120)
    assert sessions[0].stopped and workers["live"][0].killed
    assert len(workers["live"]) == 1
    assert "Live transcription restarted" not in [t for t, _ in sent_notifications]


def test_workers_are_signalled_as_a_process_group(tmp_path):
    """Workers start in their own session: their helpers go with them."""
    sent = []
    d, _, _, workers, used, _ = _watched(tmp_path, signal_worker=lambda p, sig: sent.append((p.pid, sig)))
    d.run(until=lambda: d.now() > 30)
    first = workers["live"][0]
    used[first.pid] = 3.0
    d.run(until=lambda: d.now() > 30 + OVER_SECONDS + 4)
    import signal

    assert (first.pid, signal.SIGTERM) in sent and not first.terminated


def _queued(tmp_path, d, queue):
    folder = tmp_path / "m1"
    folder.mkdir()
    queue.append(folder)
    return folder


def test_notes_over_budget_with_memory_to_spare_finish(tmp_path, sent_notifications):
    d, _, _, workers, used, starter = _watched(tmp_path, activity=lambda now: False, notes_memory_gb=14.0)
    d._launch_notes = starter("notes", 16.0)  # over the model's 14 GB
    _queued(tmp_path, d, d._notes_queue)
    d.run(until=lambda: d.now() > 60)
    assert not workers["notes"][0].terminated
    assert [t for t, _ in sent_notifications].count("Notes use more memory than planned") == 1


def test_notes_over_budget_while_the_mac_runs_low_wait_in_the_queue(tmp_path, sent_notifications):
    free = [30.0]
    d, _, _, workers, used, starter = _watched(tmp_path, activity=lambda now: False, free=free,
                                               notes_memory_gb=14.0)
    d._launch_notes = starter("notes", 9.0)
    folder = _queued(tmp_path, d, d._notes_queue)
    d.run(until=lambda: d.now() > 10)
    [notes] = workers["notes"]
    used[notes.pid] = 16.0
    free[0] = 1.0  # the Mac is out of memory
    d.run(until=lambda: d.now() > 10 + OVER_SECONDS + 10)
    assert notes.terminated
    assert d.status()["notes_queued"] == [str(folder)]
    assert "Notes paused: the Mac is low on memory" in [t for t, _ in sent_notifications]
    d.run(until=lambda: d.now() > 10 + OVER_SECONDS + 90)  # past the backoff; still low
    assert len(workers["notes"]) == 1
    assert any(w["kind"] == "notes" and w["state"] == "waiting for memory" for w in d.status()["memory"]["workers"])
    free[0] = 30.0  # memory came back: the normal gate lets them run
    d.run(until=lambda: d.now() > 10 + OVER_SECONDS + 100)
    assert len(workers["notes"]) == 2 and workers["notes"][1].folder == folder


def test_notes_stopped_three_times_are_given_up_with_what_to_do(tmp_path, sent_notifications):
    d, _, _, workers, used, starter = _watched(tmp_path, activity=lambda now: False, free=[1.0],
                                               notes_memory_gb=0.0)
    d._launch_notes = starter("notes", 20.0)
    _queued(tmp_path, d, d._notes_queue)
    d.run(until=lambda: d.now() > 3600)
    assert len(workers["notes"]) == 3
    assert d.status()["notes_queued"] == []
    [(title, message)] = [n for n in sent_notifications if n[0].startswith("Notes not written")]
    assert "Write notes" in message and "3 times" in message


def test_process_over_budget_with_memory_to_spare_finishes(tmp_path, sent_notifications):
    d, _, launched, workers, used, starter = _watched(tmp_path, activity=lambda now: False)
    d._launch = starter("process", 13.0)
    _queued(tmp_path, d, d._queue)
    d.run(until=lambda: d.now() > 60)
    assert not workers["process"][0].terminated
    assert [t for t, _ in sent_notifications].count("Transcription uses more memory than planned") == 1


def test_process_over_budget_while_the_mac_runs_low_is_stopped_and_tried_again(tmp_path, sent_notifications):
    free = [1.0]
    d, _, launched, workers, used, starter = _watched(tmp_path, activity=lambda now: False, free=free)
    d._launch = starter("process", 13.0, stubborn=True)
    folder = _queued(tmp_path, d, d._queue)
    d.run(until=lambda: d.now() > 14)
    first = workers["process"][0]
    assert first.terminated and d.status()["queued"] == [str(folder)]
    d.run(until=lambda: d.now() > 40)
    assert first.killed and len(workers["process"]) == 1  # one at a time, then a backoff
    assert "Transcription failed" not in [t for t, _ in sent_notifications]
    free[0] = 30.0
    d._launch = starter("process", 2.0)
    d.run(until=lambda: d.now() > 120)
    assert len(workers["process"]) == 2 and workers["process"][1].folder == folder


def test_process_stopped_three_times_is_given_up_with_what_to_do(tmp_path, sent_notifications):
    d, _, launched, workers, used, starter = _watched(tmp_path, activity=lambda now: False, free=[1.0])
    d._launch = starter("process", 13.0)
    _queued(tmp_path, d, d._queue)
    d.run(until=lambda: d.now() > 3600)
    assert len(workers["process"]) == 3
    assert d.status()["queued"] == []
    titles = [t for t, _ in sent_notifications]
    assert "Transcription stopped: the Mac kept running low on memory" in titles
    assert "Transcription failed" not in titles


def test_status_shows_what_palaver_costs(tmp_path):
    d, _, _, workers, used, _ = _watched(tmp_path)
    d.run(until=lambda: d.now() > 30)
    status = d.status()
    mem = status["memory"]
    assert mem["total"] == int(0.25 * GB) + int(1.2 * GB) + int(1.0 * GB)
    assert {w["kind"]: w["state"] for w in mem["workers"]} == {"live": "running", "stream": "running"}
    assert status["why_text"].endswith(" · Palaver 2.4 GB")


def test_without_a_watchdog_nothing_is_measured(tmp_path):
    d, _, _ = _daemon(tmp_path, lambda now: 10 <= now < 700)
    d.run(until=lambda: d.now() > 30)
    assert d.status()["memory"] is None
    assert "Palaver" not in d.status()["why_text"]


def test_a_memory_table_in_config_toml_starts_the_daemon_and_doctor(monkeypatch, tmp_path):
    """The table is parsed once (load_config); the app must start with one."""
    import palaver.daemon as daemon
    from palaver import doctor
    from palaver.config import load_config

    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "daemon.json")
    path = tmp_path / "config.toml"
    path.write_text('[notion]\ntoken = "t"\nparent_page_id = "p"\nauto_sync = false\n'
                    f'[recording]\noutput_dir = "{tmp_path}"\n[memory]\nlive_gb = 4\nstream_gb = 2.5\n')
    d = daemon.build_daemon(load_config(path))
    assert d._watchdog.budgets.live == 4.0 and d._watchdog.budgets.stream == 2.5
    for name in ("check_aec", "check_microphone", "check_teams_detection"):
        monkeypatch.setattr(doctor, name, lambda *a, **k: doctor.Check(name, "ok", ""))
    monkeypatch.setattr(doctor, "check_model", lambda *a, **k: doctor.Check("model", "ok", ""))
    monkeypatch.setattr(doctor, "_ram_gb", lambda: 48.0)  # CI's 7 GB would warn instead
    checks = doctor.run_checks(config_path=path, offline=True)
    [mem] = [c for c in checks if c.name == "Memory budgets"]
    assert mem.detail.startswith("live 4 GB, realtime 2.5 GB")


def _indexing(tmp_path, free):
    """A daemon that wants the search index built; ``free()``: GB free."""
    used: dict[int, float] = {}
    dog = Watchdog(Budgets(), sample=lambda pid: int(used[pid] * GB) if pid in used else None,
                   own=lambda: int(0.25 * GB), others=lambda known: 0, free_gb=lambda: free(d))
    d, _, _ = _daemon(tmp_path, lambda now: False, watchdog=dog, memory_free_gb=lambda: free(d),
                      index_wanted=lambda: True)
    d._index_check_seconds = 5
    indexers: list[_Worker] = []

    def launch():
        w = _Worker(5000 + len(indexers))
        indexers.append(w)
        used[w.pid] = 1.6  # over its 1 GB
        return w

    d._launch_index = launch
    return d, indexers


def test_the_search_index_over_budget_finishes_while_memory_is_free(tmp_path, sent_notifications):
    d, indexers = _indexing(tmp_path, lambda d: 30.0)
    d.run(until=lambda: d.now() > 60)
    assert len(indexers) == 1 and not indexers[0].terminated
    assert d.status()["indexing"] is True
    assert any(w["kind"] == "index" for w in d.status()["memory"]["workers"])


def test_the_search_index_is_paused_when_the_mac_runs_low_then_given_up(tmp_path, sent_notifications):
    # Low on memory only while it runs: it starts again after its backoff.
    d, indexers = _indexing(tmp_path, lambda d: 1.0 if d._indexer is not None else 30.0)
    d.run(until=lambda: d.now() > 40)
    assert indexers[0].terminated and d.status()["indexing"] is False
    assert len(indexers) == 1  # backoff
    d.run(until=lambda: d.now() > 3600)
    assert len(indexers) == 3  # then it is given up for this run of Palaver
    titles = [t for t, _ in sent_notifications]
    assert "Search index paused: the Mac kept running low on memory" in titles


def test_the_best_next_question_helper_has_the_notes_budget(tmp_path, sent_notifications):
    """The coach's helper (#41) is watched like notes: over the model's
    budget while the Mac runs low it is stopped, and nothing is queued."""
    free = [30.0]
    d, sessions, _, workers, used, _ = _watched(tmp_path, free=free, notes_memory_gb=14.0)
    d.run(until=lambda: d.now() > 20)
    helper = _Worker(4242)
    used[helper.pid] = 9.0
    d.watch_helper(sessions[0].folder, helper)
    assert ("question", sessions[0].folder, helper) in d._workers()
    d.run(until=lambda: d.now() > 30)
    assert not helper.terminated
    used[helper.pid] = 16.0
    free[0] = 1.0
    d.run(until=lambda: d.now() > 30 + OVER_SECONDS + 10)
    assert helper.terminated
    assert d.status()["notes_queued"] == []  # a question is not notes to write later
    assert not any(n[0].startswith("Notes") for n in sent_notifications)
    d.run(until=lambda: d.now() > 30 + OVER_SECONDS + 30)
    assert all(p is not helper for _, _, p in d._workers())  # gone once it exited
    assert sessions[0].stopped is False


def test_a_stopped_question_never_counts_against_the_meetings_notes(tmp_path, sent_notifications):
    """The helper is its own kind ("question"), with the notes' budget: two
    helpers stopped for low memory leave that meeting's notes their own
    three tries, and the notes still run normally."""
    free = [1.0]
    d, _, _, workers, used, starter = _watched(tmp_path, activity=lambda now: False, free=free, notes_memory_gb=0.0)
    folder = tmp_path / "m1"
    folder.mkdir()
    assert d._watchdog.budget("question", folder) == d._watchdog.budget("notes", folder)
    for pid in (5001, 5002):
        helper = _Worker(pid)
        used[pid] = 20.0
        d.watch_helper(folder, helper)
        start = d.now()
        d.run(until=lambda: d.now() > start + OVER_SECONDS + 10)
        assert helper.terminated
    assert d._watchdog._requeues.get(("notes", folder), 0) == 0
    assert not any(t.startswith("Notes") for t, _ in sent_notifications)
    d._launch_notes = starter("notes", 20.0)
    d._notes_queue.append(folder)
    d.run(until=lambda: d.now() > 3600)
    assert len(workers["notes"]) == 3  # its own three tries, none taken by the questions


def test_notes_run_normally_after_stopped_questions(tmp_path):
    free = [1.0]
    d, _, _, workers, used, starter = _watched(tmp_path, activity=lambda now: False, free=free, notes_memory_gb=0.0)
    folder = tmp_path / "m1"
    folder.mkdir()
    for pid in (6001, 6002):
        helper = _Worker(pid)
        used[pid] = 20.0
        d.watch_helper(folder, helper)
        start = d.now()
        d.run(until=lambda: d.now() > start + OVER_SECONDS + 10)
    free[0] = 30.0  # memory came back
    d._launch_notes = starter("notes", 9.0)
    d._notes_queue.append(folder)
    start = d.now()
    d.run(until=lambda: d.now() > start + 60)
    [notes] = workers["notes"]
    assert notes.folder == folder and not notes.terminated
