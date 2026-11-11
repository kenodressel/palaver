// A transcript line's toolbar and right-click menu, the word "Fix spelling"
// starts from, and the texts of a line edit and a cut
// (web/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { clock, lineCommands, lineMarks, fixableWord, lineBefore, lineEditedText, cutKind }
  from "../../web/logic.js";

function meeting(extra = {}) {
  return {
    id: "2026-10-28T10-00-00", status: "ready", live: null, has_audio: true,
    transcript: [
      { speaker: "Timo", label: null, start: 0, end: 2, text: "Hallo" },
      { speaker: "Speaker 1", label: "SPEAKER_00", start: 2, end: 4, text: "Hi" },
    ],
    ...extra,
  };
}

const names = (items) => items.map((x) => x.name);

test("clock shows minutes and seconds, hours when there are any", () => {
  assert.equal(clock(0), "0:00");
  assert.equal(clock(724.6), "12:04");
  assert.equal(clock(3725), "1:02:05");
  assert.equal(clock(-3), "0:00");
});

test("lineCommands: every action on a later line of a finished meeting, in order", () => {
  const items = lineCommands(meeting(), 1, true);
  assert.deepEqual(names(items), ["play", "edit", "speaker", "fixSpelling", "copy", "split"]);
  assert.deepEqual(items.map((x) => x.label),
    ["Play from here", "Edit", "This line is…", "Fix spelling", "Copy", "Split here"]);
  assert.ok(items.every((x) => x.enabled));
});

test("lineCommands: the first line has no Split here", () => {
  assert.ok(!names(lineCommands(meeting(), 0, true)).includes("split"));
});

test("lineCommands: live and processing meetings get no Edit, no This line is… and no Split here", () => {
  for (const m of [meeting({ status: "recording", live: { until: 30 }, has_audio: false }),
    meeting({ status: "processing" })]) {
    const n = names(lineCommands(m, 1, true));
    assert.ok(!n.includes("edit"), m.status);
    assert.ok(!n.includes("split"), m.status);
    assert.ok(!n.includes("speaker"), m.status);
    assert.ok(n.includes("copy") && n.includes("fixSpelling"), m.status);
  }
});

test("lineCommands: no Play from here without audio", () => {
  assert.ok(!names(lineCommands(meeting({ has_audio: false }), 1, true)).includes("play"));
});

test("lineCommands: Fix spelling is disabled when there is nothing to fix", () => {
  const fix = lineCommands(meeting(), 1, false).find((x) => x.name === "fixSpelling");
  assert.equal(fix.enabled, false);
});

test("lineMarks: glossed spans and unsure words, in order, never overlapping", () => {
  const t = { text: "Wir nutzen Kubernetes mit Helm und Argo", glossed: [[11, 21, "Kuberneedes"]],
    unsure: ["Argo", "Kubernetes", "Helm"] };
  assert.deepEqual(lineMarks(t), [
    { a: 11, b: 21, kind: "glossed", heard: "Kuberneedes" },
    { a: 26, b: 30, kind: "unsure" },
    { a: 35, b: 39, kind: "unsure" },
  ]);
});

test("lineMarks: an unsure word matches whole words only, any case", () => {
  const t = { text: "Argonaut und argo.", glossed: [], unsure: ["Argo"] };
  assert.deepEqual(lineMarks(t), [{ a: 13, b: 17, kind: "unsure" }]);
});

test("lineMarks: words with regex characters are taken literally", () => {
  const t = { text: "Das kostet 5$ (ca.) oder C++ heute", unsure: ["C++", "(ca.)"] };
  assert.deepEqual(lineMarks(t).map((x) => t.text.slice(x.a, x.b)), ["(ca.)", "C++"]);
});

test("lineMarks: a mark is dropped only where it overlaps one that is kept", () => {
  const t = { text: "abcdefghijklmnopqrstuvwxyz", glossed: [[0, 10, "a"], [5, 15, "b"], [12, 20, "c"]], unsure: [] };
  assert.deepEqual(lineMarks(t).map((x) => [x.a, x.b]), [[0, 10], [12, 20]]);
});

test("fixableWord: the line's first unsure or glossed word, as the line shows it", () => {
  const t = { text: "Mit Helm und Kubernetes", glossed: [[13, 23, "Kuberneedes"]], unsure: ["Helm"] };
  assert.deepEqual(fixableWord(t), { text: "Helm", a: 4, b: 8 });
  assert.equal(fixableWord({ text: "Alles klar", glossed: [], unsure: [] }), null);
  assert.equal(fixableWord({ text: "Alles klar" }), null);
});

test("lineBefore: what undo of an edit puts back", () => {
  assert.equal(lineBefore({ text: "Hallo", edited: false, heard: null }), null);
  assert.equal(lineBefore({ text: "Hallo Welt", edited: true, heard: "Hallo Wält" }), "Hallo Welt");
});

test("lineEditedText names the line by its time", () => {
  assert.equal(lineEditedText({ start: 724.2 }), "Line at 12:04 edited");
});

test("cutKind: which of the four cuts the server did", () => {
  assert.equal(cutKind({ rest: "x", joined: false }), "own");
  assert.equal(cutKind({ rest: "x", joined: true }), "next");
  assert.equal(cutKind({ rest: null, discarded: "after" }), "after");
  assert.equal(cutKind({ rest: null, discarded: "before" }), "before");
});
