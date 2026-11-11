// The meeting's commands (toolbar, ⋯ menu, list right-click, native menu):
// which apply to a meeting, from its JSON alone (web/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { meetingCommands, nextAfter } from "../../web/logic.js";

const NAMES = ["trash", "joinPrevious", "joinNext", "changeEvent", "split", "reviewAgain", "writeNotes", "play",
  "localOnly", "shared", "forgetSeries", "rename", "export", "report", "transcribe", "deleteAudio"];

function ready(extra = {}) {
  return {
    id: "2026-10-28T10-00-00", status: "ready", notes: null, reviewed: null, has_audio: true,
    transcript: [{ start: 0, end: 4, text: "Hallo" }, { start: 5, end: 9, text: "Hi" }],
    neighbours: { previous: null, next: null },
    ...extra,
  };
}

test("meetingCommands has every command the native menu names", () => {
  assert.deepEqual(Object.keys(meetingCommands(ready())).sort(), [...NAMES].sort());
  for (const [name, c] of Object.entries(meetingCommands(ready()))) {
    assert.equal(typeof c.label, "string", name);
    assert.equal(typeof c.enabled, "boolean", name);
  }
});

test("meetingCommands disables trash/join/split while live", () => {
  const live = ready({ live: { until: 312 }, status: "recording", has_audio: false,
    neighbours: { previous: { id: "2026-10-28T09-00-00", title: "Before" }, next: null } });
  const c = meetingCommands(live);
  assert.equal(c.trash.enabled, false);
  assert.equal(c.joinPrevious.enabled, false);
  assert.equal(c.joinNext.enabled, false);
  assert.equal(c.split.enabled, false);
  assert.equal(c.writeNotes.enabled, false);
});

test("a ready meeting with a previous neighbour can join with it, not with a next one", () => {
  const c = meetingCommands(ready({ neighbours: { previous: { id: "2026-10-28T09-00-00", title: "Before" }, next: null } }));
  assert.equal(c.joinPrevious.enabled, true);
  assert.equal(c.joinNext.enabled, false);
});

test("trash is the dangerous one, on ⌘⌫", () => {
  const c = meetingCommands(ready());
  assert.equal(c.trash.danger, true);
  assert.equal(c.trash.shortcut, "⌘⌫");
  assert.equal(c.trash.label, "Move to Trash");
  assert.equal(c.trash.enabled, true);
  assert.equal(c.joinPrevious.shortcut, "⌘J");
  assert.equal(c.writeNotes.shortcut, "⌘⇧N");
});

test("review again only for a reviewed meeting; notes are rewritten once there are some", () => {
  assert.equal(meetingCommands(ready()).reviewAgain.enabled, false);
  assert.equal(meetingCommands(ready({ reviewed: "2026-10-28T12:00:00+01:00" })).reviewAgain.enabled, true);
  assert.equal(meetingCommands(ready()).writeNotes.label, "Write notes");
  assert.equal(meetingCommands(ready({ notes: { title: "x" } })).writeNotes.label, "Rewrite notes");
});

test("a meeting still being transcribed can't be trashed, reviewed again, cut or given notes", () => {
  const c = meetingCommands(ready({ status: "processing", transcript: [], reviewed: "2026-10-28T12:00:00+01:00" }));
  assert.equal(c.trash.enabled, false);
  assert.equal(c.reviewAgain.enabled, false);
  assert.equal(c.split.enabled, false);
  assert.equal(c.changeEvent.enabled, false);
  assert.equal(c.writeNotes.enabled, false);
});

test("an incomplete recording can still go to the trash", () => {
  assert.equal(meetingCommands(ready({ status: "incomplete", transcript: [] })).trash.enabled, true);
});

test("play needs audio", () => {
  assert.equal(meetingCommands(ready()).play.enabled, true);
  assert.equal(meetingCommands(ready({ has_audio: false })).play.enabled, false);
});

test("nextAfter picks the one below, or above when it was the last", () => {
  const list = [{ id: "a" }, { id: "b" }, { id: "c" }];
  assert.equal(nextAfter(list, "a").id, "b");
  assert.equal(nextAfter(list, "c").id, "b");
  assert.equal(nextAfter([{ id: "a" }], "a"), null);
  assert.equal(nextAfter(list, "x"), null);
});

test("a meeting can be kept on this Mac, and allowed to the cloud again", () => {
  assert.equal(meetingCommands(ready()).localOnly.label, "Keep on This Mac");
  assert.equal(meetingCommands(ready()).localOnly.enabled, true);
  assert.equal(meetingCommands(ready({ local_only: true })).localOnly.label, "Allow Cloud Models");
  // While recording too: the mark is what decides where its notes are written.
  assert.equal(meetingCommands(ready({ status: "recording", live: { until: 3 } })).localOnly.enabled, true);
});

test("a finished meeting's speakers can be said to be inseparable, and separable again", () => {
  assert.equal(meetingCommands(ready()).shared.label, "Speakers Can't Be Separated");
  assert.equal(meetingCommands(ready()).shared.enabled, true);
  assert.equal(meetingCommands(ready({ shared: { meeting: true } })).shared.label, "Speakers Can Be Separated");
  assert.equal(meetingCommands(ready({ status: "processing" })).shared.enabled, false);
});

test("a remembered series can be forgotten from the menu, and only then is it there", () => {
  assert.equal(meetingCommands(ready()).forgetSeries.hidden, true);
  const c = meetingCommands(ready({ shared: { meeting: false, series: { can: true, remembered: true } } }));
  assert.deepEqual([c.forgetSeries.label, c.forgetSeries.enabled, c.forgetSeries.hidden], ["Forget for This Series", true, false]);
});

test("Transcribe Again: only for a meeting not transcribed, which can then go to the trash too", async () => {
  const { untranscribedText } = await import("../../web/logic.js");
  for (const status of ["failed", "waiting"]) {
    const c = meetingCommands(ready({ status, transcript: [] }));
    assert.equal(c.transcribe.enabled, true, status);
    assert.equal(c.transcribe.hidden, false, status);
    assert.equal(c.trash.enabled, true, status);  // "processing" for ever before: it could not
    assert.equal(c.writeNotes.enabled, false, status);
  }
  for (const status of ["ready", "processing", "recording"]) {
    assert.equal(meetingCommands(ready({ status })).transcribe.hidden, true, status);
  }
  const waiting = { status: "waiting", untranscribed: { missing: ["Speech models", "Notes model"] } };
  assert.match(untranscribedText(waiting), /waiting for Speech models and Notes model\./);
  assert.match(untranscribedText({ ...waiting, untranscribed: { missing: ["Speech models"] } }), /waiting for Speech models\./);
  assert.match(untranscribedText({ status: "waiting" }), /waiting for the speech models\./);
  const failed = { status: "failed", untranscribed: { error: "no GPU" } };
  assert.match(untranscribedText(failed), /not transcribed \(no GPU\)\. The audio is kept/);
  // The log's failure line says why already: not twice.
  assert.doesNotMatch(untranscribedText({ ...failed, failure: { step: "process", error: "no GPU" } }), /no GPU/);
});
