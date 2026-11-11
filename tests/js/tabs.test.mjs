// A meeting's tabs: Summary (the generated notes, key "notes"), Notes (mine), Transcript, Coach; and which
// one a meeting opens on (web/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { meetingTabs, meetingTab, TAB_LABELS } from "../../web/logic.js";

const ready = { status: "ready", notes: { summary: "…" }, my_notes_revision: "" };
const live = { status: "recording", live: { until: 60 }, notes: null, my_notes_revision: "" };

test("the tabs, in order; Coach only once the meeting is ready", () => {
  assert.deepEqual(meetingTabs(ready), ["notes", "mine", "transcript", "coach"]);
  assert.deepEqual(meetingTabs(live), ["notes", "mine", "transcript"]);
  assert.deepEqual(meetingTabs(ready).map((t) => TAB_LABELS[t]), ["Summary", "Notes", "Transcript", "Coach"]);
});

test("a live meeting opens on its transcript", () => {
  assert.equal(meetingTab(live), "transcript");
  assert.equal(meetingTab({ ...live, my_notes_revision: "abc" }), "transcript");
  assert.equal(meetingTab({ status: "recording", notes: null, my_notes_revision: "" }), "transcript");  // its first minute
});

test("a ready meeting opens on its summary, or on my notes when there is no summary", () => {
  assert.equal(meetingTab(ready), "notes");
  assert.equal(meetingTab({ ...ready, my_notes_revision: "abc" }), "notes");
  assert.equal(meetingTab({ ...ready, notes: null, my_notes_revision: "abc" }), "mine");
  assert.equal(meetingTab({ ...ready, notes: null }), "notes");  // nothing yet: Write notes is there
});

test("the tab asked for (history, a link) wins when the meeting has it", () => {
  assert.equal(meetingTab(ready, { asked: "transcript" }), "transcript");
  assert.equal(meetingTab(ready, { asked: "mine" }), "mine");
  assert.equal(meetingTab(ready, { asked: "notes" }), "notes");  // an old entry: the Summary
  assert.equal(meetingTab(ready, { asked: "coach" }), "coach");
  assert.equal(meetingTab(live, { asked: "coach" }), "transcript");  // no coach while it records
  assert.equal(meetingTab(ready, { asked: "nonsense" }), "notes");
});

test("a time to play opens the transcript; the coach stays open from meeting to meeting", () => {
  assert.equal(meetingTab(ready, { at: 15 }), "transcript");
  assert.equal(meetingTab(ready, { current: "coach" }), "coach");
  assert.equal(meetingTab(live, { current: "coach" }), "transcript");
  assert.equal(meetingTab(ready, { current: "mine" }), "notes");  // the defaults, not the last tab
});
