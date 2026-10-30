// A meeting's project chips, the Projects page's ⋯ and the People page's
// toasts, from the JSON alone (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { withProject, projectChange, projectCommands, renameText, voicesText,
  personCommands, voiceCommands, termCommands, termChangeText, projectEditText }
  from "../../palaver/webapp/static/logic.js";

function meeting(extra = {}) {
  return {
    id: "2026-10-28T10-00-00",
    projects: [
      { id: "a1", name: "Contoso", by: "you", why: "" },
      { id: "b2", name: "Northwind", by: "auto", why: "same people" },
    ],
    project_suggestions: [{ id: "c3", name: "Foundry", score: 0.4, why: "title" }],
    all_projects: [
      { id: "a1", name: "Contoso" }, { id: "c3", name: "Foundry" },
      { id: "b2", name: "Northwind" }, { id: "d4", name: "RTV" },
    ],
    ...extra,
  };
}

const ids = (m) => m.projects.map((p) => `${p.id}:${p.by}`);

test("withProject removes a project at once, and leaves the meeting passed in alone", () => {
  const m = meeting();
  const shown = withProject(m, { project: "b2", remove: true });
  assert.deepEqual(ids(shown), ["a1:you"]);
  assert.deepEqual(ids(m), ["a1:you", "b2:auto"]);
});

test("withProject confirms an unsure project", () => {
  assert.deepEqual(ids(withProject(meeting(), { project: "b2" })), ["a1:you", "b2:you"]);
});

test("withProject adds a suggestion, which stops being suggested", () => {
  const shown = withProject(meeting(), { project: "c3" });
  assert.deepEqual(ids(shown), ["a1:you", "c3:you", "b2:auto"]);
  assert.deepEqual(shown.project_suggestions, []);
});

test("withProject adds by name: an existing project in any case, or a new one", () => {
  assert.deepEqual(ids(withProject(meeting(), { name: " rtv " })), ["a1:you", "b2:auto", "d4:you"]);
  const shown = withProject(meeting(), { name: " Zeta " });
  assert.deepEqual(shown.projects.at(-1), { id: null, name: "Zeta", by: "you", why: "",
    link: { kind: "project", target: "Zeta", source: "you", confidence: null, reason: "", unsure: false,
      label: "Project: Zeta (you)" } });
});

test("projectChange: an added project", () => {
  assert.deepEqual(projectChange(meeting(), { project: "c3" }), { text: "Added to Foundry", id: "c3" });
  assert.deepEqual(projectChange(meeting(), { project: "d4" }), { text: "Added to RTV", id: "d4" });
});

test("projectChange: a removed project", () => {
  assert.deepEqual(projectChange(meeting(), { project: "b2", remove: true }), { text: "Removed from Northwind", id: "b2" });
});

test("projectChange: a confirmed project", () => {
  assert.deepEqual(projectChange(meeting(), { project: "b2" }), { text: "Confirmed Northwind", id: "b2" });
});

test("projectChange: by name, the id comes from the answer", () => {
  const after = meeting({ projects: [...meeting().projects, { id: "e5", name: "Zeta", by: "you", why: "" }] });
  assert.deepEqual(projectChange(meeting(), { name: "zeta" }, after), { text: "Added to Zeta", id: "e5" });
  assert.deepEqual(projectChange(meeting(), { name: "Zeta" }), { text: "Added to Zeta", id: null });
  assert.deepEqual(projectChange(meeting(), { name: "RTV" }, after), { text: "Added to RTV", id: "d4" });
});

test("projectChange: nothing changes when the project is already sure", () => {
  assert.equal(projectChange(meeting(), { project: "a1" }), null);
  assert.equal(projectChange(meeting(), { name: "contoso" }), null);
  assert.equal(projectChange(meeting(), { project: "d4", remove: true }), null);
});

test("projectCommands: Rename, Merge Into… when there is another project, then Delete in red", () => {
  const d = { projects: [{ id: "a1", name: "Contoso" }, { id: "b2", name: "Northwind" }] };
  const items = projectCommands(d, d.projects[0]);
  assert.deepEqual(items.map((x) => x && x.name), ["rename", "mergeInto", null, "delete"]);
  assert.deepEqual(items.map((x) => x && x.label), ["Rename", "Merge Into…", null, "Delete"]);
  assert.equal(items.at(-1).danger, true);
  const alone = { projects: [{ id: "a1", name: "Contoso" }] };
  assert.deepEqual(projectCommands(alone, alone.projects[0]).map((x) => x && x.name), ["rename", null, "delete"]);
});

test("renameText: a new name, a name that exists already (merged), or nothing", () => {
  const d = { people: [{ name: "Anna Berg" }, { name: "Henrik" }] };
  assert.equal(renameText(d, "Anna Berg", " Anna Bergmann "), "Anna Berg is now Anna Bergmann");
  assert.equal(renameText(d, "Anna Berg", "henrik"), "Anna Berg merged into Henrik");
  assert.equal(renameText(d, "Anna Berg", "Anna Berg"), null);
  assert.equal(renameText(d, "Anna Berg", "  "), null);
});

test("voicesText: the name and in how many meetings", () => {
  assert.equal(voicesText(3, " Henrik "), "This voice is now Henrik · 3 meetings");
  assert.equal(voicesText(1, "Henrik"), "This voice is now Henrik · 1 meeting");
});

const names = (items) => items.map((c) => c && c.name);

test("personCommands: a person's ⋯ has Rename and Change Organization, Play Voice only with a clip", () => {
  assert.deepEqual(names(personCommands({ meetings: [{ id: "m1" }] })), ["rename", "organization"]);
  assert.deepEqual(names(personCommands({ meetings: [{ id: "m1" }, { id: "m2", clip: { start: 1, end: 3 } }] })),
    ["rename", "organization", "playVoice"]);
  assert.ok(personCommands({ meetings: [] }).every((c) => c.enabled && !c.danger));
});

test("voiceCommands: an unnamed voice's ⋯ names it, and plays it when there is a clip", () => {
  assert.deepEqual(names(voiceCommands({ voices: [{ id: "m1", label: "S0" }] })), ["name"]);
  assert.deepEqual(names(voiceCommands({ voices: [{ id: "m1", label: "S0", clip: { start: 0, end: 2 } }] })),
    ["name", "playVoice"]);
});

test("termCommands: Delete is red, last, after a separator", () => {
  const items = termCommands();
  assert.deepEqual(names(items), ["rename", "editNote", null, "delete"]);
  assert.equal(items.at(-1).danger, true);
  assert.ok(items.slice(0, 2).every((c) => !c.danger));
});

test("termChangeText says what changed", () => {
  const t = { term: "Databricks" };
  assert.equal(termChangeText(t, { term: " DataBricks " }), "“Databricks” is now “DataBricks”");
  assert.equal(termChangeText(t, { note: "the platform" }), "Note on “Databricks” saved");
  assert.equal(termChangeText(t, { note: " " }), "Note on “Databricks” removed");
  assert.equal(termChangeText(t, { remove_variant: "Data Bricks" }), "“Data Bricks” is no longer respelled as “Databricks”");
  assert.equal(termChangeText(t, { add_variants: ["Datab"] }), "“Datab” is now respelled as “Databricks”");
});

test("projectEditText says what changed", () => {
  const p = { name: "Hiring" };
  assert.equal(projectEditText(p, { name: " Recruiting " }), "“Hiring” is now “Recruiting”");
  assert.equal(projectEditText(p, { description: "Lead engineer." }), "Description of “Hiring” saved");
  assert.equal(projectEditText(p, { description: "" }), "Description of “Hiring” removed");
});
