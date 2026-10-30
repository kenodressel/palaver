// The search in the meeting list (#46): taking a filter out of the text,
// what a notes hit is called, related meetings beside the found ones
// (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { withoutSpan, noteKind, relatedOnly, firstMoment } from "../../palaver/webapp/static/logic.js";

test("withoutSpan takes a filter out with the little word that joined it", () => {
  const q = "Anna and Tom last month";
  assert.equal(withoutSpan(q, [0, 4]), "Tom last month");
  assert.equal(withoutSpan(q, [9, 12]), "Anna last month");
  assert.equal(withoutSpan(q, [13, 23]), "Anna and Tom");
  assert.equal(withoutSpan("with Henrik about pricing", [5, 11]), "about pricing");
  assert.equal(withoutSpan("in:decisions offer", [0, 12]), "offer");
  assert.equal(withoutSpan("Anna", [0, 4]), "");
});

test("noteKind names a notes hit, with its owner or section", () => {
  assert.equal(noteKind({ kind: "decision", text: "x" }), "Decision");
  assert.equal(noteKind({ kind: "step", text: "x", owner: "Anna" }), "Next step · Anna");
  assert.equal(noteKind({ kind: "step", text: "x", owner: "" }), "Next step");
  assert.equal(noteKind({ kind: "point", text: "x", heading: "Pricing" }), "Pricing");
  assert.equal(noteKind({ kind: "summary", text: "x" }), "Summary");
});

test("relatedOnly leaves out meetings the words found already", () => {
  assert.deepEqual(relatedOnly([{ id: "a" }], [{ id: "a" }, { id: "b" }]).map((r) => r.id), ["b"]);
  assert.deepEqual(relatedOnly([], null), []);
});

test("firstMoment is the first line found, by words or by meaning", () => {
  assert.equal(firstMoment({ hits: [{ start: 15 }], meaning: [] }), 15);
  assert.equal(firstMoment({ hits: [], meaning: [{ kind: "decision" }, { kind: "line", start: 42 }] }), 42);
  assert.equal(firstMoment({ hits: [], notes_hits: [{ kind: "decision" }] }), undefined);
});

test("chipRemoved puts a name back as a quoted word, and works on the text as it is now", async () => {
  const { chipRemoved } = await import("../../palaver/webapp/static/logic.js");
  const person = { kind: "person", text: "Tom", written: false };
  assert.equal(chipRemoved("Anna and Tom last month", person), 'Anna and "Tom" last month');
  assert.equal(chipRemoved("Anna and Tom last month", { kind: "project", text: "ÖNW", written: false }),
    "Anna and Tom last month");  // not there any more: nothing changes
  assert.equal(chipRemoved("önw pricing", { kind: "project", text: "ÖNW", written: false }), '"önw" pricing');
  // typed on since the search: the place is found again, not taken from old offsets
  assert.equal(chipRemoved("pricing Anna and Tom last month", { kind: "date", text: "last month", written: false }),
    "pricing Anna and Tom");
  assert.equal(chipRemoved("offer project:ÖNW", { kind: "project", text: "project:ÖNW", written: true }), "offer");
  assert.equal(chipRemoved("Tomas and Tom", person), 'Tomas and "Tom"');  // the whole word only
});

test("indexingNotice is said once, the first time the index is built", async () => {
  const { indexingNotice } = await import("../../palaver/webapp/static/logic.js");
  assert.match(indexingNotice({ indexing: true, downloading: true }, false), /470 MB/);
  assert.match(indexingNotice({ indexing: true, downloading: false }, false), /^Indexing meetings/);
  assert.equal(indexingNotice({ indexing: true, downloading: true }, true), null);  // said before
  assert.equal(indexingNotice({ indexing: false, downloading: false }, false), null);
});
