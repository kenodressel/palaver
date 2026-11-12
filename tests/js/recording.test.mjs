// The question whether to stop a manual recording whose call has ended (issue #52).
import { test } from "node:test";
import assert from "node:assert/strict";

import { stopQuestionFor, stopAnswerText } from "../../web/logic.js";

const ID = "2026-10-29T16-07-55";
const asked = { meeting: ID, reason: "teams", minutes: 10, message: "You started this recording yourself, and your Teams call just ended. Stop recording?" };

test("stopQuestionFor shows the question only on the meeting being recorded", () => {
  assert.equal(stopQuestionFor(asked, { id: ID, status: "recording" }), asked);
  assert.equal(stopQuestionFor(asked, { id: ID, status: "processing", live: { until: 30 } }), asked);
  assert.equal(stopQuestionFor(asked, { id: "2026-10-29T15-00-00", status: "recording" }), null);
  assert.equal(stopQuestionFor(asked, { id: ID, status: "ready" }), null);  // stopped meanwhile
  assert.equal(stopQuestionFor(null, { id: ID, status: "recording" }), null);
  assert.equal(stopQuestionFor(asked, null), null);
});

test("stopAnswerText says what happened and when it asks again", () => {
  assert.equal(stopAnswerText("stop", asked), "Recording stopped. It is transcribed in the background.");
  assert.equal(stopAnswerText("keep", asked), "Still recording. Palaver asks again when the next call ends or after 30 silent minutes.");
});

// Why it records, why it stopped, where it paused (issue #47).
import { recordingLine, gapsBefore } from "../../web/logic.js";

test("recordingLine: why the running recording records, else how it was recorded", () => {
  const rec = { meeting: ID, text: "Recording · Teams call since 16:07 · mic AirPods (24 kHz)" };
  assert.equal(recordingLine({ id: ID, status: "recording" }, rec), rec.text);
  assert.equal(recordingLine({ id: ID, status: "processing", live: { until: 3 } }, rec), rec.text);
  assert.equal(recordingLine({ id: ID, status: "ready", recorded: "Teams call ended" }, rec), "Teams call ended");
  assert.equal(recordingLine({ id: "other", status: "recording" }, rec), null);
  assert.equal(recordingLine({ id: ID, status: "ready" }, null), null);
  assert.equal(recordingLine(null, rec), null);
});

test("gapsBefore: each pause shows once, before the first line after it", () => {
  const gaps = [{ start: 30, end: 39, text: "a" }, { start: 69, end: 80, text: "b" }, { start: 200, end: 210, text: "c" }];
  const lines = [{ start: 1 }, { start: 29 }, { start: 40 }, { start: 81 }];
  assert.deepEqual(lines.map((l, i) => gapsBefore(gaps, lines, i).map((g) => g.text)), [[], [], ["a"], ["b"]]);
  assert.deepEqual(gapsBefore(gaps, lines, lines.length).map((g) => g.text), ["c"]);  // after the last line
  assert.deepEqual(gapsBefore(undefined, lines, 0), []);
});

// Audio problems (issue #50): live warnings of the running recording, or
// when a finished one's audio went wrong.
import { audioWarnings } from "../../web/logic.js";

test("audioWarnings: the running recording's warnings, else the meeting's audio problems", () => {
  const rec = { meeting: ID, text: "Recording", warnings: ["System audio is playing at the wrong speed; Palaver is correcting it"] };
  assert.deepEqual(audioWarnings({ id: ID, status: "recording" }, rec), rec.warnings);
  assert.deepEqual(audioWarnings({ id: ID, status: "processing", live: { until: 3 } }, rec), rec.warnings);
  assert.deepEqual(audioWarnings({ id: ID, status: "recording" }, { meeting: ID, text: "Recording" }), []);
  const done = { id: ID, status: "ready", audio_problems: [{ start: 60, end: 75, text: "Audio problem at 16:04 (system audio played at the wrong speed)" }] };
  assert.deepEqual(audioWarnings(done, rec), ["Audio problem at 16:04 (system audio played at the wrong speed)"]);
  assert.deepEqual(audioWarnings({ id: "other", status: "recording" }, rec), []);
  assert.deepEqual(audioWarnings({ id: ID, status: "ready" }, null), []);
  assert.deepEqual(audioWarnings(null, rec), []);
});

import { audioHints } from "../../web/logic.js";

test("audioHints: the running recording's soft hints, only on its own page", () => {
  const rec = { meeting: ID, text: "Recording", warnings: [], hints: ["Your mic sends nothing — muted?"] };
  assert.deepEqual(audioHints({ id: ID, status: "recording" }, rec), rec.hints);
  assert.deepEqual(audioHints({ id: ID, status: "ready" }, rec), []);
  assert.deepEqual(audioHints({ id: "other", status: "recording" }, rec), []);
  assert.deepEqual(audioHints({ id: ID, status: "recording" }, { meeting: ID, text: "Recording" }), []);
  assert.deepEqual(audioHints(null, rec), []);
});

