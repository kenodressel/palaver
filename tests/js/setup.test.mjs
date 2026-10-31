// The setup assistant (#55): its steps, which choices a click applies, and
// what it says (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { placeOf, hashOf, SETUP_STEPS, setupStepAfter, setupStepBefore, recommendedChanges,
  chosenChanges, gbText, downloadsText, downloadProgress, permissionText, recommendedHint,
  setupOfferText, testRecordingText, seedChecked, optionLabel, stepButtons, engineOptions, sendsText }
  from "../../palaver/webapp/static/logic.js";

const rec = (id, step, value, current, extra = {}) => ({
  id, step, value, current, matches: JSON.stringify(value) === JSON.stringify(current), label: String(value),
  reason: `why ${id}`, needs_setup: false, downloads: [], features: [], options: [], ...extra,
});

test("the assistant has a hash per step", () => {
  assert.deepEqual(placeOf("#/setup"), { view: "setup", step: null });
  assert.deepEqual(placeOf("#/setup/models"), { view: "setup", step: "models" });
  assert.equal(hashOf({ view: "setup", step: "you" }), "#/setup/you");
  assert.equal(hashOf({ view: "setup" }), "#/setup");
});

test("three steps: you, the recommended package, the test", () => {
  assert.deepEqual(SETUP_STEPS.map((s) => s.id), ["you", "recommended", "test"]);
  assert.equal(setupStepAfter("you"), "recommended");
  assert.equal(setupStepAfter("test"), null);
  assert.equal(setupStepBefore("recommended"), "you");
  assert.equal(setupStepBefore("you"), null);
  assert.equal(setupStepAfter("nonsense"), "you");
});

test("Use recommended changes only what differs; notes wait for a cloud model rather than stay on Gemma", () => {
  const recs = [
    rec("realtime", "calls", false, true),
    rec("live_processing", "calls", true, true),
    rec("language_model", "models", "pending", "local:gemma", { needs_setup: true }),
    rec("claude_desktop", "claude", false, false),
    rec("claude_code", "claude", true, false, { options: [{ value: true, available: true }, { value: false, available: true }] }),
    rec("disk", "models", 4.3, 0),
  ];
  assert.deepEqual(recommendedChanges(recs), { realtime: false, language_model: "pending", claude_code: true });
});

test("a step's buttons: a deliberate choice is kept unless the user asks for the recommendation", () => {
  const fresh = [rec("realtime", "calls", false, true), rec("live_processing", "calls", true, true)];
  assert.deepEqual(stepButtons(fresh, {}), { primary: { label: "Use recommended", changes: { realtime: false } }, secondary: null });
  const deliberate = [rec("realtime", "calls", false, true, { chosen: true }), rec("live_processing", "calls", true, false)];
  assert.deepEqual(stepButtons(deliberate, {}), {
    primary: { label: "Keep current", changes: {} },
    secondary: { label: "Use recommended", changes: { realtime: false, live_processing: true } },
  });
  assert.deepEqual(stepButtons(deliberate, { realtime: false }),
    { primary: { label: "Use these", changes: { realtime: false } }, secondary: null });
  assert.deepEqual(stepButtons([rec("realtime", "calls", true, true, { chosen: true })], {}),
    { primary: { label: "Continue", changes: {} }, secondary: null });
});

test("Settings shows notes waiting for a cloud model", () => {
  const lm = {
    features: [{ id: "notes", label: "Notes", sends: "the transcript", choice: "pending", default: "local" }],
    providers: [{ id: "anthropic", label: "Anthropic API", model: "m", ready: false, problem: "Add the API key", sends_to: "Anthropic" }],
    local: { model: "repo/gemma", models: [{ repo: "repo/gemma", label: "Gemma 4 12B" }] },
  };
  const options = engineOptions(lm);
  assert.deepEqual(options.at(-1), { value: "pending", label: "None yet: set up a cloud model", disabled: false });
  assert.equal(sendsText(lm, lm.features[0]),
    "Off: no model writes notes until you set up a cloud model below. Nothing is sent.");
  assert.ok(!engineOptions({ ...lm, features: [{ ...lm.features[0], choice: "local" }] }).some((o) => o.value === "pending"));
});

test("Customize applies the user's picks that differ from now", () => {
  const recs = [rec("realtime", "calls", false, true), rec("live_processing", "calls", true, true)];
  assert.deepEqual(chosenChanges(recs, { realtime: true, live_processing: false }), { live_processing: false });
  assert.deepEqual(chosenChanges(recs, {}), {});
});

