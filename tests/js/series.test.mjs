// Meeting series of Palaver's own (#39): the ⋯ menu's Add to / Move to Series… and Remove from Series, the series
// chip, the series page's texts, the list's filter, the palette and the page's place (web/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { meetingCommands, paletteCommands, seriesView, seriesChoice, seriesMovedText, seriesCommands, seriesEditText,
  seriesLede, seriesFilterGroups, seriesEntries, paletteRecentShown, placeOf, hashOf, samePlace } from "../../web/logic.js";

const weekly = { id: "s1", name: "Contoso weekly", project: "Contoso", learned: "you", calendar: false, call_title: false,
  when: "" };

test("the ⋯ menu adds a meeting to a series, moves it to another or takes it out", () => {
  let c = meetingCommands({ status: "recording" });
  assert.deepEqual([c.addToSeries.label, c.addToSeries.enabled], ["Add to Series…", true]);  // also while recording
  assert.deepEqual([c.leaveSeries.hidden, c.leaveSeries.enabled], [true, false]);
  c = meetingCommands({ status: "ready", series: weekly });
  assert.deepEqual([c.addToSeries.label, c.addToSeries.paletteLabel], ["Move to Series…", "Move Meeting to Another Series…"]);
  assert.deepEqual([c.leaveSeries.label, c.leaveSeries.hidden, c.leaveSeries.enabled], ["Remove from Series", false, true]);
  const palette = paletteCommands({ status: "ready", series: weekly }).map((x) => x.id);
  assert.ok(palette.includes("addToSeries") && palette.includes("leaveSeries"));
  assert.ok(!paletteCommands({ status: "ready" }).map((x) => x.id).includes("leaveSeries"));
});

test("a name typed picks the series of that name, any case and spacing; another one makes a new series", () => {
  const all = [weekly, { id: "s2", name: "Northwind 1:1" }];
  assert.deepEqual(seriesChoice("  contoso   WEEKLY ", all), { series: "s1", name: "Contoso weekly" });
  assert.deepEqual(seriesChoice("Kim and Anna", all), { name: "Kim and Anna" });
  assert.equal(seriesChoice("   ", all), null);
});

test("the toast says where the meeting went", () => {
  assert.equal(seriesMovedText({}, { series: weekly }), "Added to “Contoso weekly”");
  assert.equal(seriesMovedText({ series: { id: "s2", name: "Northwind 1:1" } }, { series: weekly }), "Moved to “Contoso weekly”");
  assert.equal(seriesMovedText({ series: weekly }, { series: weekly }), "Already in “Contoso weekly”");
  assert.equal(seriesMovedText({ series: weekly }, { series: null }), "Removed from “Contoso weekly”");
});

test("the chip of a series the user put together says so, with its project, and opens it", () => {
  const v = seriesView({ series: weekly });
  assert.deepEqual([v.id, v.name, v.project, v.why], ["s1", "Contoso weekly", "Contoso", "your series"]);
  assert.equal(v.title, "“Contoso weekly”: a series you put together. Click to open it.");
  // Once it knows the call's title or a calendar series, recordings join it by themselves.
  assert.equal(seriesView({ series: { ...weekly, call_title: true } }).why, "the same title in the call");
  assert.equal(seriesView({ series: { ...weekly, calendar: true, when: "Tuesdays around 15:00" } }).why,
    "its calendar series, Tuesdays around 15:00");
});

test("the series page: its ⋯, the toasts of its fields and how it came to be", () => {
  const d = { series: [weekly, { id: "s2", name: "Northwind 1:1" }] };
  assert.deepEqual(seriesCommands(d, weekly).map((c) => c && c.name), ["rename", "mergeInto", null, "delete"]);
  assert.deepEqual(seriesCommands({ series: [weekly] }, weekly).map((c) => c && c.name), ["rename", null, "delete"]);
  assert.equal(seriesCommands(d, weekly).at(-1).danger, true);
  assert.equal(seriesEditText(weekly, { name: " Contoso  jour fixe " }), "“Contoso weekly” is now “Contoso jour fixe”");
  assert.equal(seriesEditText(weekly, { project: "Northwind" }), "“Contoso weekly” is in project Northwind");
  assert.equal(seriesEditText(weekly, { project: "" }), "“Contoso weekly” is in no project now");
  assert.equal(seriesLede(weekly), "Put together by you; add recordings from their ⋯ menu.");
  assert.equal(seriesLede({ learned: "event", calendar: true, when: "Mondays around 10:00" }),
    "From a recurring calendar event you linked; new recordings join it by themselves (Mondays around 10:00).");
  assert.equal(seriesLede({ learned: "call-window", call_title: true }),
    "From a call title that repeated; new recordings join it by themselves.");
});

test("the list's filter and the palette find series from the meeting list", () => {
  const meetings = [{ id: "a", series: weekly }, { id: "b", series: weekly }, { id: "c", series: { id: "s2", name: "Northwind 1:1" } },
    { id: "d", series: null }];
  assert.deepEqual(seriesFilterGroups(meetings), [["Contoso weekly", 2, "s1"], ["Northwind 1:1", 1, "s2"]]);
  assert.deepEqual(seriesEntries(meetings), [
    { kind: "series", id: "s1", label: "Contoso weekly", detail: "Series · Contoso", keywords: ["Contoso"] },
    { kind: "series", id: "s2", label: "Northwind 1:1", detail: "Series", keywords: [] }]);
  // A series opened lately shows under Recent while it is still there.
  const recent = [{ kind: "series", id: "s1", label: "Contoso weekly" }, { kind: "series", id: "gone", label: "Old" }];
  assert.deepEqual(paletteRecentShown(recent, { series: ["s1"] }).map((r) => r.id), ["s1"]);
});

test("a series' page has a place of its own", () => {
  assert.deepEqual(placeOf("#/series/s1"), { view: "series", focus: "s1" });
  assert.deepEqual(placeOf("#/series"), { view: "series", focus: null });
  assert.equal(hashOf({ view: "series", focus: "s1" }), "#/series/s1");
  assert.equal(hashOf({ view: "series", focus: null }), "#/series");
  assert.ok(!samePlace("#/series/s1", "#/series/s2"));
});
