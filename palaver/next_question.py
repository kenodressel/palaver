"""Best next question (#41): on the user's click during a call, 1–3
questions to ask next, each with why.

From the last few minutes of what was said (the live text: the block
worker's and the stream's), and the meeting's prep: its calendar title
and invitees, who hasn't spoken, the last meeting with the same people
(its summary and open next steps) and the user's own notes (#44). The
prompt is strict: only what the transcript and the context show.

It runs on the language model the user chose for it in Settings (#53);
"Keep on This Mac" keeps it local. The local model runs only on a click,
and only with the free memory the notes need (``memory_problem``): it never
starts when it would take the memory a call needs.
"""

from __future__ import annotations

from typing import Any, Callable

from .cloud_llm import _json_object

FEATURE = "coach"
RECENT_SECONDS = 300.0  # the last five minutes of the transcript ...
MIN_LINES = 2  # ... or at least the last two lines
MAX_LINES = 120
MAX_QUESTIONS = 3
MAX_NOTES_CHARS = 4000

SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "questions": {
            "type": "array",
            "maxItems": MAX_QUESTIONS,
            "items": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "The question, as the user would ask it."},
                    "why": {"type": "string",
                            "description": "One short sentence: what in the transcript or the context it comes from."},
                },
                "required": ["question", "why"],
            },
        },
    },
    "required": ["questions"],
}

RULES = """You help {user} during a meeting that is going on right now. Suggest one to three questions {user} could ask next.

Only use what the transcript and the context below show. Never invent names, numbers, dates, decisions or facts. Look for gaps:
- a decision or task without an owner or a date;
- something raised and then dropped;
- an open next step from last time that has not come up yet;
- an invitee who has not said anything yet;
- a question of the others that is still unanswered.
For each question, say in one short sentence why, pointing to what in the transcript or the context it comes from. Write the questions in the language the meeting is held in. If nothing in the transcript supports a good question, return an empty list."""


class NothingYet(ValueError):
    """There is no transcript to suggest a question from yet."""


def _clock(seconds: float) -> str:
    seconds = int(max(0, seconds))
    h, rest = divmod(seconds, 3600)
    m, s = divmod(rest, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def recent_lines(lines: list[dict], now: float) -> list[dict]:
    """The lines of the last RECENT_SECONDS, or the last MIN_LINES when
    fewer were said in that time."""
    lines = sorted(lines, key=lambda line: line["start"])
    recent = [line for line in lines if line["start"] >= now - RECENT_SECONDS]
    if len(recent) < MIN_LINES:
        recent = lines[-MIN_LINES:]
    return recent[-MAX_LINES:]


def build_prompt(inputs: dict[str, Any]) -> str:
    """``inputs``: user, now (seconds into the meeting), lines ({speaker,
    start, text}), title, invitees, quiet (invitees not heard yet),
    last_time ({title, start, summary, next_steps}), my_notes."""
    lines = recent_lines([line for line in inputs.get("lines") or [] if (line.get("text") or "").strip()],
                         float(inputs.get("now") or 0.0))
    if not lines:
        raise NothingYet("Nothing has been said yet.")
    user = inputs.get("user") or "the user"
    parts = [RULES.format(user=user), "", "## Context"]
    if inputs.get("title"):
        parts.append(f"Meeting: {inputs['title']}")
    if inputs.get("invitees"):
        parts.append("Invited: " + ", ".join(inputs["invitees"]))
    if inputs.get("quiet"):
        parts.append("Invited but not heard yet: " + ", ".join(inputs["quiet"]))
    for m in inputs.get("last_time") or []:
        parts.append(f"Last time ({(m.get('start') or '')[:10]}, {m.get('title') or 'a meeting'}): "
                     f"{m.get('summary') or 'no summary'}")
        steps = [s for s in m.get("next_steps") or [] if isinstance(s, dict) and s.get("task")]
        for s in steps:
            parts.append(f"- open next step: {s['task']}" + (f" ({s['owner']})" if s.get("owner") else ""))
    notes = "\n".join(n for n in inputs.get("my_notes") or [] if n.strip())
    if notes:
        parts += [f"{user}'s own notes on the meeting:", notes[:MAX_NOTES_CHARS]]
    parts += ["", "## Transcript (the last minutes)"]
    parts += [f"[{_clock(line['start'])}] {line.get('speaker') or 'Someone'}: {line['text'].strip()}" for line in lines]
    return "\n".join(parts)


def parse(text: str) -> dict[str, Any]:
    """The model's answer, kept to what the schema allows."""
    return checked(_json_object(text))


def checked(answer: Any) -> dict[str, Any]:
    if not isinstance(answer, dict) or not isinstance(answer.get("questions"), list):
        raise ValueError("the answer has no list of questions")
    out = []
    for q in answer["questions"]:
        if not isinstance(q, dict):
            continue
        question, why = str(q.get("question") or "").strip(), str(q.get("why") or "").strip()
        if question:
            out.append({"question": question, "why": why})
    return {"questions": out[:MAX_QUESTIONS]}


def ask(inputs: dict[str, Any], run: Callable[[str, dict], dict]) -> dict[str, Any]:
    """The questions, from the engine's runner ``run(prompt, schema)``."""
    return checked(run(build_prompt(inputs), SCHEMA))


def model_name(model: str) -> str:
    """"claude-opus-5-5" → "Claude Opus 5.5", "sonnet" → "Claude Sonnet";
    any other model as it is named."""
    import re

    m = re.fullmatch(r"claude-([a-z]+)-(\d+)(?:-(\d))?(?:-\d{8})?", model)
    if m:
        return f"Claude {m.group(1).capitalize()} {m.group(2)}" + (f".{m.group(3)}" if m.group(3) else "")
    if model in ("opus", "sonnet", "haiku"):
        return f"Claude {model.capitalize()}"
    return model


def memory_problem(*, local: bool, free_gb: float, need_gb: float, recording: bool) -> str | None:
    """Why the local model can't start now, said plainly; None when it can
    (or a cloud model answers)."""
    if not local or free_gb >= need_gb:
        return None
    if recording:
        return ("Not enough free memory for the local model during the call; choose a cloud model in "
                "Settings → Language model, or ask after the call")
    return (f"Not enough free memory for the local model right now ({free_gb:.0f} GB free, it needs "
            f"{need_gb:.0f} GB); choose a cloud model in Settings → Language model, or try again later")
