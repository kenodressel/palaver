// The speaker lanes' ⋯ menu and the texts of their toasts, from the meeting
// JSON alone (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { laneCommands, laneLines, labelDisplay, linesText, namingText, withName, inlinePlay, roomText, roomNameText,
  unknownText }
  from "../../palaver/webapp/static/logic.js";

const you = { label: null, name: "Timo", display: "Timo", is_user: true, clips: [] };

function speaker(label, extra = {}) {
  return { label, name: null, display: labelDisplay(label), is_user: false, named_by: null,
    recognized: null, inferred: null, clips: [{ start: 1, end: 4 }], merged: [], ...extra };
}

function meeting(speakers, extra = {}) {
  return {
    id: "2026-10-28T10-00-00", status: "ready", live: null,
    speakers: [you, ...speakers],
    transcript: [
      { speaker: "Timo", label: null, start: 0, end: 2, text: "Hallo" },
      { speaker: "Speaker 1", label: "SPEAKER_00", start: 2, end: 4, text: "Hi" },
      { speaker: "Speaker 2", label: "SPEAKER_01", start: 4, end: 6, text: "Moin" },
      { speaker: "Speaker 1", label: "SPEAKER_00", start: 6, end: 8, text: "Ja" },
    ],
    ...extra,
  };
}

const names = (items) => items.map((x) => x && x.name);

test("labelDisplay counts from one, as the server does", () => {
  assert.equal(labelDisplay("SPEAKER_00"), "Speaker 1");
  assert.equal(labelDisplay("SPEAKER_02"), "Speaker 3");
  assert.equal(labelDisplay("odd"), "odd");
});

test("laneLines counts the transcript lines of a lane", () => {
  const m = meeting([speaker("SPEAKER_00"), speaker("SPEAKER_01")]);
  assert.equal(laneLines(m, "SPEAKER_00"), 2);
  assert.equal(laneLines(m, "SPEAKER_01"), 1);
  assert.equal(laneLines(m, "SPEAKER_09"), 0);
});

test("linesText says line or lines", () => {
  assert.equal(linesText(1), "1 line");
  assert.equal(linesText(0), "0 lines");
  assert.equal(linesText(14), "14 lines");
});

test("laneCommands: Rename, Play Voice, Merge Into…, then Not a Speaker in red after a separator", () => {
  const a = speaker("SPEAKER_00");
  const m = meeting([a, speaker("SPEAKER_01")]);
  const items = laneCommands(m, a);
  assert.deepEqual(names(items), ["rename", "playVoice", "mergeInto", "unknown", "room", null, "notSpeaker"]);
  assert.deepEqual(items.filter(Boolean).map((x) => x.label),
    ["Rename", "Play Voice", "Merge Into…", "Don't Know Who This Is", "A Room, Several People", "Not a Speaker"]);
  assert.equal(items.at(-1).danger, true);
  assert.ok(items.filter(Boolean).every((x) => x.enabled));
});

test("laneCommands: no Play Voice without clips, no Merge Into… without another voice", () => {
  const a = speaker("SPEAKER_00", { clips: [] });
  assert.deepEqual(names(laneCommands(meeting([a]), a)), ["rename", "unknown", "room", null, "notSpeaker"]);
});

test("laneCommands: Not <Name> only for a name by voice or inferred", () => {
  for (const by of ["voice", "inferred"]) {
    const a = speaker("SPEAKER_00", { name: "Henrik", display: "Henrik", named_by: by });
    const items = laneCommands(meeting([a, speaker("SPEAKER_01")]), a);
    assert.deepEqual(names(items), ["rename", "playVoice", "mergeInto", "notName", "room", null, "notSpeaker"], by);
    assert.equal(items[3].label, "Not Henrik");
  }
  const mine = speaker("SPEAKER_00", { name: "Henrik", display: "Henrik", named_by: "you" });
  assert.ok(!names(laneCommands(meeting([mine]), mine)).includes("notName"));
});

test("laneCommands: merging and removing wait while the meeting is live or processing", () => {
  const a = speaker("SPEAKER_00");
  for (const extra of [{ live: { until: 60 } }, { status: "recording" }, { status: "processing" }]) {
    const items = laneCommands(meeting([a, speaker("SPEAKER_01")], extra), a).filter(Boolean);
    const enabled = Object.fromEntries(items.map((x) => [x.name, x.enabled]));
    assert.deepEqual(enabled, { rename: true, playVoice: true, mergeInto: false, unknown: false, room: false,
      notSpeaker: false },
      JSON.stringify(extra));
  }
});

test("laneCommands: a room is named as a room and can be one person again; a meeting marked whole has neither", () => {
  const room = speaker("SPEAKER_00", { shared: "room", room: "Lab", display: "Room (Lab)" });
  const items = laneCommands(meeting([room]), room);
  assert.deepEqual(items.filter(Boolean).map((x) => x.label), ["Name the Room", "Play Voice", "One Person After All", "Not a Speaker"]);
  const several = speaker("SPEAKER_00", { shared: "meeting", display: "Several people" });
  assert.deepEqual(names(laneCommands(meeting([several]), several)), ["playVoice", null, "notSpeaker"]);
});

test("laneCommands: my own lane can be several people at my mic, once the meeting is transcribed", () => {
  const m = meeting([speaker("SPEAKER_00")]);
  assert.deepEqual(laneCommands(m, you).map((x) => x.label), ["Several People at My Mic"]);
  const room = { ...you, shared: "mic", room: "" };
  assert.deepEqual(laneCommands(m, room).map((x) => x.label), ["Name the Room", "Only Me at My Mic"]);
  assert.deepEqual(laneCommands(m, { ...you, shared: "meeting" }), []);
  assert.deepEqual(laneCommands(meeting([], { status: "recording", live: { until: 3 } }), you), []);
  assert.equal(roomText(you, true, 2), "Several people at your microphone · 2 lines");
  assert.equal(roomText(you, false, 2), "Only you at your microphone");
});

