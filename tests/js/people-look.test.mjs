// One person, one look (UI cleanup 2026-10-30): a named person's colour is
// the same in every meeting and on every page; the header's people, the
// projects beside them, "About this recording", and names marked in text.
import { test } from "node:test";
import assert from "node:assert/strict";

import { personHue, personColor, laneColors, meetingPeople, attendeeTokens, ownerTokens, nameMarks, lineMarks,
  fixableWord, projectView, aboutLines, calendarHint, eventLinkView, sameTitle }
  from "../../web/logic.js";

// --- the colour of a person ------------------------------------------------------

test("a person's colour comes from the name: the same everywhere, whatever the case or spaces", () => {
  for (const name of ["Anna", "Jonas Weber", "Mara Fischer", "Strauß", "Ольга"]) {
    const hue = personHue(name);
    assert.ok(Number.isInteger(hue) && hue >= 0 && hue < 8, `${name}: ${hue}`);
    assert.equal(personHue(` ${name.toLowerCase().replace(" ", "  ")} `), hue);
  }
  assert.equal(personColor("Anna"), `var(--v${personHue("Anna")})`);
  assert.equal(personColor(""), null);
  assert.equal(personColor(null), null);
});

test("the colours are pinned: changing the hash would repaint everyone", () => {
  assert.deepEqual(["Anna", "Bob", "Carla", "Dana", "Eli", "Jonas Weber", "Mara Fischer", "Timo"].map(personHue),
    [5, 6, 0, 0, 2, 1, 6, 0]);
});

test("names spread over the eight colours", () => {
  const names = ["Anna", "Bob", "Carla", "Dana", "Eli", "Fritz", "Gabi", "Hans", "Ines", "Jonas", "Klara", "Lena"];
  assert.ok(new Set(names.map(personHue)).size >= 6);
});

test("the user is always the violet of 'you'", () => {
  assert.equal(personColor("Timo", "Timo"), "var(--you)");
  assert.equal(personColor("timo ", "Timo"), "var(--you)");
  assert.equal(personColor("Anna", "Timo"), personColor("Anna"));
});

// --- lanes -------------------------------------------------------------------------

const you = { label: null, name: "Timo", display: "Timo", is_user: true, org: "Contoso" };
const anna = { label: "SPEAKER_00", name: "Anna", display: "Anna", org: "Contoso" };
const unnamed = { label: "SPEAKER_01", name: null, display: "Speaker 2" };
const carla = { label: "SPEAKER_02", name: "Carla", display: "Carla" };

test("named lanes take the person's colour, the user's lane violet", () => {
  const colors = laneColors([you, anna, unnamed, carla], new Map());
  assert.equal(colors.get("__you"), "var(--you)");
  assert.equal(colors.get("SPEAKER_00"), personColor("Anna"));
  assert.equal(colors.get("SPEAKER_02"), personColor("Carla"));
});

test("an unnamed lane gets a colour no named person of the meeting has, and keeps it", () => {
  const cache = new Map();
  const first = laneColors([you, anna, unnamed, carla], cache).get("SPEAKER_01");
  assert.ok(![personColor("Anna"), personColor("Carla")].includes(first));
  // Carla gone (merged), a new voice: the unnamed lane is not repainted.
  const again = laneColors([you, anna, unnamed, { label: "SPEAKER_03", name: null }], cache);
  assert.equal(again.get("SPEAKER_01"), first);
  assert.notEqual(again.get("SPEAKER_03"), first);
});

test("naming a lane repaints only that lane", () => {
  const cache = new Map();
  const before = laneColors([you, anna, unnamed, { label: "SPEAKER_03", name: null }], cache);
  const after = laneColors([you, anna, { ...unnamed, name: "Bob" }, { label: "SPEAKER_03", name: null }], cache);
  assert.equal(after.get("SPEAKER_01"), personColor("Bob"));
  assert.equal(after.get("SPEAKER_03"), before.get("SPEAKER_03"));
});

test("a lane of several people is no person: it keeps a colour of the meeting", () => {
  const room = { label: "SPEAKER_04", name: "Anna", shared: "room", room: "Room 1" };
  const colors = laneColors([you, room], new Map());
  assert.match(colors.get("SPEAKER_04"), /^var\(--v\d\)$/);
});

// --- who was there ------------------------------------------------------------------

const withCalendar = (attendees, speakers = [you, anna, unnamed, carla]) => ({
  speakers, calendar: { title: "Foundry Pitch", attendees },
});

test("invitees who spoke come first, in their lane's colour; the silent ones have no colour", () => {
  const m = withCalendar([
    { name: "Jonas Weber", org: "Contoso" },
    { name: "Anna Berger", org: "Contoso" },
    { name: "Carla", org: "Fabrikam" },
  ]);
  const tokens = attendeeTokens(m);
  assert.deepEqual(tokens.map((t) => [t.name, t.spoke, t.color]), [
    ["Anna Berger", true, personColor("Anna")],  // her lane says "Anna": the first name is enough when only she has it
    ["Carla", true, personColor("Carla")],
    ["Jonas Weber", false, null],
  ]);
});

