// Follow-ups after a call (#18): what a target's button says on the meeting page, the toast after it, and who the
// recap draft is for (web/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { followUpButton, followUpAddedText, recapTitle, settingsEntries, paletteMatch } from "../../web/logic.js";

const todoist = (extra = {}) => ({ id: "todoist", label: "Todoist", problem: null, sent: 0, new_mine: 1, new_all: 3, ...extra });
const status = (extra = {}) => ({
  local_only: false, mine: 1, recap_to: ["Timo Strauß"],
  steps: [{ task: "Book a room", owner: "Valerie", mine: true, sent: [] }, { task: "Send the figures", owner: "Timo", mine: false, sent: [] },
    { task: "Ask Northwind", owner: "", mine: false, sent: [] }],
  ...extra,
});

test("my next steps by default, everyone's when asked", () => {
  assert.deepEqual(followUpButton(status(), todoist(), false), { label: "Add my next steps to Todoist", disabled: false, title: null });
  assert.equal(followUpButton(status(), todoist(), true).label, "Add all next steps to Todoist");
});

test("once every step went, the button says so", () => {
  const b = followUpButton(status(), todoist({ sent: 1, new_mine: 0, new_all: 2 }), false);
  assert.deepEqual(b, { label: "Added to Todoist ✓", disabled: true, title: null });
});

test("only the new ones go when some went before", () => {
  const b = followUpButton(status(), todoist({ sent: 1, new_mine: 0, new_all: 2 }), true);
  assert.equal(b.label, "Add 2 new next steps to Todoist");
  assert.equal(b.disabled, false);
  assert.equal(followUpButton(status(), todoist({ project: "Contoso" }), false).title, "Into Contoso");
});

test("nothing to send: none of mine, or a meeting kept on this Mac", () => {
  const none = followUpButton(status({ mine: 0 }), todoist({ new_mine: 0 }), false);
  assert.equal(none.disabled, true);
  assert.equal(none.title, "None of the next steps are yours");
  const local = followUpButton(status({ local_only: true }), todoist(), false);
  assert.equal(local.disabled, true);
  assert.match(local.title, /kept on this Mac/);
});

test("the toast counts what was added", () => {
  assert.equal(followUpAddedText(1, "Notion"), "1 next step added to Notion");
  assert.equal(followUpAddedText(3, "Todoist"), "3 next steps added to Todoist");
  assert.equal(followUpAddedText(0, "Todoist"), "Nothing new to add to Todoist");
});

test("the recap's hint names who it goes to", () => {
  assert.match(recapTitle(["Timo Strauß", "Kim"]), /^A draft to Timo Strauß, Kim, /);
  assert.match(recapTitle(["A", "B", "C", "D", "E"]), /A, B, C and 2 more/);
  assert.match(recapTitle([]), /no addressees/);
});

test("the palette finds the Follow-ups pane by Todoist and Notion", () => {
  const entries = settingsEntries();
  assert.equal(paletteMatch("todoist", entries)[0]?.id, "follow-ups");
  assert.equal(paletteMatch("to-do", entries)[0]?.id, "follow-ups");
});
