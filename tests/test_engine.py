import os
import threading
import time
from pathlib import Path

import pytest

from palaver import engine
from palaver.engine import Engine, EngineError, ModelsMissing

FAKE = Path(__file__).parent / "fake_engine.py"


@pytest.fixture(autouse=True)
def fake(monkeypatch):
    monkeypatch.setenv("PALAVER_ENGINE", str(FAKE))
    monkeypatch.delenv("FAKE_ENGINE_MODE", raising=False)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_call_returns_reply():
    e = Engine()
    try:
        assert e.call("hello")["fluidaudio"] == "0.18.2"
    finally:
        e.close()


def test_progress_lines_reach_callback(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "progress")
    seen = []
    e = Engine()
    try:
        e.call("transcribe", progress=lambda frac, phase: seen.append(frac), wav="x.wav")
    finally:
        e.close()
    assert seen == [0.5, 1.0]


def test_error_reply_raises(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "error")
    e = Engine()
    try:
        with pytest.raises(EngineError, match="no such wav") as info:
            e.call("transcribe", wav="x.wav")
        assert not isinstance(info.value, ModelsMissing)
    finally:
        e.close()


def test_models_missing_raises_models_missing(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "models_missing")
    e = Engine()
    try:
        with pytest.raises(ModelsMissing, match="models missing: asr"):
            e.call("transcribe", wav="x.wav")
    finally:
        e.close()


def test_engine_crash_raises_engine_error(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash")
    e = Engine()
    with pytest.raises(EngineError) as info:
        e.call("hello")
    assert "exit 3" in str(info.value)
    assert "fake engine: out of memory" in str(info.value)
    e.close()


def test_close_ends_child():
    e = Engine()
    pid = e.call("hello")["pid"]
    e.close()
    deadline = time.time() + 5
    while alive(pid) and time.time() < deadline:
        time.sleep(0.05)
    assert not alive(pid)


def test_models_argument_reaches_child(tmp_path):
    e = Engine(models=tmp_path)
    try:
        args = e.call("hello")["args"]
    finally:
        e.close()
    assert args[args.index("--models") + 1] == str(tmp_path)


def test_two_clients_run_side_by_side(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "slow")
    monkeypatch.setenv("FAKE_ENGINE_DELAY", "1.0")
    engines = [Engine(), Engine()]
    out = []
    try:
        threads = [threading.Thread(target=lambda e=e: out.append(e.call("hello")["pid"])) for e in engines]
        start = time.time()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert time.time() - start < 1.8
    finally:
        for e in engines:
            e.close()
    assert len(set(out)) == 2


def test_engine_path_prefers_env_then_bundle_then_checkout(tmp_path, monkeypatch):
    env_bin = tmp_path / "env-engine"
    env_bin.write_text("")
    app = tmp_path / "Palaver.app"
    bundled = app / "Contents/MacOS/palaver-engine"
    bundled.parent.mkdir(parents=True)
    bundled.write_text("")
    checkout = tmp_path / "repo/native/.build/release/palaver-engine"
    checkout.parent.mkdir(parents=True)
    checkout.write_text("")
    monkeypatch.setattr(engine, "REPO", tmp_path / "repo")

    monkeypatch.setenv("PALAVER_ENGINE", str(env_bin))
    monkeypatch.setenv("PALAVER_APP", str(app))
    assert engine.engine_path() == env_bin
    monkeypatch.delenv("PALAVER_ENGINE")
    assert engine.engine_path() == bundled
    monkeypatch.delenv("PALAVER_APP")
    assert engine.engine_path() == checkout
    checkout.unlink()
    with pytest.raises(EngineError, match="make engine"):
        engine.engine_path()


@pytest.mark.integration
def test_real_engine_hello(monkeypatch):
    monkeypatch.delenv("PALAVER_ENGINE")
    try:
        engine.engine_path()
    except EngineError:
        pytest.skip("engine not built: run `make engine`")
    e = Engine()
    try:
        assert e.call("hello")["ok"] is True
    finally:
        e.close()


def test_silent_child_times_out(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "silent")
    e = Engine(idle_timeout=0.5)
    start = time.time()
    with pytest.raises(EngineError, match="stopped answering") as info:
        e.call("hello")
    assert time.time() - start < 5
    assert "fake engine started" in str(info.value)
    assert e._proc is None


def test_foreign_ids_then_silence_times_out(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "foreign")
    e = Engine(idle_timeout=0.5)
    with pytest.raises(EngineError, match="stopped answering"):
        e.call("hello")


def test_timed_out_child_is_gone(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "silent")
    e = Engine(idle_timeout=0.3)
    with pytest.raises(EngineError):
        e.call("hello")
    assert e._last_pid is not None
    deadline = time.time() + 5
    while alive(e._last_pid) and time.time() < deadline:
        time.sleep(0.05)
    assert not alive(e._last_pid)


def test_dropped_engine_ends_child():
    import gc

    e = Engine()
    pid = e.call("hello")["pid"]
    del e
    gc.collect()
    deadline = time.time() + 5
    while alive(pid) and time.time() < deadline:
        time.sleep(0.05)
    assert not alive(pid)


def test_invalid_utf8_does_not_break_client(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "badbytes")
    e = Engine(idle_timeout=10)
    try:
        reply = e.call("hello")
        assert reply["ok"] is True
    finally:
        e.close()


def test_kwargs_cannot_override_id_or_cmd():
    e = Engine()
    try:
        assert e.call("hello", id=5, cmd="evil")["cmd"] == "hello"
    finally:
        e.close()


def test_progress_callback_raising_kills_child(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "badprogress")
    e = Engine()

    def boom(frac, phase):
        raise ValueError("cancel")

    with pytest.raises(ValueError):
        e.call("hello", progress=boom)
    deadline = time.time() + 5
    while alive(e._last_pid) and time.time() < deadline:
        time.sleep(0.05)
    assert not alive(e._last_pid)
    assert e._proc is None


def test_errors_carry_a_short_reason_and_the_full_stderr_tail(monkeypatch):
    monkeypatch.setenv("FAKE_ENGINE_MODE", "crash")
    with pytest.raises(EngineError) as info:
        Engine().call("hello")
    assert info.value.reason == "the speech engine stopped (exit 3)"
    assert "out of memory" in str(info.value)


def test_missing_engine_says_reinstall_inside_the_app(monkeypatch, tmp_path):
    from palaver import engine, install_layout

    monkeypatch.delenv("PALAVER_ENGINE", raising=False)
    monkeypatch.setattr(engine, "REPO", tmp_path)
    monkeypatch.setattr(install_layout, "bundle", lambda: tmp_path / "Palaver.app")
    with pytest.raises(EngineError, match="reinstall Palaver"):
        engine.engine_path()
    monkeypatch.setattr(install_layout, "bundle", lambda: None)
    with pytest.raises(EngineError, match="make engine"):
        engine.engine_path()