test("the user's own organization is left out; another goes into the tooltip only", () => {
  const [carla, julian] = attendeeTokens(withCalendar([{ name: "Jonas Weber", org: "Contoso" }, { name: "Carla", org: "Fabrikam" }]));
  assert.equal(carla.title, "Carla · Fabrikam");
  assert.equal(julian.title, "Jonas Weber · invited, no named voice");
  assert.ok(!julian.title.includes("Contoso"));
});

test("a first name two invitees share names nobody", () => {
  const m = withCalendar([{ name: "Anna Berger" }, { name: "Anna Huber" }]);
  assert.deepEqual(attendeeTokens(m).map((t) => t.spoke), [false, false]);
});

test("who declined and did not speak is not listed", () => {
  const m = withCalendar([{ name: "Jonas Weber", response: "declined" }, { name: "Carla", response: "declined" }]);
  assert.deepEqual(attendeeTokens(m).map((t) => t.name), ["Carla"]);
});

test("the organizer says so in the tooltip", () => {
  const [t] = attendeeTokens(withCalendar([{ name: "Carla", organizer: true }]));
  assert.equal(t.title, "Carla · organized it");
});

test("no calendar, no invitees", () => {
  assert.deepEqual(attendeeTokens({ speakers: [you], calendar: null }), []);
});

test("the named people of a meeting, with their colours, the user's violet", () => {
  const people = meetingPeople({ speakers: [you, anna, unnamed, carla], calendar: { attendees: [{ name: "Anna Berger" }] } });
  assert.deepEqual([...people], [["Timo", "var(--you)"], ["Anna", personColor("Anna")], ["Carla", personColor("Carla")],
    ["Anna Berger", personColor("Anna")]]);
});

test("a next step's owner is a person of the meeting, or several, or just words", () => {
  const people = meetingPeople({ speakers: [you, anna, carla], calendar: null });
  assert.deepEqual(ownerTokens("Anna", people), [{ name: "Anna", color: personColor("Anna") }]);
  assert.deepEqual(ownerTokens("Timo and Carla", people),
    [{ name: "Timo", color: "var(--you)" }, { name: "Carla", color: personColor("Carla") }]);
  assert.deepEqual(ownerTokens("Anna, Carla", people).map((t) => t.name), ["Anna", "Carla"]);
  assert.deepEqual(ownerTokens("Everyone", people), [{ name: "Everyone", color: null }]);
  assert.deepEqual(ownerTokens("Anna and the team", people), [{ name: "Anna and the team", color: null }]);
  assert.deepEqual(ownerTokens("", people), []);
});

// --- names in running text ------------------------------------------------------------

test("names are marked where they stand as words, exactly, the longest first", () => {
  const people = new Map([["Anna", "a"], ["Anna Berger", "a"], ["Carla", "c"]]);
  const text = "Anna Berger asked Carla; Annabelle and anna stayed. Carla's turn.";
  assert.deepEqual(nameMarks(text, people).map((x) => [text.slice(x.a, x.b), x.color]),
    [["Anna Berger", "a"], ["Carla", "c"], ["Carla", "c"]]);
  assert.deepEqual(nameMarks("Nothing here", people), []);
  assert.deepEqual(nameMarks("", new Map()), []);
});

test("a name never takes the place of a glossary or unsure mark", () => {
  const t = { text: "Ask Atterkring and Anna about Carla", glossed: [[4, 14, "Atter Kring"]], unsure: ["Carla"] };
  const people = new Map([["Atterkring", "x"], ["Anna", "a"], ["Carla", "c"]]);
  assert.deepEqual(lineMarks(t, people).map((x) => [t.text.slice(x.a, x.b), x.kind]),
    [["Atterkring", "glossed"], ["Anna", "name"], ["Carla", "unsure"]]);
  assert.deepEqual(lineMarks(t).map((x) => x.kind), ["glossed", "unsure"]);  // without names: as before
  assert.equal(fixableWord(t).text, "Atterkring");
});

// --- the projects beside the people ---------------------------------------------------------

const projects = (list, suggestions) => ({
  projects: list,
  project_suggestions: suggestions,
  all_projects: [{ id: "a", name: "Data Platform" }, { id: "b", name: "Internal" }, { id: "c", name: "Northwind Terminal" },
    { id: "d", name: "Foundry" }, { id: "e", name: "Litware" }],
});
const sugg = [{ id: "b", name: "Internal", why: "same people" }, { id: "c", name: "Northwind Terminal", why: "title" },
  { id: "a", name: "Data Platform", why: "words" }];