import { mutedIn, muteUnfollowed, mutedText } from "../../web/logic.js";

test("mutedIn: the call app the running recording's mic is muted in, only on its own page", () => {
  const rec = { meeting: ID, text: "Recording", warnings: [], hints: [], muted: "teams", mute_unfollowed: null };
  assert.equal(mutedIn({ id: ID, status: "recording" }, rec), "Teams");
  assert.equal(mutedIn({ id: ID, status: "processing", live: { until: 30 } }, rec), "Teams");
  assert.equal(mutedIn({ id: ID, status: "recording" }, { ...rec, muted: "slack" }), "Slack");
  assert.equal(mutedIn({ id: ID, status: "recording" }, { ...rec, muted: null }), null);
  assert.equal(mutedIn({ id: ID, status: "ready" }, rec), null);
  assert.equal(mutedIn({ id: "other", status: "recording" }, rec), null);
  assert.equal(mutedIn(null, rec), null);
  assert.equal(mutedText("Teams"), "Your mic is muted in Teams: not recorded");
});

test("muteUnfollowed: a Teams recording whose mute can't be seen", () => {
  const rec = { meeting: ID, text: "Recording", muted: null, mute_unfollowed: "teams" };
  assert.equal(muteUnfollowed({ id: ID, status: "recording" }, rec), "Teams");
  assert.equal(muteUnfollowed({ id: ID, status: "recording" }, { ...rec, mute_unfollowed: null }), null);
  assert.equal(muteUnfollowed({ id: ID, status: "recording" }, { meeting: ID, text: "Recording" }), null);
  assert.equal(muteUnfollowed({ id: ID, status: "ready" }, rec), null);
});

// While the window's server restarts (#57): a quiet "Reconnecting…" after 2 s without an answer.
import { heartbeat } from "../../web/logic.js";

function fakeClock() {
  const timers = new Map();
  let next = 1;
  return {
    setTimeout: (fn, ms) => { const id = next++; timers.set(id, { fn, ms }); return id; },
    clearTimeout: (id) => timers.delete(id),
    fire: () => { for (const [id, t] of [...timers]) { timers.delete(id); t.fn(); } },
    pending: () => [...timers.values()].map((t) => t.ms),
  };
}

test("heartbeat: a server that answers shows nothing", async () => {
  const clock = fakeClock();
  const shown = [];
  const beat = heartbeat({ fetch: async () => ({ ok: true }), show: (on) => shown.push(on), ...clock });
  await beat();
  assert.deepEqual(clock.pending(), []);
  assert.deepEqual(shown, [false]);
});

test("heartbeat: no answer within 2 s shows the line; the answer clears it", async () => {
  const clock = fakeClock();
  const shown = [];
  let answer;
  const beat = heartbeat({ fetch: () => new Promise((resolve) => { answer = resolve; }), show: (on) => shown.push(on), ...clock });
  const done = beat();
  assert.deepEqual(clock.pending(), [2000]);
  clock.fire();
  assert.deepEqual(shown, [true]);
  assert.equal(beat(), undefined);  // one at a time: the hanging one decides
  answer({ ok: true });
  await done;
  assert.deepEqual(shown, [true, false]);
});

test("heartbeat: a failed request shows the line at once", async () => {
  const clock = fakeClock();
  const shown = [];
  const beat = heartbeat({ fetch: async () => { throw new TypeError("Load failed"); }, show: (on) => shown.push(on), ...clock });
  await beat();
  assert.deepEqual(shown, [true]);
  assert.deepEqual(clock.pending(), []);
});

// --- recording by hand from the window (#11) ---

import { recordingNow, recordingCommand, paletteMatch } from "../../web/logic.js";

test("a stopped recording that is still finishing is no longer the one being recorded", () => {
  assert.equal(recordingNow([{ id: "a", status: "recording", finishing: true }]), null);
});

test("recordingNow is the meeting being recorded, if any", () => {
  const live = { id: ID, status: "recording" };
  assert.equal(recordingNow([{ id: "a", status: "ready" }, live]), live);
  assert.equal(recordingNow([{ id: "a", status: "processing" }]), null);
  assert.equal(recordingNow(undefined), null);
});

test("the palette offers Start Recording, or Stop Recording while one runs", () => {
  assert.equal(recordingCommand(null).label, "Start Recording");
  assert.equal(recordingCommand({ id: ID }).id, "stopRecording");
  for (const typed of ["record", "on site", "in person", "new"]) {
    assert.deepEqual(paletteMatch(typed, [recordingCommand(null)]).map((e) => e.id), ["startRecording"], typed);
  }
});
