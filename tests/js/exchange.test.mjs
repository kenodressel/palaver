// Export and import of a meeting as one .palaver file (#58): what the window says and sends.
import { test } from "node:test";
import assert from "node:assert/strict";

import { exportChoices, exportRequest, exportedText, isPalaverFile, collisionText, importedText, importedLine,
  voicesQuestion, inferredText, meetingCommands, paletteCommands, GLOBAL_COMMANDS, linkWhy }
  from "../../palaver/webapp/static/logic.js";

const ready = { id: "2026-10-29T10-00-00", status: "ready", transcript: [] };

test("the transcript always goes, notes are ticked, voices and audio are not", () => {
  const choices = exportChoices(ready);
  const first = Object.fromEntries(choices.map((c) => [c.key, c.always || !!c.on]));
  assert.deepEqual(first, { transcript: true, notes: true, voices: false, audio: false });
  assert.match(choices.find((c) => c.key === "voices").hint, /Biometric/);
});

test("notes written with my own notes in view are not ticked, and say why", () => {
  const notes = exportChoices({ ...ready, notes_from_my_notes: true }).find((c) => c.key === "notes");
  assert.equal(notes.on, false);
  assert.match(notes.hint, /^The summary was written with your own notes in view/);
});

test("the export request says what is ticked, and the yes for a meeting kept on this Mac", () => {
  assert.deepEqual(exportRequest({ notes: true }), { notes: true, voices: false, audio: false });
  assert.deepEqual(exportRequest({ voices: true, audio: true }, true),
    { notes: false, voices: true, audio: true, confirm_local: true });
});

test("the toast says where the file went", () => {
  assert.equal(exportedText({ name: "2026-10-29 Budget.palaver", folder: "Downloads" }),
    "Saved to Downloads: “2026-10-29 Budget.palaver”");
});

test("only .palaver files are imported", () => {
  assert.ok(isPalaverFile("2026-10-29 Budget.palaver"));
  assert.ok(isPalaverFile("X.PALAVER"));
  assert.ok(!isPalaverFile("notes.png"));
  assert.ok(!isPalaverFile(undefined));
});

test("the collision question says whose meeting is here", () => {
  const q = { own: true, from: "Anna", meeting: { title: "Budget review" } };
  assert.equal(collisionText(q),
    "You recorded this meeting yourself: “Budget review”. Keep yours, or add Anna’s recording as a separate meeting beside it?");
  assert.match(collisionText({ ...q, own: false }), /^This meeting was imported before/);
});

test("an imported meeting says from whom, when and where the sender filed it", () => {
  const fmt = () => "30 Oct";
  assert.equal(importedText("Budget review", { from: "Anna" }), "“Budget review” imported from Anna");
  assert.equal(importedText("Budget review", { from: "Anna", warnings: ["2 voices were left out: why."] }),
    "“Budget review” imported from Anna · 2 voices were left out: why.");
  assert.equal(importedLine({ from: "Anna", at: "2026-10-30T10:00:00+01:00", projects: [] }, fmt),
    "Imported from Anna, 30 Oct");
  assert.equal(importedLine({ from: "Anna", at: null, projects: ["Northwind", "Budget"] }, fmt),
    "Imported from Anna · Anna filed it under Northwind and Budget");
  assert.equal(importedLine(null), null);
});

test("the voices question names the people and what a yes does", () => {
  assert.equal(voicesQuestion([], "Anna"), null);
  assert.match(voicesQuestion([{ label: "SPEAKER_00", name: "Tom" }, { label: "SPEAKER_01", name: "Carla" }], "Anna"),
    /^Anna sent the voices of Tom and Carla\. Add them to your voice bank\?.*count as confirmed\.$/);
});

test("a name from an import says who named the speaker", () => {
  assert.equal(inferredText({ rule: "imported", by: "Anna", how: "hand" }), "named by Anna");
  assert.equal(inferredText({ rule: "imported", by: "Anna" }), "named by Anna");
  assert.equal(inferredText({ rule: "imported", by: "Anna", how: "voice" }), "Anna’s voice match");
  assert.equal(inferredText({ rule: "imported", by: "Anna", how: "inferred" }), "Anna’s guess");
  assert.equal(inferredText({ rule: "imported", by: "Anna", how: "exporter" }), "Anna’s microphone");
  assert.equal(inferredText({ rule: "calendar" }), "from the calendar");
  assert.equal(inferredText({ rule: "new" }), "inferred");
  assert.equal(inferredText(null), "");
});

test("Export is a command of a finished meeting, in ⌘K too; Import needs no meeting", () => {
  assert.equal(meetingCommands(ready).export.enabled, true);
  assert.equal(meetingCommands({ ...ready, status: "processing" }).export.enabled, false);
  assert.equal(meetingCommands({ ...ready, live: true }).export.enabled, false);
  assert.ok(paletteCommands(ready).some((c) => c.id === "export" && c.label === "Export Meeting…"));
  assert.deepEqual(GLOBAL_COMMANDS.map((c) => c.id), ["importMeeting"]);
});

test("an event linked by an import says so", () => {
  assert.equal(linkWhy({ source: "imported", reason: "" }), "imported");
});