test("with a confirmed project, suggestions leave the row for the top of the picker", () => {
  const v = projectView(projects([{ id: "d", name: "Foundry", by: "you" }], sugg));
  assert.deepEqual(v.suggestions, []);
  assert.deepEqual(v.picker.map((p) => [p.name, p.suggested]), [
    ["Internal", true], ["Northwind Terminal", true], ["Data Platform", true], ["Litware", false]]);
});

test("without a confirmed project, only the best suggestion shows as a chip", () => {
  const v = projectView(projects([], sugg));
  assert.deepEqual(v.suggestions.map((s) => s.name), ["Internal"]);
  assert.deepEqual(v.picker.filter((p) => p.suggested).map((p) => p.name), ["Northwind Terminal", "Data Platform"]);
});

test("a project Palaver is unsure of is no confirmed one: it stays, and so does the best suggestion", () => {
  const v = projectView(projects([{ id: "d", name: "Foundry", by: "model" }], sugg));
  assert.deepEqual(v.suggestions.map((s) => s.name), ["Internal"]);
});

test("no suggestions: the picker lists the projects not yet on the meeting", () => {
  const v = projectView(projects([{ id: "d", name: "Foundry", by: "you" }], []));
  assert.deepEqual(v.picker.map((p) => p.name), ["Data Platform", "Internal", "Northwind Terminal", "Litware"]);
});

// --- the event: a chip when it asks, a quiet line when it differs -----------------------------

const event = (title, link = { source: "calendar", reason: "time match", unsure: false, label: `Event: ${title} (time match)` }) =>
  ({ title, attendees: [], link });

test("titles are the same when they differ only in case and spaces", () => {
  assert.ok(sameTitle(" Foundry pitch", "foundry Pitch "));
  assert.ok(!sameTitle("Foundry Pitch", "Pitch"));
});

test("the event the title already says is not shown again", () => {
  const m = { title: "foundry pitch", title_from: "notes", calendar: event("Foundry Pitch") };
  assert.equal(eventLinkView(m), null);
  assert.equal(calendarHint(m), null);
});

test("an event called otherwise shows as a quiet line, whatever made the title", () => {
  for (const from of ["you", "imported", "notes"]) {
    const m = { title: "Budget with Anna", title_from: from, calendar: event("Weekly sync") };
    assert.equal(calendarHint(m), "Calendar: Weekly sync");
    assert.equal(eventLinkView(m), null);
  }
});

test("an event Palaver is unsure of stays a chip that asks, with no quiet line beside it", () => {
  const link = { source: "calendar", reason: "time match, 2 events overlapped", unsure: true, confidence: 0.6, label: "x" };
  const m = { title: "Budget", title_from: "you", calendar: event("Weekly sync", link) };
  assert.equal(eventLinkView(m).kind, "link");
  assert.equal(calendarHint(m), null);
  const asking = { title: "Budget", calendar: null, event_question: { reason: "2 events", choices: [{ key: "k", title: "A" }] } };
  assert.equal(eventLinkView(asking).kind, "question");
  assert.equal(calendarHint(asking), null);
});

// --- About this recording -----------------------------------------------------------------

const finished = {
  status: "ready",
  recorded: "Teams call detected 12:00 · Teams call ended 12:52",
  calendar: event("Foundry Pitch"),
  transcribed_by: { engine: "openai", label: "OpenAI", sent_seconds: 3120, usd: 0.31 },
  audio_problems: [{ text: "Audio problem at 12:14 (system audio ran at the wrong speed)" }],
  imported: { from: "Anna", at: "2026-10-28T12:00:00Z", projects: ["Factory"] },
};

test("About this recording: how it started and stopped, the event's link, who transcribed it, audio, the import", () => {
  const lines = aboutLines(finished, null, (d) => "28 Oct");
  assert.deepEqual(lines.map((l) => l.kind), ["recorded", "event", "transcribed", "audio", "imported"]);
  assert.equal(lines[0].text, "Teams call detected 12:00 · Teams call ended 12:52");
  assert.equal(lines[1].text, "Event: Foundry Pitch (time match)");
  assert.equal(lines[3].text, "Audio problem at 12:14 (system audio ran at the wrong speed)");
  assert.equal(lines[4].text, "Imported from Anna, 28 Oct · Anna filed it under Factory");
});

test("while it records, the recording's own line stays in the header, not in About", () => {
  const live = { ...finished, status: "recording", live: { until: 60 }, id: "m" };
  const kinds = aboutLines(live, { meeting: "m", text: "Recording · Teams call since 12:06", warnings: ["x"] }).map((l) => l.kind);
  assert.ok(!kinds.includes("recorded") && !kinds.includes("audio"));
});

test("an unsure event is asked about in the header: About leaves it out", () => {
  const m = { ...finished, calendar: event("X", { unsure: true, label: "Event: X", reason: "" }) };
  assert.ok(!aboutLines(m, null).some((l) => l.kind === "event"));
});

test("a meeting with nothing to tell has no About lines", () => {
  assert.deepEqual(aboutLines({ status: "ready" }, null), []);
});