test("laneCommands: a voice without a name can be one nobody knows, and be asked about again", () => {
  const a = speaker("SPEAKER_00", { unknown: true });
  const item = laneCommands(meeting([a]), a).find((x) => x?.name === "unknown");
  assert.equal(item.label, "Ask Me Again");
  assert.equal(item.danger, undefined);  // nothing is lost: no red
  for (const s of [speaker("SPEAKER_00", { name: "Henrik", display: "Henrik", named_by: "you" }),
    speaker("SPEAKER_00", { name: "Henrik", display: "Henrik", named_by: "voice" }),
    speaker("SPEAKER_00", { shared: "room", room: "Lab" })]) {
    assert.ok(!names(laneCommands(meeting([s]), s)).includes("unknown"), JSON.stringify(s));
  }
});

test("unknownText: what Don't Know and Ask Me Again did", () => {
  assert.equal(unknownText("Speaker 2", true), "Speaker 2 stays without a name · not asked again");
  assert.equal(unknownText("Speaker 2", false), "Speaker 2 is asked about again");
});

test("a room has no play button to tell who it is", () => {
  assert.equal(inlinePlay(speaker("SPEAKER_00", { shared: "room" })), false);
  assert.equal(inlinePlay(speaker("SPEAKER_00")), true);
});

test("roomText and roomNameText: what marking and naming a room did", () => {
  const a = speaker("SPEAKER_01");
  assert.equal(roomText(a, true, 3), "Speaker 2 is a room, several people · 3 lines");
  assert.equal(roomText(a, false, 3), "Speaker 2 is one person again");
  const room = speaker("SPEAKER_01", { shared: "room", room: "" });
  assert.equal(roomNameText(room, " Raum 3.12 "), "The room is now “Raum 3.12”");
  assert.equal(roomNameText(room, ""), null);
  assert.equal(roomNameText({ ...room, room: "Lab" }, ""), "The room has no name now");
});

test("namingText: a new name, a name taken back, a confirmed guess, no change", () => {
  const unnamed = speaker("SPEAKER_02");
  assert.equal(namingText(unnamed, "Henrik"), "Speaker 3 is now Henrik");
  const anna = speaker("SPEAKER_02", { name: "Anna", display: "Anna", named_by: "you" });
  assert.equal(namingText(anna, "Henrik"), "Speaker 3 is now Henrik");
  const voice = speaker("SPEAKER_02", { name: "Henrik", display: "Henrik", named_by: "voice" });
  assert.equal(namingText(voice, ""), "Speaker 3 is not Henrik");
  const guess = speaker("SPEAKER_02", { name: "Henrik", display: "Henrik", named_by: "inferred" });
  assert.equal(namingText(guess, "Henrik"), "Speaker 3 is Henrik");
  assert.equal(namingText(anna, "Anna"), null);
  assert.equal(namingText(anna, "  Anna "), null);
  assert.equal(namingText(unnamed, ""), null);
});

test("withName names a lane at once: the speaker and its transcript lines; the meeting itself stays", () => {
  const m = meeting([speaker("SPEAKER_00"), speaker("SPEAKER_01")]);
  const named = withName(m, "SPEAKER_00", " Henrik ");
  const s = named.speakers.find((x) => x.label === "SPEAKER_00");
  assert.equal(s.name, "Henrik");
  assert.equal(s.display, "Henrik");
  assert.equal(s.named_by, "you");
  assert.deepEqual(named.transcript.map((t) => t.speaker), ["Timo", "Henrik", "Speaker 2", "Henrik"]);
  // The original is untouched: it is what a failure rolls back to.
  assert.equal(m.speakers[1].name, null);
  assert.equal(m.transcript[1].speaker, "Speaker 1");
});

test("withName with an empty name leaves the lane unnamed", () => {
  const voice = speaker("SPEAKER_00", { name: "Henrik", display: "Henrik", named_by: "voice",
    recognized: { name: "Henrik", similarity: 0.8 } });
  const m = meeting([voice]);
  m.transcript[1].speaker = "Henrik";
  const s = withName(m, "SPEAKER_00", "").speakers[1];
  assert.equal(s.name, null);
  assert.equal(s.display, "Speaker 1");
  assert.equal(s.named_by, null);
  assert.equal(s.recognized, null);
  assert.equal(withName(m, "SPEAKER_00", "").transcript[1].speaker, "Speaker 1");
});

const unsure = (extra = {}) => ({ label: "SPEAKER_00", name: null, display: "Speaker 1", is_user: false,
  named_by: null, clips: [{ start: 1, end: 4 }], ...extra });

test("inlinePlay: a voice without a name, or with a guess, shows its play button", () => {
  assert.equal(inlinePlay(unsure()), true);
  assert.equal(inlinePlay(unsure({ name: "Anna", named_by: "voice" })), true);
  assert.equal(inlinePlay(unsure({ name: "Anna", named_by: "inferred" })), true);
});

test("inlinePlay: not for a name that is settled, for you, or without clips", () => {
  assert.equal(inlinePlay(unsure({ name: "Anna", named_by: "you" })), false);
  assert.equal(inlinePlay(unsure({ name: "Anna", named_by: null })), false);
  assert.equal(inlinePlay(unsure({ clips: [] })), false);
  assert.equal(inlinePlay(unsure({ clips: undefined })), false);
  assert.equal(inlinePlay(unsure({ is_user: true, label: null })), false);
});
