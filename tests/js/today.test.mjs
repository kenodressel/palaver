// Today and "Needs you": what the strip of a meeting says, which cards Today
// shows, the question each card asks, and when the next meeting starts
// (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { needsSummary, needCards, needQuestion, startsInText, cutAtPointer, navCount }
  from "../../palaver/webapp/static/logic.js";

const review = { kind: "review" };

test("needsSummary: the things to check, without the review itself", () => {
  assert.equal(needsSummary([review]), null);
  assert.equal(needsSummary([]), null);
  const s = needsSummary([
    { kind: "unnamed", label: "SPEAKER_01", display: "Speaker 2" },
    { kind: "unnamed", label: "SPEAKER_02", display: "Speaker 3" },
    { kind: "project", project: "p1", name: "Foundry" },
    { kind: "cut", at: 432, event: "Weekly" },
    review,
  ]);
  assert.equal(s.count, 4);
  assert.equal(s.text, "4 things to check");
  assert.deepEqual(s.parts, ["may run into “Weekly”", "2 voices without a name", "project to confirm"]);
  assert.equal(s.lead, "4 things to check");
  assert.deepEqual(s.targets, [{ kind: "cut", at: 432 }, { kind: "unnamed", label: "SPEAKER_01" },
    { kind: "project", project: "p1" }]);
  // One part says it all: no count before it.
  assert.deepEqual(needsSummary([{ kind: "speaker", label: "SPEAKER_03", name: "Carla" }, review]),
    { count: 1, text: "1 thing to check", lead: null, parts: ["a name to confirm"],
      targets: [{ kind: "speaker", label: "SPEAKER_03" }] });
  assert.equal(needsSummary([{ kind: "event", title: "Sync" }, { kind: "project", project: "p" }]).lead, "2 things to check");
  assert.deepEqual(needsSummary([{ kind: "no_event" }]).targets, [{ kind: "event" }]);
  assert.deepEqual(needsSummary([{ kind: "which_event" }]).parts, ["which event?"]);
  assert.deepEqual(needsSummary([{ kind: "no_event" }]).parts, ["no calendar event"]);
  assert.deepEqual(needsSummary([{ kind: "event", title: "Sync" }]).parts, ["event to confirm"]);
});

const needs = {
  count: 3,
  meetings: [
    { id: "m3", title: "Weekly", items: [{ kind: "unnamed", label: "S1" }, { kind: "project", project: "p" }, review] },
    { id: "m2", title: "Design", items: [review] },
    { id: "m1", title: "Old", items: [{ kind: "cut", at: 10 }, review] },
  ],
};

test("needCards: every question, newest meeting first; a meeting with none asks for its review", () => {
  const { cards, more } = needCards(needs, 10);
  assert.deepEqual(cards.map((c) => [c.meeting.id, c.item.kind]),
    [["m3", "unnamed"], ["m3", "project"], ["m2", "review"], ["m1", "cut"]]);
  assert.equal(more, 0);
  assert.equal(cards[0].key, "m3|unnamed|S1");
  assert.equal(cards[1].key, "m3|project|p");
});

test("needCards: capped, and says how many more there are", () => {
  const { cards, more } = needCards(needs, 2);
  assert.equal(cards.length, 2);
  assert.equal(more, 2);
  assert.deepEqual(needCards(null, 5), { cards: [], more: 0 });
});

test("needQuestion asks each kind plainly", () => {
  assert.deepEqual(needQuestion({ kind: "unnamed", display: "Speaker 2", talk_seconds: 75, guesses: ["Bob"] }),
    { text: "Who is Speaker 2?", detail: "1 min of talk" });
  assert.deepEqual(needQuestion({ kind: "unnamed", display: "Speaker 2", talk_seconds: 12, guesses: [] }),
    { text: "Who is Speaker 2?", detail: "12 s of talk" });
  assert.deepEqual(needQuestion({ kind: "speaker", display: "Speaker 3", name: "Carla", why: "the one invitee left" }),
    { text: "Is Speaker 3 Carla?", detail: "the one invitee left" });
  assert.deepEqual(needQuestion({ kind: "project", name: "Foundry", why: "title" }),
    { text: "Part of Foundry?", detail: "title" });
  assert.deepEqual(needQuestion({ kind: "which_event", reason: "2 events overlapped the recording" }),
    { text: "Which calendar event was it?", detail: "2 events overlapped the recording" });
  assert.deepEqual(needQuestion({ kind: "event", title: "Sync", why: "time match" }),
    { text: "Was it “Sync”?", detail: "time match" });
  assert.deepEqual(needQuestion({ kind: "no_event" }),
    { text: "Which calendar event was it?", detail: "None is linked yet" });
  assert.deepEqual(needQuestion({ kind: "cut", at: 432, event: "Weekly", why: "new voices" }),
    { text: "Runs into “Weekly” at 7:12?", detail: "new voices" });
  assert.deepEqual(needQuestion(review), { text: "Did it come out right?", detail: "Nothing open, not reviewed yet" });
});

test("startsInText: how soon the next meeting starts", () => {
  const now = new Date("2026-10-30T13:35:00+01:00");
  const at = (hm) => new Date(`2026-10-30T${hm}:00+01:00`).toISOString();
  assert.equal(startsInText(at("14:00"), at("14:30"), now), "In 25 min");
  assert.equal(startsInText(at("13:36"), at("14:30"), now), "In 1 min");
  assert.equal(startsInText(at("15:45"), at("16:00"), now), "In 2 h 10 min");
  assert.equal(startsInText(at("16:35"), at("17:00"), now), "In 3 h");
  assert.equal(startsInText(at("13:30"), at("14:00"), now), "Now");
  assert.equal(startsInText(at("12:00"), at("13:00"), now), null);  // over
  assert.equal(startsInText("2026-10-31T09:00:00+01:00", "2026-10-31T09:30:00+01:00", now), null);  // not soon
});

test("navCount: the meetings waiting, nothing at none", () => {
  assert.equal(navCount({ count: 3 }), "3");
  assert.equal(navCount({ count: 120 }), "99+");
  assert.equal(navCount({ count: 0 }), null);
  assert.equal(navCount(null), null);
});

test("cutAtPointer: the line start nearest the pointer, never the first line", () => {
  const lines = [{ start: 0 }, { start: 5 }, { start: 20 }, { start: 38 }];
  assert.deepEqual(cutAtPointer(0.5, 40, lines), { at: 20, i: 2 });   // 20 s
  assert.deepEqual(cutAtPointer(0.0, 40, lines), { at: 5, i: 1 });    // before the second line
  assert.deepEqual(cutAtPointer(0.92, 40, lines), { at: 38, i: 3 });  // 36.8 s
  assert.deepEqual(cutAtPointer(1.5, 40, lines), { at: 38, i: 3 });
  assert.equal(cutAtPointer(0.5, 40, [{ start: 0 }]), null);
});
