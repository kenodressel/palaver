// The coach's statistics page (#43): weeks, records, streaks and topics from the overview's meetings.
import { test } from "node:test";
import assert from "node:assert/strict";

import { weekOf, sizeOf, coachPoints, coachWeeks, balanceWeeks, coachStreaks, coachRecords, sizeTrend, topicsByMonth,
  niceTicks, compactNumber, hoursText } from "../../web/logic.js";

// A meeting row as GET /api/coach gives it (newest first there).
const row = (id, start, more = {}) => ({
  id, title: `Meeting ${id}`, start, people: 2, share: 0.5, fair: 0.5, wpm: 140, fillers: 1, minutes_talked: 5,
  questions: 2, questions_per_hour: 6, interruptions: 1, duration: 1800, longest: 0, fastest: null, projects: [],
  series: null, terms: [], ...more,
});

const MEETINGS = [
  row("e", "2026-11-12T10:00:00+01:00", { share: 0.7, fair: 0.333, people: 3, wpm: 170, longest: 200, fastest: 190 }),
  row("d", "2026-11-10T10:00:00+01:00", { share: 0.3, fair: 0.333, people: 3, minutes_talked: 2, wpm: 200 }),
  row("c", "2026-11-03T09:00:00+01:00", { share: 0.2, fair: 0.2, people: 6, questions: 9, duration: 5400 }),
  row("b", "2026-10-28T10:00:00+01:00", { share: 0.45, projects: ["Harbor"], series: "Weekly sync",
    terms: [{ term: "Atterkring", count: 3 }] }),
  row("a", "2026-10-27T10:00:00+01:00", { share: 0.6, projects: ["Harbor"], terms: [{ term: "Atterkring", count: 1 }] }),
];

test("weekOf is the Monday of the day as written, sizeOf the size compared", () => {
  assert.equal(weekOf("2026-10-27T23:30:00-08:00"), "2026-10-26");
  assert.equal(weekOf("2026-11-01T10:00:00+01:00"), "2026-10-26");  // a Sunday
  assert.equal(weekOf("2026-11-02"), "2026-11-02");
  assert.equal(weekOf("nonsense"), null);
  assert.deepEqual([1, 2, 3, 4, 5, 9].map(sizeOf), [null, "2", "3", "4", "5+", "5+"]);
});

test("coachPoints puts the meetings oldest first with their distance to the fair share", () => {
  const p = coachPoints([...MEETINGS, row("x", null)]);
  assert.deepEqual(p.map((r) => r.id), ["a", "b", "c", "d", "e"]);
  assert.equal(p[0].month, "2026-10");
  assert.ok(Math.abs(p[4].over - 0.367) < 1e-9);
  assert.equal(coachPoints([row("s", "2026-11-12T10:00:00", { share: null })])[0].over, null);
});

test("coachWeeks averages per week; pace and filler words only where the user talked 3 minutes or more", () => {
  const weeks = coachWeeks(coachPoints(MEETINGS));
  assert.deepEqual(weeks.map((w) => [w.week, w.meetings]), [["2026-10-26", 2], ["2026-11-02", 1], ["2026-11-09", 2]]);
  assert.equal(weeks[0].share, 0.525);
  assert.equal(weeks[2].wpm, 170);  // d talked 2 minutes
  assert.equal(weeks[1].seconds, 5400);
});

test("balanceWeeks finds the most and the least balanced week", () => {
  const { best, worst } = balanceWeeks(coachWeeks(coachPoints(MEETINGS)));
  assert.equal(worst.week, "2026-11-09");  // (0.367 - 0.033) / 2 above
  assert.equal(best.week, "2026-10-26");   // weeks of two meetings first
  assert.deepEqual(balanceWeeks([]), { best: null, worst: null });
  assert.equal(balanceWeeks([{ week: "2026-11-02", meetings: 1, over: 0.1 }]).worst, null);
});

test("coachStreaks counts weeks in a row and meetings at or under the fair share", () => {
  const p = coachPoints(MEETINGS);
  assert.deepEqual(coachStreaks(p, new Date("2026-11-18T12:00:00Z")), { weeks: 3, longestWeeks: 3, fair: 0, fairLongest: 3 });
  // Two weeks later the streak is over; the longest stays.
  assert.equal(coachStreaks(p, new Date("2026-11-30T12:00:00Z")).weeks, 0);
  const gap = coachPoints([row("y", "2026-10-01T10:00:00"), row("z", "2026-10-20T10:00:00")]);
  assert.deepEqual(coachStreaks(gap, new Date("2026-10-21T10:00:00Z")), { weeks: 1, longestWeeks: 1, fair: 2, fairLongest: 2 });
  assert.deepEqual(coachStreaks([], new Date()), { weeks: 0, longestWeeks: 0, fair: 0, fairLongest: 0 });
});

test("coachRecords names the meeting of each record", () => {
  const r = coachRecords(coachPoints(MEETINGS));
  assert.deepEqual([r.pace.id, r.pace.value], ["e", 170]);  // d's 200 is from 2 minutes
  assert.deepEqual([r.stretch.id, r.stretch.value], ["e", 190]);
  assert.deepEqual([r.monologue.id, r.questions.id, r.meeting.id], ["e", "c", "c"]);
  assert.equal(coachRecords([]).pace, null);
});

test("sizeTrend has the share per month for each size with meetings", () => {
  const t = sizeTrend(coachPoints(MEETINGS));
  assert.deepEqual(t.months, ["2026-10", "2026-11"]);
  assert.deepEqual(Object.keys(t.sizes), ["2", "3", "5+"]);
  assert.deepEqual(t.sizes["2"].map((m) => m.share), [0.525, null]);
  assert.equal(t.sizes["3"][1].meetings, 2);
});

test("topicsByMonth counts projects and series once a meeting, terms as often as said", () => {
  const t = topicsByMonth(coachPoints(MEETINGS));
  assert.deepEqual(t.months, ["2026-10", "2026-11"]);
  assert.deepEqual(t.topics, [
    { name: "Harbor", counts: [2, 0], total: 2 }, { name: "Weekly sync", counts: [1, 0], total: 1 },
  ]);
  assert.deepEqual(t.terms, [{ name: "Atterkring", counts: [4, 0], total: 4 }]);
  assert.deepEqual(topicsByMonth(coachPoints(MEETINGS), { months: 1 }).topics, []);
});

test("niceTicks, compactNumber and hoursText", () => {
  assert.deepEqual(niceTicks(0, 200), [0, 50, 100, 150, 200]);
  assert.deepEqual(niceTicks(-0.3, 0.4), [-0.4, -0.2, 0, 0.2, 0.4]);  // around both ends
  assert.deepEqual(niceTicks(127, 139), [125, 130, 135, 140]);
  assert.deepEqual(niceTicks(3, 3), [3]);
  assert.deepEqual([999, 1284, 12940, 4_230_000, null].map(compactNumber), ["999", "1,284", "12.9K", "4.2M", "–"]);
  assert.deepEqual([600, 5400, 46800, null].map(hoursText), ["10 min", "1.5 h", "13 h", "–"]);
});
