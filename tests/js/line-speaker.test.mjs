// "This line is…" (#12): who a transcript line can be given to, the line to
// go on with, and what the toast says (web/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { lineCommands, lineSpeakerChoices, nextLineOfSpeaker, lineSpeakerText }
  from "../../web/logic.js";

function meeting(extra = {}) {
  return {
    id: "2026-10-29T14-00-00", status: "ready", live: null, has_audio: true,
    speakers: [
      { label: null, name: "Kim", display: "Kim", is_user: true },
      { label: "SPEAKER_00", name: "Valerie", display: "Valerie", is_user: false },
      { label: "SPEAKER_01", name: null, display: "Speaker 2", is_user: false },
    ],
    calendar: { invited: ["Timo Strauß", "Valerie"] },
    transcript: [
      { speaker: "Kim", label: null, start: 0, end: 1, text: "Hi everyone.", fixed: null },
      { speaker: "Valerie", label: "SPEAKER_00", start: 1, end: 12, text: "Welcome.", fixed: null },
      { speaker: "Speaker 2", label: "SPEAKER_01", start: 13, end: 15, text: "Numbers.", fixed: null },
      { speaker: "Kim", label: null, start: 15.5, end: 16, text: "Yes?", fixed: null },
      { speaker: "Speaker 2", label: "SPEAKER_01", start: 16, end: 18, text: "I disagree.", fixed: null },
      { speaker: "Speaker 2", label: "SPEAKER_01", start: 19, end: 21, text: "Check again.", fixed: null },
    ],
    ...extra,
  };
}

const labels = (items) => items.map((x) => (x ? x.label : "—"));

test("lineSpeakerChoices: Me, the other speakers, then invitees without a voice", () => {
  const m = meeting();
  const items = lineSpeakerChoices(m, m.transcript[2]);
  assert.deepEqual(labels(items), ["Me", "Valerie", "Timo Strauß"]);
  assert.deepEqual(items.map((x) => x.to), [{ me: true }, { label: "SPEAKER_00" }, { name: "Timo Strauß" }]);
});

test("lineSpeakerChoices: a line of mine offers the others, not me", () => {
  const m = meeting();
  assert.deepEqual(labels(lineSpeakerChoices(m, m.transcript[0])), ["Valerie", "Speaker 2", "Timo Strauß"]);
});

test("lineSpeakerChoices: a corrected line can go back; its person is not offered again", () => {
  const m = meeting();
  const t = { ...m.transcript[4], speaker: "Timo Strauß", label: "Timo Strauß", fixed: { was: "Speaker 2", from: "SPEAKER_01" } };
  const items = lineSpeakerChoices(m, t);
  assert.deepEqual(labels(items), ["Me", "Valerie", "—", "Back to Speaker 2"]);
  assert.equal(items.at(-1).to, null);
});

test("lineSpeakerChoices: someone given lines before is offered for the next ones", () => {
  const m = meeting({ calendar: null });
  m.transcript[4] = { ...m.transcript[4], speaker: "Timo Strauß", label: "Timo Strauß", fixed: { was: "Speaker 2", from: "SPEAKER_01" } };
  assert.deepEqual(labels(lineSpeakerChoices(m, m.transcript[5])), ["Me", "Valerie", "Timo Strauß"]);
});

test("lineSpeakerChoices: a line of mine moved to someone goes back to me, not to Me", () => {
  const m = meeting();
  const t = { ...m.transcript[0], speaker: "Valerie", label: "SPEAKER_00", fixed: { was: "Kim", from: null } };
  assert.deepEqual(labels(lineSpeakerChoices(m, t)), ["Speaker 2", "Timo Strauß", "—", "Back to Kim"]);
});

test("nextLineOfSpeaker: the next line the speaker had, skipping the others", () => {
  const m = meeting();
  assert.equal(nextLineOfSpeaker(m, 13, "SPEAKER_01")?.start, 16);
  assert.equal(nextLineOfSpeaker(m, 16, "SPEAKER_01")?.start, 19);
  assert.equal(nextLineOfSpeaker(m, 19, "SPEAKER_01"), null);
  assert.equal(nextLineOfSpeaker(m, 0, null)?.start, 15.5);  // my own lines
});

test("lineSpeakerText: what the toast says", () => {
  assert.equal(lineSpeakerText({ start: 16 }, "Timo Strauß"), "Line at 0:16 → Timo Strauß");
  assert.equal(lineSpeakerText({ start: 76 }, "Me"), "Line at 1:16 → Me");
  assert.equal(lineSpeakerText({ start: 16 }, null, "Speaker 2"), "Line at 0:16 → Speaker 2 again");
});

test("lineCommands: This line is… for a finished meeting's lines only", () => {
  const items = lineCommands(meeting(), 1, true);
  assert.deepEqual(items.map((x) => x.name), ["play", "edit", "speaker", "fixSpelling", "copy", "split"]);
  assert.equal(items[2].label, "This line is…");
  assert.ok(!lineCommands(meeting({ status: "processing" }), 1, true).some((x) => x.name === "speaker"));
  assert.ok(!lineCommands(meeting(), 1, true, { review: true }).some((x) => x.name === "speaker"));  // not in Review
});
