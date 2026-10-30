// Getting back: where a hash points, push or replace, how deep the window's
// own history is, and which keys and mouse buttons go back or forward
// (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { placeOf, hashOf, historyStep, navStart, navPush, navArrive, keyNav, mouseNav, samePlace, undoStep }
  from "../../palaver/webapp/static/logic.js";

test("placeOf reads every page the window has", () => {
  assert.deepEqual(placeOf(""), { view: "today" });  // the window opens on Today
  assert.deepEqual(placeOf("#"), { view: "today" });
  assert.deepEqual(placeOf("#/"), { view: "today" });
  assert.deepEqual(placeOf("#/today"), { view: "today" });
  assert.deepEqual(placeOf("#/meetings"), { view: "meetings", id: null });
  assert.deepEqual(placeOf("#/2026-10-21T16-29-29"), { view: "meetings", id: "2026-10-21T16-29-29" });
  assert.deepEqual(placeOf("#/people"), { view: "people", focus: null });
  assert.deepEqual(placeOf("#/people/Anna%20Berger"), { view: "people", focus: "Anna Berger" });
  assert.deepEqual(placeOf("#/projects"), { view: "projects", focus: null });
  assert.deepEqual(placeOf("#/projects/p3"), { view: "projects", focus: "p3" });
  assert.deepEqual(placeOf("#/glossary"), { view: "glossary" });
  assert.deepEqual(placeOf("#/settings"), { view: "settings" });
  assert.deepEqual(placeOf("#/review"), { view: "review" });
  assert.deepEqual(placeOf("#/coach"), { view: "coach" });
  assert.deepEqual(placeOf("#/upcoming/abc%2F1"), { view: "prep", key: "abc/1" });
});

test("hashOf is placeOf the other way round", () => {
  for (const hash of ["#/today", "#/meetings", "#/2026-10-21T16-29-29", "#/people", "#/people/Anna%20Berger", "#/projects",
    "#/projects/p3", "#/glossary", "#/settings", "#/review", "#/coach", "#/upcoming/abc%2F1"]) {
    assert.equal(hashOf(placeOf(hash)), hash);
  }
  assert.equal(hashOf({ view: "meetings", id: null }), "#/meetings");
  assert.ok(samePlace("", "#/today") && samePlace("#/", "#/today"));
});

test("historyStep: somewhere else is a new entry, the same place is replaced", () => {
  assert.equal(historyStep("#/a", "#/people"), "push");
  assert.equal(historyStep("#/a", "#/b"), "push");
  assert.equal(historyStep("#/a", "#/a"), "replace");          // a refresh of the open meeting
  assert.equal(historyStep("", "#/"), "replace");              // all three are the start
  assert.equal(historyStep("#", "#/"), "replace");
  assert.equal(historyStep("#/a", "#/b", "replace"), "replace");  // the next meeting after a trash
  assert.equal(historyStep("#/a", "#/b", "none"), "none");     // Back or Forward already moved there
  assert.equal(historyStep("#/a", "#/a", "none"), "none");
});

test("navStart: a fresh window has nowhere to go; a reload keeps its depth", () => {
  assert.deepEqual(navStart(null, null), { depth: 0, top: 0 });
  assert.deepEqual(navStart(null, 4), { depth: 0, top: 0 });  // a new page: the old count is not ours
  assert.deepEqual(navStart({ depth: 2 }, 3), { depth: 2, top: 3 });
  assert.deepEqual(navStart({ depth: 2 }, null), { depth: 2, top: 2 });
  assert.deepEqual(navStart({ depth: 2 }, 1), { depth: 2, top: 2 });
});

test("navPush goes one deeper, and there is nothing forward any more", () => {
  assert.deepEqual(navPush({ depth: 0, top: 0 }), { depth: 1, top: 1 });
  assert.deepEqual(navPush({ depth: 1, top: 3 }), { depth: 2, top: 2 });
});

test("navArrive: Back and Forward land on an entry that knows its depth", () => {
  const nav = { depth: 3, top: 3 };
  assert.deepEqual(navArrive(nav, { depth: 2 }), { depth: 2, top: 3 });  // Back
  assert.deepEqual(navArrive({ depth: 2, top: 3 }, { depth: 3 }), { depth: 3, top: 3 });  // Forward
  assert.deepEqual(navArrive(nav, { depth: 0, scroll: 120 }), { depth: 0, top: 3 });
});

test("navArrive: an entry without a depth is a new one (a link or a notification set the hash)", () => {
  assert.deepEqual(navArrive({ depth: 1, top: 3 }, null), { depth: 2, top: 2 });
  assert.deepEqual(navArrive({ depth: 0, top: 0 }, {}), { depth: 1, top: 1 });
});

const key = (k, extra = {}) => ({ key: k, code: "", metaKey: true, ctrlKey: false, altKey: false, shiftKey: false, repeat: false, ...extra });

test("keyNav: ⌘[ goes back and ⌘] forward", () => {
  assert.equal(keyNav(key("[", { code: "BracketLeft" })), "back");
  assert.equal(keyNav(key("]", { code: "BracketRight" })), "forward");
});

test("keyNav: the same keys on a German keyboard (ü and + where [ and ] are)", () => {
  assert.equal(keyNav(key("ü", { code: "BracketLeft" })), "back");
  assert.equal(keyNav(key("+", { code: "BracketRight" })), "forward");
});

test("keyNav: not without ⌘, not with other modifiers, not for a held key", () => {
  assert.equal(keyNav(key("[", { metaKey: false })), null);
  assert.equal(keyNav(key("[", { shiftKey: true })), null);
  assert.equal(keyNav(key("[", { altKey: true })), null);
  assert.equal(keyNav(key("[", { ctrlKey: true })), null);
  assert.equal(keyNav(key("[", { repeat: true })), null);
  assert.equal(keyNav(key("j", { code: "KeyJ" })), null);
});

test("mouseNav: the mouse's back and forward buttons", () => {
  assert.equal(mouseNav({ button: 3 }), "back");
  assert.equal(mouseNav({ button: 4 }), "forward");
  assert.equal(mouseNav({ button: 0 }), null);
  assert.equal(mouseNav({ button: 2 }), null);
});

test("samePlace: a page still loading is still wanted only while the hash points at it", () => {
  assert.equal(samePlace("#/a", "#/a"), true);
  assert.equal(samePlace("", "#/"), true);
  assert.equal(samePlace("#/people", "#/people"), true);
  assert.equal(samePlace("#/a", "#/people"), false);   // Back went on while meeting a loaded
  assert.equal(samePlace("#/a", "#/b"), false);
  assert.equal(samePlace("#/projects", "#/projects/p3"), false);
});

test("undoStep: an undo takes the place of the page it undid, and adds one anywhere else", () => {
  // trashed a, b opened in its place: undo on b (or still on a) replaces it
  assert.equal(undoStep("#/b", ["a", "b"]), "replace");
  assert.equal(undoStep("#/a", ["a", "b"]), "replace");
  // the user went on to People, or another meeting: the meeting comes back as a new page
  assert.equal(undoStep("#/people", ["a", "b"]), "push");
  assert.equal(undoStep("#/c", ["a", "b"]), "push");
  assert.equal(undoStep("#/review", ["a"]), "push");
  assert.equal(undoStep("#/b", ["a", null]), "push");
});