test("sizes and downloads, said plainly", () => {
  assert.equal(gbText(8.3), "8.3 GB");
  assert.equal(gbText(0.47), "470 MB");
  assert.equal(gbText(0.03), "30 MB");
  assert.equal(gbText(16), "16 GB");
  const needed = [{ id: "parakeet", label: "Parakeet", disk_gb: 2.3 }, { id: "gemma", label: "Gemma 4 12B", disk_gb: 8.3 }];
  assert.equal(downloadsText(needed), "Parakeet (2.3 GB) and Gemma 4 12B (8.3 GB): 10.6 GB in all");
  assert.equal(downloadsText([]), "Nothing to download: every model is on this Mac.");
});

test("download progress across the models", () => {
  const status = { running: true, models: [
    { id: "parakeet", disk_gb: 2, done_gb: 2, state: "done" },
    { id: "gemma", disk_gb: 8, done_gb: 2, state: "downloading" },
  ] };
  assert.equal(downloadProgress(status), 0.4);
  assert.equal(downloadProgress({ running: false, models: [] }), 0);
});

test("a permission in a line", () => {
  assert.deepEqual(permissionText({ state: "granted", detail: "allowed" }), { status: "ok", text: "allowed" });
  assert.deepEqual(permissionText({ state: "not_asked", detail: "not asked yet" }), { status: "warn", text: "not asked yet" });
  assert.deepEqual(permissionText({ state: "denied", detail: "not allowed" }), { status: "fail", text: "not allowed" });
  assert.deepEqual(permissionText(undefined), { status: "warn", text: "not checked" });
  assert.deepEqual(permissionText({ state: "fallback", detail: "works with a fallback" }),
    { status: "warn", text: "works with a fallback" });
});

test("Settings shows the recommendation beside a switch set otherwise; one it follows needs no word", () => {
  const recs = [rec("realtime", "calls", false, true, { label: "Off", reason: "The M1 is below an M2 Pro." }),
    rec("record_teams", "record", true, true, { label: "On" })];
  assert.deepEqual(recommendedHint(recs, "realtime"), { matches: false, text: "Recommended for this Mac: Off. The M1 is below an M2 Pro." });
  assert.equal(recommendedHint(recs, "record_teams"), null);
  assert.equal(recommendedHint(recs, "nope"), null);
  assert.equal(recommendedHint(null, "realtime"), null);
});

test("what the window says when it offers the assistant again", () => {
  assert.equal(setupOfferText({ why: "first" }), null);  // the first start opens it, no toast
  assert.equal(setupOfferText({ why: "changed", was: "Apple M1, 16 GB", now: "Apple M4 Pro, 48 GB" }),
    "This is another Mac (Apple M4 Pro, 48 GB). Review the recommended settings?");
  assert.equal(setupOfferText({ why: "missing", models: ["gemma"] }, { gemma: "Gemma 4 12B" }),
    "Gemma 4 12B is not downloaded yet.");
  assert.equal(setupOfferText({ why: "missing", models: ["parakeet", "gemma"] }, { gemma: "Gemma 4 12B", parakeet: "Parakeet" }),
    "Parakeet and Gemma 4 12B are not downloaded yet.");
  assert.equal(setupOfferText(null), null);
});

test("the test recording, said plainly, never about headphones", () => {
  assert.equal(testRecordingText({ state: "idle" }), "");
  assert.equal(testRecordingText({ state: "recording", seconds: 3.2, max_seconds: 20 }),
    "Recording · 3 s. Say a sentence, then click Stop.");
  assert.equal(testRecordingText({ state: "checking" }), "Checking both tracks…");
  assert.equal(testRecordingText({ state: "failed", error: "could not start recording: no device" }),
    "could not start recording: no device");
  assert.equal(testRecordingText({ state: "aborted", error: "A call started, so the test stopped." }),
    "A call started, so the test stopped.");
  for (const s of ["idle", "recording", "checking", "done"]) {
    assert.ok(!/headphone/i.test(testRecordingText({ state: s, seconds: 1, max_seconds: 20 })));
  }
});

test("glossary terms from the calendar start unticked: only an explicit Add adds them", () => {
  const terms = [{ term: "Contoso", kind: "organization", count: 3 }, { term: "Northwind", kind: "title", count: 1 }];
  assert.deepEqual(seedChecked(terms), new Set());
});

test("an option's label says when it is the recommendation and the current choice", () => {
  const r = rec("realtime", "calls", false, true);
  assert.equal(optionLabel(r, { value: false, label: "Off" }), "Off · recommended");
  assert.equal(optionLabel(r, { value: true, label: "On" }), "On · now");
  assert.equal(optionLabel(rec("x", "s", 1, 1), { value: 1, label: "One" }), "One · recommended, now");
});
