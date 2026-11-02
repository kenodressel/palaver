// What Settings says about updates (#60).
import { test } from "node:test";
import assert from "node:assert/strict";

import { updateIndicator, updateView } from "../../palaver/webapp/static/logic.js";

const available = { version: "0.2.0", notes: "Faster notes.", download_bytes: 5 * 2 ** 20 };

test("a newer release offers its install, with the download's size", () => {
  assert.deepEqual(updateView({ state: "available", current: "0.1.0", available }),
    { text: "Palaver 0.2.0 is available (5 MB). You have 0.1.0.", action: "install" });
});

test("a downloaded update waits for an idle moment and says what it waits for", () => {
  assert.equal(updateView({ state: "ready", available, waiting_for: "recording" }).text,
    "Palaver 0.2.0 installs when Palaver is idle (now: recording).");
  assert.equal(updateView({ state: "downloading", available, done_bytes: 2.5 * 2 ** 20 }).text,
    "Downloading Palaver 0.2.0… 50 %");
});

test("a failure says why and can be tried again", () => {
  const v = updateView({ state: "failed", available, error: "Download failed: offline. Palaver 0.1.0 stays." });
  assert.deepEqual(v, { text: "Download failed: offline. Palaver 0.1.0 stays.", action: "install" });
});

test("a checkout has no updates and no button", () => {
  assert.equal(updateView({ state: "unsupported" }).action, null);
  assert.equal(updateView(null).action, null);
});

test("a check that failed is said quietly", () => {
  assert.deepEqual(updateView({ state: "idle", current: "0.1.0", check_error: "offline" }),
    { text: "Palaver 0.1.0. Could not look for updates: offline", action: "check" });
});

test("the top bar shows an update while there is one to install or one installing", () => {
  assert.deepEqual(updateIndicator({ state: "available", current: "0.1.0", available }),
    { text: "Update to 0.2.0", title: "Palaver 0.2.0 is available (5 MB). You have 0.1.0." });
  assert.equal(updateIndicator({ state: "downloading", available, done_bytes: 2.5 * 2 ** 20 }).text, "Updating · 50 %");
  assert.equal(updateIndicator({ state: "ready", available, waiting_for: "recording" }).text, "Update waits");
  assert.equal(updateIndicator({ state: "installing", available }).text, "Updating…");
  assert.equal(updateIndicator({ state: "failed", available, error: "Download failed: offline." }).text, "Update failed");
});

test("the top bar shows nothing up to date, while checking, from a checkout or before a check", () => {
  for (const u of [{ state: "up_to_date", current: "0.1.0" }, { state: "checking", current: "0.1.0" },
    { state: "idle", current: "0.1.0" }, { state: "unsupported" }, { state: "failed", error: "x" }, null]) {
    assert.equal(updateIndicator(u), null);
  }
});

test("Today leads with a card while a release waits for a click", async () => {
  const { updateCard } = await import("../../palaver/webapp/static/logic.js");
  assert.deepEqual(updateCard({ state: "available", current: "0.1.0", available }), {
    title: "Palaver 0.2.0 is available",
    text: "You have 0.1.0. It installs once Palaver is idle; nothing is lost." });
  assert.equal(updateCard({ state: "failed", current: "0.1.0", available, error: "Download failed: offline." }).text,
    "Download failed: offline.");
  for (const u of [{ state: "downloading", available }, { state: "ready", available }, { state: "up_to_date" },
    { state: "failed", error: "x" }, null]) {
    assert.equal(updateCard(u), null);  // under way (the top bar follows it), or nothing to install
  }
});

test("up to date says when it looked", () => {
  const at = Date.UTC(2026, 10, 2, 15, 1) / 1000;
  assert.equal(updateView({ state: "up_to_date", current: "0.3.10", checked_at: at }, (d) => d.toISOString().slice(11, 16)).text,
    "Palaver 0.3.10 is the latest version (checked at 15:01).");
  assert.equal(updateView({ state: "up_to_date", current: "0.3.10" }).text, "Palaver 0.3.10 is the latest version.");
});

import { SETTINGS_PANES, settingsPane } from "../../palaver/webapp/static/logic.js";

test("settingsPane: a pane, an older section's pane, else General", () => {
  assert.equal(settingsPane("storage"), "storage");
  assert.equal(settingsPane("update"), "update");  // the update notification's settings/update
  assert.equal(settingsPane("live"), "recording");
  assert.equal(settingsPane(undefined), "general");
  assert.equal(settingsPane("nope"), "general");
  assert.equal(SETTINGS_PANES[0][0], "general");
});
