// Report a Problem and the usage counts of the window (#59): the form's
// meeting, its address, the action catalog, and the counter the action
// registry is hooked into (palaver/webapp/static/logic.js, ui.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { reportMeeting, reportDraft, reportDoneText, actionCatalog, placeOf, hashOf, meetingCommands, paletteCommands }
  from "../../palaver/webapp/static/logic.js";
import { UsageCounter, tracked } from "../../palaver/webapp/static/ui.js";

const meetings = [{ id: "2026-10-30T09-00-00" }, { id: "2026-10-28T09-00-00" }, { id: "2026-10-29T09-00-00" }];

test("reportMeeting: the one asked for, else the open one, else the last opened, else the newest", () => {
  assert.equal(reportMeeting("2026-10-28T09-00-00", { open: "2026-10-29T09-00-00", meetings }), "2026-10-28T09-00-00");
  assert.equal(reportMeeting(null, { open: "2026-10-29T09-00-00", last: "2026-10-28T09-00-00", meetings }),
    "2026-10-29T09-00-00");
  assert.equal(reportMeeting(null, { last: "2026-10-28T09-00-00", meetings }), "2026-10-28T09-00-00");
  assert.equal(reportMeeting(null, { meetings }), "2026-10-30T09-00-00");
  assert.equal(reportMeeting("gone", { meetings }), "2026-10-30T09-00-00");
});

test("reportMeeting: none when asked for none, or when there are no meetings", () => {
  assert.equal(reportMeeting("none", { open: "2026-10-29T09-00-00", meetings }), null);
  assert.equal(reportMeeting(null, {}), null);
});

test("the report form has an address, with the meeting it is about", () => {
  assert.deepEqual(placeOf("#/report"), { view: "report", meeting: null });
  assert.deepEqual(placeOf("#/report/2026-10-30T09-00-00"), { view: "report", meeting: "2026-10-30T09-00-00" });
  assert.equal(hashOf({ view: "report", meeting: "2026-10-30T09-00-00" }), "#/report/2026-10-30T09-00-00");
  assert.equal(hashOf({ view: "report" }), "#/report");
});

test("every meeting offers Report a Problem in its ⋯ menu and in ⌘K", () => {
  const m = { status: "recording", live: true };
  assert.equal(meetingCommands(m).report.enabled, true);
  assert.ok(paletteCommands(m).some((c) => c.id === "report" && c.label === "Report a Problem with This Meeting"));
});

test("an error's words begin the report; the toast says where the zip is", () => {
  assert.equal(reportDraft("Not joined: boom"), "Palaver said: “Not joined: boom”\n\n");
  assert.equal(reportDraft(null), "");
  assert.equal(reportDoneText({ shown: "~/Desktop/Palaver report 2026-10-30 14-05.zip", size_text: "2.1 MB" }),
    "Report saved to ~/Desktop/Palaver report 2026-10-30 14-05.zip · 2.1 MB");
});

test("actionCatalog: every action of every ⋯ menu, toolbar and line", () => {
  const all = actionCatalog();
  for (const id of ["meeting.trash", "meeting.report", "meeting.play", "lane.notSpeaker", "lane.room", "lane.unknown", "line.split",
    "line.fixSpelling", "project.mergeInto", "person.organization", "voice.name", "term.editNote"]) {
    assert.ok(all.includes(id), id);
  }
  assert.deepEqual(all, [...new Set(all)].sort());
});

test("tracked: every call of an action is counted, and the registry is the catalog", () => {
  const counter = new UsageCounter();
  const actions = tracked("meeting", { trash: (m) => `trashed ${m}`, split: () => null }, counter);
  assert.equal(actions.trash("m1"), "trashed m1");
  actions.trash("m2");
  const body = counter.take();
  assert.deepEqual(body.events, [{ kind: "action", id: "meeting.trash" }, { kind: "action", id: "meeting.trash" }]);
  assert.deepEqual(body.catalog, { action: ["meeting.split", "meeting.trash"] });
  assert.equal(counter.take(), null);  // nothing new: nothing to post
});

test("UsageCounter: posts in batches, the catalog once, and never more than its limit", async () => {
  const sent = [];
  const counter = new UsageCounter({ send: async (b) => { sent.push(b); }, limit: 2 });
  counter.catalog("view", ["today", "people"]);
  counter.count("view", "people");
  counter.count("error", null, { text: "Not joined" });
  counter.count("view", "today");  // over the limit
  counter.flush();
  counter.count("tab", "transcript");
  counter.flush();
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent, [
    { events: [{ kind: "view", id: "people" }, { kind: "error", text: "Not joined" }], catalog: { view: ["people", "today"] } },
    { events: [{ kind: "tab", id: "transcript" }] },
  ]);
});

test("UsageCounter: a failed post bothers nobody", async () => {
  const counter = new UsageCounter({ send: async () => { throw new Error("server gone"); } });
  counter.count("view", "today");
  counter.flush();
  await new Promise((r) => setTimeout(r, 0));
});
