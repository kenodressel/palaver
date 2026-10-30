// What Settings says about updates (#60).
import { test } from "node:test";
import assert from "node:assert/strict";

import { updateView } from "../../palaver/webapp/static/logic.js";

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
