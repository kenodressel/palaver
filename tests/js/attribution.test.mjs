// Links Palaver made and how sure it is (issue #48): what the event chip, the
// lanes and the project chips say, from the meeting JSON alone.
import { test } from "node:test";
import assert from "node:assert/strict";

import { linkWhy, linkTitle, yourLink, eventChangeText, eventLinkView, withName, withProject, labelDisplay,
  eventPickerChoices, EVENT_FILTER_AFTER } from "../../web/logic.js";

const link = (extra = {}) => ({ kind: "event", target: "Northwind", source: "calendar", confidence: 0.6,
  reason: "time match, 2 events overlapped", unsure: true,
  label: "Event: Northwind (time match, 2 events overlapped)", ...extra });

test("linkWhy is the reason, else what the source is called, else nothing", () => {
  assert.equal(linkWhy(link()), "time match, 2 events overlapped");
  assert.equal(linkWhy(link({ reason: "", source: "you" })), "you");
  assert.equal(linkWhy(link({ reason: "", source: "unknown" })), "");
  assert.equal(linkWhy(null), "");
});

test("linkTitle says the link, how sure, and what to do when unsure", () => {
  assert.equal(linkTitle(link()), "Event: Northwind (time match, 2 events overlapped) · 60% sure. Not sure: confirm or change it.");
  assert.equal(linkTitle(link({ source: "you", reason: "", unsure: false, confidence: null, label: "Event: Northwind (you)" })),
    "Event: Northwind (you)");
  assert.equal(linkTitle(link({ source: "unknown", reason: "", unsure: false, confidence: null, label: "Event: Northwind" })),
    "Event: Northwind · linked before Palaver kept reasons");
  assert.equal(linkTitle(null), null);
});

test("yourLink is a link the user set: sure, final", () => {
  assert.deepEqual(yourLink("speaker", "Henrik"), { kind: "speaker", target: "Henrik", source: "you", confidence: null,
    reason: "", unsure: false, label: "Speaker: Henrik (you)" });
});

test("the event line names the event with Change…; an unsure one is dotted, says why, with ✓ (#30)", () => {
  const sure = eventLinkView({ calendar: { title: "Northwind", link: link({ unsure: false, confidence: 0.9, reason: "time match" }) } });
  assert.deepEqual(sure, { kind: "link", title: "Northwind", why: null, unsure: false, canConfirm: false });
  const unsure = eventLinkView({ calendar: { title: "Northwind", link: link() } });
  assert.deepEqual(unsure, { kind: "link", title: "Northwind", why: "time match, 2 events overlapped", unsure: true, canConfirm: true });
  // Stored before links kept theirs: still the event, with Change….
  assert.equal(eventLinkView({ calendar: { title: "Northwind" } }).kind, "link");
});

test("no event: Pick… while the calendar is on, nothing without it; overlapping events ask which one", () => {
  assert.deepEqual(eventLinkView({ calendar: null, event_question: null, calendar_on: true }), { kind: "none" });
  assert.equal(eventLinkView({ calendar: null, event_question: null, calendar_on: false }), null);
  assert.equal(eventLinkView({ calendar: null }), null);
  const choices = [{ key: "a|2026-10-27", title: "Contoso sync" }, { key: "l|2026-10-27", title: "Northwind" }];
  const asking = eventLinkView({ calendar: null, calendar_on: true, event_question: { reason: "2 events overlapped the recording", choices } });
  assert.deepEqual(asking, { kind: "question", why: "2 events overlapped the recording", choices });
});

test("the toast after choosing the event", () => {
  assert.equal(eventChangeText(null, null), "Event changed to “none”");
  assert.equal(eventChangeText("current", "Northwind"), "Event confirmed: “Northwind”");
  assert.equal(eventChangeText("l|2026-10-27", "Northwind"), "Event changed to “Northwind”");
});

test("naming a lane makes its link yours at once; taking the name back leaves none", () => {
  const m = {
    speakers: [{ label: "SPEAKER_00", name: "Tom", display: "Tom", is_user: false, named_by: "voice",
      link: link({ kind: "speaker", target: "Tom", source: "voice" }) }],
    transcript: [],
  };
  assert.deepEqual(withName(m, "SPEAKER_00", "Henrik").speakers[0].link, yourLink("speaker", "Henrik"));
  assert.equal(withName(m, "SPEAKER_00", "").speakers[0].link, null);
  assert.equal(withName(m, "SPEAKER_00", "").speakers[0].display, labelDisplay("SPEAKER_00"));
});

test("a project confirmed at once is a sure link", () => {
  const m = { projects: [{ id: "b2", name: "Foundry", by: "auto", why: "title", link: link({ kind: "project" }) }],
    project_suggestions: [], all_projects: [] };
  assert.deepEqual(withProject(m, { project: "b2" }).projects[0].link, yourLink("project", "Foundry"));
});

test("the event picker's filter keeps the events whose title has the words, in their order (#28)", () => {
  const events = [{ key: "a", title: "Contoso weekly", overlaps: true }, { key: "b", title: "1:1 Timo Strauß", overlaps: false },
    { key: "c", title: "Zürich offsite", overlaps: false }, { key: "d", title: "Contoso Sync", overlaps: false }];
  assert.equal(eventPickerChoices(events), events);
  assert.equal(eventPickerChoices(events, "  "), events);
  assert.deepEqual(eventPickerChoices(events, "contoso").map((e) => e.key), ["a", "d"]);
  assert.deepEqual(eventPickerChoices(events, " STRAUß ").map((e) => e.key), ["b"]);
  assert.deepEqual(eventPickerChoices(events, "zurich").map((e) => e.key), ["c"]);
  assert.deepEqual(eventPickerChoices(events, "nothing like it"), []);
  assert.equal(EVENT_FILTER_AFTER, 8);
});
