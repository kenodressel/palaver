// What Palaver costs in memory, shown in Settings (issue #49).
import { test } from "node:test";
import assert from "node:assert/strict";

import { sizeText, memoryRows, memoryTotalText, memoryPolling } from "../../palaver/webapp/static/logic.js";

const GB = 1024 ** 3;
const budgets = { live: 5, stream: 3.5, process: 8, notes: 14, index: 1 };

test("sizeText matches the menu bar's", () => {
  assert.equal(sizeText(5.44 * GB), "5.4 GB");
  assert.equal(sizeText(12 * GB), "12 GB");
  assert.equal(sizeText(0.31 * GB), "317 MB");
  assert.equal(sizeText(null), "—");
});

test("memoryRows: every kind of worker, its state and its share of the budget", () => {
  const mem = {
    total: 5.4 * GB, app: 0.3 * GB, budgets,
    workers: [
      { kind: "live", label: "Live transcription", meeting: "m", pid: 1, used: 3.5 * GB, budget: 5, state: "running" },
      { kind: "stream", label: "Realtime transcription", meeting: "m", pid: 2, used: 3.7 * GB, budget: 3.5, state: "over budget" },
      { kind: "notes", label: "Notes", meeting: "n", need: 20, free: 18.2, state: "waiting for memory" },
    ],
  };
  const rows = memoryRows(mem);
  assert.deepEqual(rows.map((r) => r.kind), ["live", "stream", "process", "notes", "index"]);
  assert.deepEqual(rows[4], { kind: "index", label: "Search index", state: "Not running", size: "Budget 1 GB", fill: 0, over: false });
  assert.deepEqual(rows[0], { kind: "live", label: "Live transcription", state: "Running", size: "3.5 GB of 5 GB",
    fill: 0.7, over: false });
  assert.equal(rows[1].state, "Over budget");
  assert.equal(rows[1].over, true);
  assert.equal(rows[1].fill, 1);
  assert.deepEqual(rows[2], { kind: "process", label: "Transcription", state: "Not running",
    size: "Budget 8 GB", fill: 0, over: false });
  assert.equal(rows[3].state, "Waiting for memory");
  assert.equal(rows[3].size, "Needs 20 GB free, 18 GB free now");
});

test("memoryRows: of two workers of a kind (one on its way out), the one using more shows", () => {
  const mem = { total: GB, budgets, workers: [
    { kind: "live", used: 1 * GB, budget: 5, state: "running" },
    { kind: "live", used: 6 * GB, budget: 5, state: "restarting" },
  ] };
  assert.equal(memoryRows(mem)[0].state, "Restarting");
});

test("memoryRows and the total are empty outside the menu bar app", () => {
  assert.deepEqual(memoryRows(null), []);
  assert.equal(memoryTotalText(null), "");
  assert.equal(memoryTotalText({ total: 5.4 * GB, workers: [] }), "Palaver uses 5.4 GB now.");
});

test("memoryPolling: only while Settings is shown and the window is visible", () => {
  assert.equal(memoryPolling("settings", false), true);
  assert.equal(memoryPolling("settings", true), false);
  assert.equal(memoryPolling("meetings", false), false);
});
