// The user's own notes (#44): light markdown, Enter in a list, the meeting time.
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseNote, inline, splitAt, toggleBold, meetingTime, forSave, chipText, mergeNotes, splitLong, keyOf, notesText }
  from "../../web/mynotes-logic.js";

test("bold text, and stars that are no bold", () => {
  assert.deepEqual(inline("ask about **the budget** now", 0), [
    { text: "ask about ", bold: false, src: 0 },
    { text: "the budget", bold: true, src: 12 },
    { text: " now", bold: false, src: 24 },
  ]);
  assert.deepEqual(inline("2 ** 3 and **open", 5), [{ text: "2 ** 3 and **open", bold: false, src: 5 }]);
  assert.deepEqual(inline("****", 0), [{ text: "****", bold: false, src: 0 }]);
});

test("lines become paragraphs, bullet lists and numbered lists", () => {
  const blocks = parseNote("Budget\nfrozen\n- one\n* two\n  - nested\n\n3. three\n4) four\nend");
  assert.deepEqual(blocks.map((b) => b.type), ["p", "ul", "ol", "p"]);
  assert.deepEqual(blocks[0].lines.map((l) => l.map((s) => s.text).join("")), ["Budget", "frozen"]);
  assert.deepEqual(blocks[1].items.map((i) => [i.level, i.segments[0].text, i.segments[0].src]),
    [[0, "one", 16], [0, "two", 22], [1, "nested", 30]]);
  assert.equal(blocks[2].start, 3);
  assert.deepEqual(blocks[2].items.map((i) => i.segments[0].text), ["three", "four"]);
  assert.deepEqual(parseNote(""), []);
});

test("user text stays text: no markup is made of it", () => {
  const [p] = parseNote("<img src=x onerror=alert(1)> **<b>hi</b>**");
  assert.deepEqual(p.lines[0].map((s) => [s.text, s.bold]), [["<img src=x onerror=alert(1)> ", false], ["<b>hi</b>", true]]);
});

test("Enter splits a paragraph where the caret is", () => {
  assert.deepEqual(splitAt("Budget frozen", 6, 6), { current: "Budget", next: " frozen", caret: 0 });
  assert.deepEqual(splitAt("Budget frozen", 6, 13), { current: "Budget", next: "", caret: 0 });
});

test("Enter in a list goes on with the list, and ends it on an empty item", () => {
  assert.deepEqual(splitAt("- one", 5, 5), { current: "- one", next: "- ", caret: 2 });
  assert.deepEqual(splitAt("* one", 5, 5), { current: "* one", next: "* ", caret: 2 });
  assert.deepEqual(splitAt("  - deep", 8, 8), { current: "  - deep", next: "  - ", caret: 4 });
  assert.deepEqual(splitAt("9. nine", 7, 7), { current: "9. nine", next: "10. ", caret: 4 });
  assert.deepEqual(splitAt("- one two", 5, 5), { current: "- one", next: "- two", caret: 2 });
  assert.deepEqual(splitAt("- ", 2, 2), { current: "", next: null, caret: 0 });
  assert.deepEqual(splitAt("a\n- ", 4, 4), { current: "a", next: null, caret: 1 });
});

test("⌘B makes the selection bold, and plain again", () => {
  assert.deepEqual(toggleBold("ask budget now", 4, 10), { text: "ask **budget** now", start: 6, end: 12 });
  assert.deepEqual(toggleBold("ask **budget** now", 6, 12), { text: "ask budget now", start: 4, end: 10 });
  assert.deepEqual(toggleBold("ask", 3, 3), { text: "ask****", start: 5, end: 5 });
});

test("the meeting time now, from when the recording started", () => {
  const start = "2026-10-27T11:00:00+01:00";
  assert.equal(meetingTime(start, Date.parse("2026-10-27T11:05:12.34+01:00")), 312.3);
  assert.equal(meetingTime(start, Date.parse("2026-10-27T10:59:00+01:00")), 0);
  assert.equal(meetingTime(null, Date.now()), null);
  assert.equal(meetingTime("not a date", Date.now()), null);
});

test("what is saved: text, time and image, nothing of the editor", () => {
  assert.deepEqual(forSave([{ id: 1, text: "a", at: 3 }, { id: 2, text: "", at: null, image: "img-0123456789ab.png" }]),
    [{ text: "a", at: 3 }, { text: "", at: null, image: "img-0123456789ab.png" }]);
});

test("a paragraph's time chip", () => {
  assert.equal(chipText(312.3), "5:12");
  assert.equal(chipText(3725), "1:02:05");
  assert.equal(chipText(null), "");
});

test("Enter before the next item of a list does not double its marker", () => {
  assert.deepEqual(splitAt("- foo\n- bar", 5, 5), { current: "- foo", next: "- bar", caret: 2 });
  assert.deepEqual(splitAt("1. a\n2. b", 4, 4), { current: "1. a", next: "2. b", caret: 3 });
  assert.deepEqual(splitAt("- foo\nbar", 5, 5), { current: "- foo", next: "- bar", caret: 2 });
});

const local = (id, text, at, orig = keyOf({ text, at })) => ({ id, text, at, orig });

test("a merge keeps what changed elsewhere and re-applies what was typed here", () => {
  // Read: A, B. Typed here: B edited, C new after it. Elsewhere: P put in front (prepared notes), A kept.
  const server = [{ text: "P", at: null }, { text: "A", at: 1 }, { text: "B", at: 2 }];
  const mine = [local(1, "A", 1), local(2, "B, more", 2, keyOf({ text: "B", at: 2 })), local(3, "C", 5, null)];
  const { paragraphs, changed } = mergeNotes(server, mine);
  assert.deepEqual(paragraphs.map((p) => p.text), ["P", "A", "B, more", "C"]);
  assert.deepEqual(paragraphs.map((p) => p.id ?? null).slice(1), [1, 2, 3]);  // the editor's paragraphs keep their ids
  assert.equal(changed, true);
});

test("a merge never drops either side", () => {
  // Elsewhere, B moved away (a cut) while it was being edited here: the edit stays, at the end.
  const server = [{ text: "A", at: 1 }];
  const mine = [local(1, "A", 1), local(2, "B edited", 50, keyOf({ text: "B", at: 50 }))];
  assert.deepEqual(mergeNotes(server, mine).paragraphs.map((p) => p.text), ["A", "B edited"]);
  // Nothing typed here: the notes as they are elsewhere.
  const same = mergeNotes([{ text: "X", at: null }], [local(1, "A", 1)]);
  assert.deepEqual(same.paragraphs.map((p) => p.text), ["X"]);
  assert.equal(same.changed, false);
});

test("a paragraph over the limit becomes several", () => {
  const long = `${"a".repeat(30)}\n${"b".repeat(30)}`;
  const parts = splitLong([{ id: 1, text: long, at: 7 }, { id: 2, text: "short", at: null }], 40);
  assert.deepEqual(parts.map((p) => [p.text, p.at]), [["a".repeat(30), 7], ["b".repeat(30), 7], ["short", null]]);
  assert.equal(parts[0].id, 1);
  assert.ok(splitLong([{ text: "x".repeat(95), at: null }], 40).every((p) => p.text.length <= 40));
});

test("the notes as text, to copy when they can't be saved", () => {
  assert.equal(notesText([{ text: "A", at: 3 }, { text: "", at: 4, image: "img-0123456789ab.png" }, { text: "B", at: null }]),
    "A\n\n[image]\n\nB");
});
