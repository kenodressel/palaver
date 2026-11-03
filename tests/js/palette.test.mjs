// The ⌘K palette: what it finds for what is typed, the commands of the open
// meeting with their shortcuts, the recent items, moving with the arrows
// (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { paletteMatch, paletteCommands, paletteRecent, paletteMove, paletteRecentShown } from "../../palaver/webapp/static/logic.js";

const entries = [
  { kind: "command", id: "trash", label: "Move to Trash", shortcut: "⌘⌫" },
  { kind: "command", id: "split", label: "Split At…" },
  { kind: "page", id: "people", label: "People" },
  { kind: "meeting", id: "m2", label: "Weekly Delivery", keywords: ["Anna Berger", "ÖNW"] },
  { kind: "meeting", id: "m1", label: "Software Foundry", keywords: ["Henrik Weiß"] },
  { kind: "person", id: "Anna Berger", label: "Anna Berger" },
  { kind: "project", id: "p1", label: "Österreichische Northwind" },
];
const labels = (xs) => xs.map((x) => x.label);

test("paletteMatch: every word must start a word of the label or its keywords", () => {
  assert.deepEqual(labels(paletteMatch("foun", entries)), ["Software Foundry"]);
  assert.deepEqual(labels(paletteMatch("soft fou", entries)), ["Software Foundry"]);
  assert.deepEqual(labels(paletteMatch("dry", entries)), []);  // not inside a word
  assert.deepEqual(labels(paletteMatch("xyz", entries)), []);
});

test("paletteMatch: a label match beats a keyword match; a label starting with it comes first", () => {
  assert.deepEqual(labels(paletteMatch("anna", entries)), ["Anna Berger", "Weekly Delivery"]);
  assert.deepEqual(labels(paletteMatch("s", entries)).slice(0, 2), ["Split At…", "Software Foundry"]);
});

test("paletteMatch: case and accents do not matter", () => {
  assert.deepEqual(labels(paletteMatch("osterr", entries)), ["Österreichische Northwind"]);
  assert.deepEqual(labels(paletteMatch("weiss", entries)), ["Software Foundry"]);
  assert.deepEqual(labels(paletteMatch("onw", entries)), ["Weekly Delivery"]);
});

test("paletteMatch: nothing typed gives nothing; the limit holds", () => {
  assert.deepEqual(paletteMatch("  ", entries), []);
  assert.equal(paletteMatch("s", entries, 2).length, 2);
});

test("paletteCommands: what applies to the open meeting, with its shortcut", () => {
  const m = { id: "m", status: "ready", has_audio: true, notes: {}, reviewed: null,
    transcript: [{ start: 0 }, { start: 5 }], neighbours: { previous: { id: "p" }, next: null } };
  const c = paletteCommands(m);
  assert.deepEqual(c.map((x) => x.id),
    ["play", "writeNotes", "rename", "changeEvent", "joinPrevious", "split", "export", "localOnly", "shared", "report",
      "deleteAudio", "trash"]);
  assert.equal(c.find((x) => x.id === "rename").label, "Rename Meeting");  // "Rename…" in the ⋯ menu
  assert.deepEqual(c.find((x) => x.id === "trash"), { kind: "command", id: "trash", label: "Move to Trash", shortcut: "⌘⌫", danger: true });
  assert.equal(c.find((x) => x.id === "writeNotes").label, "Rewrite notes");
  assert.equal(c.find((x) => x.id === "joinPrevious").shortcut, "⌘J");
  assert.deepEqual(paletteCommands(null), []);
});

test("paletteRecent: newest first, no twice, at most eight", () => {
  let recent = [];
  for (const id of ["a", "b", "c"]) recent = paletteRecent(recent, { kind: "meeting", id, label: id });
  recent = paletteRecent(recent, { kind: "meeting", id: "a", label: "a" });
  assert.deepEqual(recent.map((x) => x.id), ["a", "c", "b"]);
  recent = paletteRecent(recent, { kind: "person", id: "a", label: "a" });  // another kind, same id
  assert.equal(recent.length, 4);
  for (let i = 0; i < 20; i++) recent = paletteRecent(recent, { kind: "meeting", id: `x${i}`, label: "" });
  assert.equal(recent.length, 8);
  assert.deepEqual(paletteRecent([], { kind: "command", id: "trash", label: "Move to Trash" }), []);  // commands are not places
});

test("paletteMove wraps around", () => {
  assert.equal(paletteMove(0, 1, 3), 1);
  assert.equal(paletteMove(2, 1, 3), 0);
  assert.equal(paletteMove(0, -1, 3), 2);
  assert.equal(paletteMove(-1, 1, 3), 0);
  assert.equal(paletteMove(0, 1, 0), -1);
});

test("paletteRecentShown: only places that still exist, meetings as the list has them now", () => {
  const recent = [
    { kind: "meeting", id: "m1", label: "Old title" },
    { kind: "person", id: "Gone Person", label: "Gone Person" },
    { kind: "project", id: "p1", label: "Foundry" },
    { kind: "meeting", id: "trashed", label: "Trashed" },
    { kind: "person", id: "Anna", label: "Anna" },
    { kind: "project", id: "p9", label: "Deleted" },
  ];
  const meetings = [{ kind: "meeting", id: "m1", label: "New title" }];
  const shown = paletteRecentShown(recent, { meetings, people: ["Anna"], projects: ["p1"] });
  assert.deepEqual(shown.map((x) => x.label), ["New title", "Foundry", "Anna"]);
  assert.equal(paletteRecentShown(recent, { meetings, people: ["Anna"], projects: ["p1"] }, 2).length, 2);
});

import { settingsEntries } from "../../palaver/webapp/static/logic.js";

test("the palette finds Settings' panes by name and by what is in them", () => {
  const entries = settingsEntries();
  const first = (q) => paletteMatch(q, entries)[0]?.id;
  assert.equal(first("storage"), "storage");
  assert.equal(first("disk space"), "storage");
  assert.equal(first("realtime"), "recording");
  assert.equal(first("gemma"), "language-model");
  assert.equal(first("uninstall"), "update");
  assert.equal(paletteMatch("settings", entries).length, entries.length);
  assert.ok(entries.every((e) => e.kind === "setting" && e.detail === "Settings"));
});
