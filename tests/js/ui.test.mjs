// The pure parts of the window's shared UI pieces (palaver/webapp/static/ui.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { UndoHistory, commandFor, isEditable, isTextField, matchesShortcut, play } from "../../palaver/webapp/static/ui.js";

test("UndoHistory keeps the last 20", async () => {
  const history = new UndoHistory();
  const undone = [];
  for (let i = 1; i <= 25; i++) {
    history.push({ label: `change ${i}`, undo: async () => { undone.push(i); } });
  }
  assert.equal(history.size, 20);
  assert.equal(await history.undoLast(), "change 25");
  assert.deepEqual(undone, [25]);
  assert.equal(history.size, 19);
  assert.equal(await history.undoLast(), "change 24");
});

test("UndoHistory drops the oldest beyond its limit", async () => {
  const history = new UndoHistory(2);
  for (const label of ["a", "b", "c"]) history.push({ label, undo: async () => {} });
  assert.equal(history.size, 2);
  assert.equal(await history.undoLast(), "c");
  assert.equal(await history.undoLast(), "b");
  assert.equal(await history.undoLast(), null);
});

test("UndoHistory.has: false once the entry was undone or taken out", async () => {
  const history = new UndoHistory();
  const a = { label: "a", undo: async () => {} };
  const b = { label: "b", undo: async () => {} };
  history.push(a);
  history.push(b);
  assert.ok(history.has(a) && history.has(b));
  await history.undoLast();
  assert.ok(history.has(a) && !history.has(b));
  history.remove(a);
  assert.ok(!history.has(a));
});

test("undoLast on empty returns null", async () => {
  assert.equal(await new UndoHistory().undoLast(), null);
});

test("shortcut guard ignores editable targets", () => {
  assert.equal(isEditable({ tagName: "INPUT" }), true);
  assert.equal(isEditable({ tagName: "TEXTAREA" }), true);
  assert.equal(isEditable({ tagName: "SELECT" }), true);
  assert.equal(isEditable({ tagName: "DIV", isContentEditable: true }), true);
  assert.equal(isEditable({ tagName: "BUTTON" }), false);
  assert.equal(isEditable({ tagName: "INPUT", type: "checkbox" }), false);
  assert.equal(isEditable(null), false);
});

test("cmd-z edits text only in text fields, not in a select", () => {
  assert.equal(isTextField({ tagName: "SELECT" }), false);
  assert.equal(isTextField({ tagName: "INPUT", type: "text" }), true);
  assert.equal(isTextField({ tagName: "INPUT", type: "search" }), true);
  assert.equal(isTextField({ tagName: "INPUT", type: "checkbox" }), false);
  assert.equal(isTextField({ tagName: "TEXTAREA" }), true);
  assert.equal(isTextField({ tagName: "DIV", isContentEditable: true }), true);
  assert.equal(isTextField(null), false);
});

test("shortcuts match their keys and modifiers exactly", () => {
  const key = (k, mods = {}) => ({ key: k, metaKey: false, shiftKey: false, altKey: false, ctrlKey: false, ...mods });
  assert.equal(matchesShortcut("⌘J", key("j", { metaKey: true })), true);
  assert.equal(matchesShortcut("⌘J", key("j")), false);
  assert.equal(matchesShortcut("⌘J", key("J", { metaKey: true, shiftKey: true })), false);
  assert.equal(matchesShortcut("⌘⇧N", key("N", { metaKey: true, shiftKey: true })), true);
  assert.equal(matchesShortcut("⌘⌫", key("Backspace", { metaKey: true })), true);
  assert.equal(matchesShortcut("⌘Z", key("z", { metaKey: true })), true);
  assert.equal(matchesShortcut("⌘Z", key("z", { metaKey: true, shiftKey: true })), false);
});

test("a shortcut runs its command once: not on key repeat, not in a field", () => {
  const entries = [["trash", { shortcut: "⌘⌫" }], ["joinPrevious", { shortcut: "⌘J" }], ["split", {}]];
  const key = (k, extra = {}) => ({ key: k, metaKey: true, shiftKey: false, altKey: false, ctrlKey: false,
    target: { tagName: "BODY" }, ...extra });
  assert.equal(commandFor(key("Backspace"), entries), "trash");
  assert.equal(commandFor(key("j"), entries), "joinPrevious");
  assert.equal(commandFor(key("Backspace", { repeat: true }), entries), null);
  assert.equal(commandFor(key("j", { repeat: true }), entries), null);
  assert.equal(commandFor(key("Backspace", { target: { tagName: "INPUT", type: "text" } }), entries), null);
  assert.equal(commandFor(key("x"), entries), null);
});

test("play: a pause before playback started is no error", async () => {
  const warned = [];
  const media = { play: () => Promise.reject(Object.assign(new Error("The operation was aborted."), { name: "AbortError" })) };
  await play(media, (...args) => warned.push(args));  // resolves: nothing left unhandled
  assert.deepEqual(warned, []);
});

test("play: another failure is a warning, never a rejection", async () => {
  const warned = [];
  const failure = Object.assign(new Error("not supported"), { name: "NotSupportedError" });
  await play({ play: () => Promise.reject(failure) }, (...args) => warned.push(args));
  assert.deepEqual(warned, [["Playback failed:", failure]]);
  const thrown = new Error("old engine");
  await play({ play: () => { throw thrown; } }, (...args) => warned.push(args));
  assert.equal(warned[1][1], thrown);
});

test("play: playback that starts is passed through", async () => {
  let started = 0;
  await play({ play: () => { started += 1; return Promise.resolve(); } }, () => assert.fail("no warning"));
  await play({ play: () => { started += 1; } }, () => assert.fail("no warning"));  // an engine without a promise
  assert.equal(started, 2);
});
