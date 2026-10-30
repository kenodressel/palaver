// The estimate shown while the local model writes notes.
import { test } from "node:test";
import assert from "node:assert/strict";

import { notesEstimate } from "../../palaver/webapp/static/logic.js";

test("no estimate before there are two runs", () => {
  assert.equal(notesEstimate([]), null);
  assert.equal(notesEstimate([30]), null);
});

test("the estimate is the median", () => {
  assert.equal(notesEstimate([30, 50, 40]), 40);
  assert.equal(notesEstimate([30, 50]), 40);
});

test("only the last five runs count", () => {
  assert.equal(notesEstimate([500, 500, 10, 20, 30, 40, 50]), 30);
});

// After the window's server restarted (#57), notes still being written show again, from /api/model-jobs.
import { notesFromJobs } from "../../palaver/webapp/static/logic.js";

test("notesFromJobs: a running notes job shows as being written, and ends when it is done", () => {
  const jobs = { running: [{ kind: "notes", key: "A", started: 1000 }, { kind: "projects", key: "projects", started: 5 }] };
  assert.deepEqual(notesFromJobs(jobs, new Map()), { start: [{ id: "A", startedAt: 1000 * 1000 }], end: [] });
  // Written from this page (its own request): nothing to do either way.
  assert.deepEqual(notesFromJobs(jobs, new Map([["A", { remote: false }]])), { start: [], end: [] });
  assert.deepEqual(notesFromJobs({ running: [] }, new Map([["A", { remote: false }]])), { start: [], end: [] });
  // Shown from the jobs: ends when the job is no longer running.
  assert.deepEqual(notesFromJobs(jobs, new Map([["A", { remote: true }]])), { start: [], end: [] });
  assert.deepEqual(notesFromJobs({ running: [] }, new Map([["A", { remote: true }]])), { start: [], end: ["A"] });
  assert.deepEqual(notesFromJobs(null, new Map([["A", { remote: true }]])), { start: [], end: [] });  // no answer: as it was
});
