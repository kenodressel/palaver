// A meeting's own title (renamed in place, from ⋯ or ⌘K): what a save sends,
// how the page shows it before the server answers, and what it says.
import { test } from "node:test";
import assert from "node:assert/strict";

import { titleChange, withTitle, retitledText, calendarHint, meetingCommands, TITLE_MAX }
  from "../../palaver/webapp/static/logic.js";

const fromNotes = { id: "m", title: "Budget talk", title_from: "notes", notes: { title: "Budget talk" }, calendar: null };
const fromCalendar = { id: "m", title: "Weekly sync", title_from: "calendar", notes: { title: "Budget talk" },
  calendar: { title: "Weekly sync" } };
const mine = { ...fromCalendar, title: "Budget with Anna", title_from: "you" };
const untitled = { id: "m", title: null, title_from: null, notes: null, calendar: null };

test("a new title is sent as typed, on one line and capped", () => {
  assert.equal(titleChange(fromNotes, "  Budget\n with  Anna "), "Budget with Anna");
  assert.equal(titleChange(untitled, "x".repeat(250)), "x".repeat(TITLE_MAX));
  assert.equal(TITLE_MAX, 200);
});

test("nothing is sent when the title stays what it is", () => {
  assert.equal(titleChange(fromNotes, "Budget talk"), null);
  assert.equal(titleChange(fromCalendar, " Weekly sync "), null);
  assert.equal(titleChange(mine, "Budget with Anna"), null);
  assert.equal(titleChange(untitled, ""), null);
  assert.equal(titleChange(fromNotes, "   "), null);  // emptied, but there is no title of one's own to clear
});

test("emptying a title of one's own clears it", () => {
  assert.equal(titleChange(mine, ""), "");
  assert.equal(titleChange(mine, "  "), "");
});

test("the event's title can be taken as one's own once it is someone else's", () => {
  assert.equal(titleChange(mine, "Weekly sync"), "Weekly sync");
});

test("before the server answers, the page shows the new title, or the next one when cleared", () => {
  assert.deepEqual([withTitle(fromNotes, "Mine").title, withTitle(fromNotes, "Mine").title_from], ["Mine", "you"]);
  const cleared = withTitle(mine, "");
  assert.deepEqual([cleared.title, cleared.title_from], ["Weekly sync", "calendar"]);
  const back = withTitle({ ...mine, calendar: null }, "");
  assert.deepEqual([back.title, back.title_from], ["Budget talk", "notes"]);
  assert.deepEqual([withTitle({ ...untitled, title: "x", title_from: "you" }, "").title], [null]);
  assert.equal(mine.title, "Budget with Anna");  // the meeting itself is left as it was
  const imported = withTitle({ ...mine, imported: { from: "Anna", title: "Budget with Tom" } }, "");
  assert.deepEqual([imported.title, imported.title_from], ["Budget with Tom", "imported"]);  // the sender's, next
});

test("the toast says the new title, or which one shows again", () => {
  assert.equal(retitledText(mine, "Budget with Anna"), "Renamed to “Budget with Anna”");
  assert.equal(retitledText(fromCalendar, "Weekly sync"), "Title back to “Weekly sync”");
  assert.equal(retitledText(untitled, "Meeting at 12:04"), "Title back to “Meeting at 12:04”");
});

test("under a title of one's own, a quiet line says what the calendar calls the meeting", () => {
  assert.equal(calendarHint(mine), "Calendar: Weekly sync");
  assert.equal(calendarHint(fromCalendar), null);
  assert.equal(calendarHint({ ...mine, calendar: null }), null);
  assert.equal(calendarHint({ ...mine, title: "Weekly sync" }), null);  // the same words: nothing to add
});

test("a meeting can be renamed in any state, also while it is recorded", () => {
  const live = { id: "m", status: "recording", live: { until: 30 }, transcript: [], neighbours: {} };
  assert.equal(meetingCommands(live).rename.enabled, true);
  assert.equal(meetingCommands({ ...live, status: "processing", live: null }).rename.enabled, true);
  assert.equal(meetingCommands(live).rename.label, "Rename…");
});
