"""Why Palaver records, why a recording stopped, and where it paused
(issue #47), and what went wrong with its audio (issue #50) — the words the
menu bar, daemon.json, the transcript and the Meetings window show. Pure:
fed the daemon's status and a recording's meta.json.

meta.json carries what these read: ``trigger`` ("teams", "slack",
"manual", "split"), ``stop_reason`` (one of STOP_REASONS), ``gaps``
(``{"start", "end", "why"}`` in seconds from the start: stretches nothing
was recorded, e.g. while Palaver restarted) and ``audio_problems``
(``{"kind", "track", "start", "end"}``, see ``audio_health``).
"""

from __future__ import annotations

from datetime import datetime, timedelta

CALL_NAMES = {"teams": "Teams call", "slack": "Slack huddle"}
STOP_REASONS = {
    "by_you": "Stopped by you",
    "restart": "Palaver restarted",
    "auto_off": "Automatic recording turned off",
    "max_length": "Reached the maximum length",
    "silence": "Silent on this Mac for 30 minutes",  # a call taken on another device (#7)
}
GAP_WHY = {"restart": "Palaver restarted"}


def _hm(when: str | datetime) -> str:
    return (datetime.fromisoformat(when) if isinstance(when, str) else when).strftime("%H:%M")


def _khz(rate: float) -> str:
    return f"{rate / 1000:g} kHz"


def _mic(mic: dict | None) -> str | None:
    """"mic AirPods (24 kHz)", or as much of it as is known."""
    mic = mic or {}
    device, rate = mic.get("device"), mic.get("rate")
    if device and rate:
        return f"mic {device} ({_khz(rate)})"
    if device or rate:
        return f"mic {device or _khz(rate)}"
    return None


def _output(system: dict | None) -> str | None:
    """"output AirPods (24 kHz)": the device system audio is recorded from,
    once its name is known."""
    system = system or {}
    device, rate = system.get("device"), system.get("rate")
    if not device:
        return None
    return f"output {device} ({_khz(rate)})" if rate else f"output {device}"


def recording_text(why: dict) -> str:
    """"Recording · Teams call since 12:06 · mic AirPods (24 kHz) · output
    AirPods (24 kHz)"."""
    trigger, since = why.get("trigger"), _hm(why["since"])
    what = f"{CALL_NAMES[trigger]} since {since}" if trigger in CALL_NAMES else f"started by you at {since}"
    if why.get("restarts"):
        what += ", continued after a Palaver restart"
    parts = ("Recording", what, _mic(why.get("mic")), _output(why.get("system")))
    return " · ".join(p for p in parts if p)


def stopped_text(trigger: str | None, reason: str | None) -> str | None:
    if reason == "call_ended":
        return f"{CALL_NAMES.get(trigger or '', 'Call')} ended"
    return STOP_REASONS.get(reason or "")


def gap_text(gap: dict, start: datetime) -> str:
    """"Recording paused 12:13:05–12:13:14 (Palaver restarted)"."""
    def at(seconds: float) -> str:
        return (start + timedelta(seconds=int(seconds))).strftime("%H:%M:%S")

    why = GAP_WHY.get(gap.get("why") or "")
    return f"Recording paused {at(gap['start'])}–{at(gap['end'])}" + (f" ({why})" if why else "")


def _times(n: int) -> str:
    return {1: "", 2: " twice"}.get(n, f" {n} times")


def recorded_text(meta: dict, *, continued: bool = False) -> str | None:
    """How a finished recording started and stopped: "Teams call detected
    12:06 · Teams call ended 13:02 · Palaver restarted — continued".
    ``continued``: a part cut by a restart whose continuation is not joined
    on yet. None for recordings from before this was kept."""
    trigger, reason = meta.get("trigger"), meta.get("stop_reason")
    if trigger is None and reason is None:
        return None
    parts = []
    if trigger in CALL_NAMES:
        parts.append(f"{CALL_NAMES[trigger]} detected {_hm(meta['start_time'])}")
    elif trigger == "manual":
        parts.append(f"Started by you {_hm(meta['start_time'])}")
    stopped = stopped_text(trigger, reason)
    if stopped:
        end = meta.get("end_time")
        parts.append(f"{stopped} {_hm(end)}" if end else stopped)
        if reason == "restart" and continued:
            parts[-1] += " — continued"
    restarts = sum(1 for g in meta.get("gaps") or [] if g.get("why") == "restart")
    if restarts:
        parts.append(f"Palaver restarted{_times(restarts)} — continued")
    return " · ".join(parts) or None


# --- audio problems (issue #50) --------------------------------------------------

_TRACK = {"mic": "microphone", "system": "system audio"}
# While it lasts: the menu bar, the window, the notification. By (kind,
# track), else by kind.
_WARNING = {
    ("speed", "system"): "System audio is playing at the wrong speed; Palaver is correcting it",
    ("speed", "mic"): "Microphone is recording at the wrong speed; Palaver is correcting it",
    "length": "{Track} is out of step with the clock",
    ("stalled", "system"): "No system audio is arriving",
    "stalled": "No {track} audio is arriving",
    "access": "{Track} access was turned off — allow it in System Settings → Privacy & Security",
    ("device", "system"): "System audio couldn't be rebuilt; Palaver keeps trying",
    "device": "{Track} is unavailable; Palaver keeps trying",
}
# Afterwards: the meeting page, `palaver doctor`.
_HAPPENED = {
    ("speed", "system"): "system audio played at the wrong speed",
    ("speed", "mic"): "microphone recorded at the wrong speed",
    "length": "{track} drifted from the clock",
    "silent": "{track} sent nothing — muted?",
    "stalled": "{track} stopped delivering",
    "access": "{track} access was turned off",
    ("device", "system"): "system audio couldn't be rebuilt",
    "device": "{track} was unavailable",
}
_HINT = {"silent": "Your mic sends nothing — muted?"}


def _words(table: dict, problem: dict) -> str | None:
    kind, track = problem.get("kind") or "", problem.get("track") or ""
    template = table.get((kind, track)) or table.get(kind)
    if template is None:
        return None
    name = _TRACK.get(track, track)
    return template.format(track=name, Track=name[:1].upper() + name[1:])


def problem_warning(problem: dict) -> str:
    """"System audio is playing at the wrong speed; Palaver is correcting it"."""
    return _words(_WARNING, problem) or "Audio problem"


def recording_warnings(why: dict | None) -> list[str]:
    """The running recording's open audio problems, in words."""
    return [problem_warning(p) for p in (why or {}).get("problems") or []]


def recording_hints(why: dict | None) -> list[str]:
    """Soft hints about the running recording ("Your mic sends nothing — muted?")."""
    return [_HINT[h["kind"]] for h in (why or {}).get("hints") or [] if h.get("kind") in _HINT]


def problem_text(problem: dict, start: datetime) -> str:
    """"Audio problem at 12:14 (system audio played at the wrong speed)":
    at the wall-clock time taken when it happened, else ``start`` plus its
    offset."""
    try:
        when = datetime.fromisoformat(problem["at"])
    except (KeyError, TypeError, ValueError):
        when = start + timedelta(seconds=int(problem.get("start") or 0))
    what = _words(_HAPPENED, problem)
    return f"Audio problem at {_hm(when)}" + (f" ({what})" if what else "")
