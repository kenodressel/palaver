// The Worker in node: node:sqlite stands in for D1 (the same SQLite, schema.sql as deployed), requests are the
// platform's Request. Nothing goes over the network.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

import worker, { handle, hashInstall, parsePing, prune, compareVersions, numbers, MAX_BODY } from "../src/index.js";

const SCHEMA = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");
const SALT = "a-salt-only-the-worker-knows";

/** The part of D1's API the Worker uses, over an in-memory SQLite. */
class FakeD1 {
  constructor() {
    this.sqlite = new DatabaseSync(":memory:");
    this.sqlite.exec(SCHEMA);
  }
  prepare(sql) {
    return new Statement(this.sqlite, sql, []);
  }
  async batch(statements) {
    const out = [];
    for (const s of statements) out.push(await s.all());
    return out;
  }
  rows() {
    return this.sqlite.prepare("SELECT * FROM pings ORDER BY day, install").all().map((r) => ({ ...r }));
  }
}

class Statement {
  constructor(sqlite, sql, args) {
    Object.assign(this, { sqlite, sql, args });
  }
  bind(...args) {
    return new Statement(this.sqlite, this.sql, args);
  }
  async run() {
    const r = this.sqlite.prepare(this.sql).run(...this.args);
    return { success: true, meta: { changes: Number(r.changes) } };
  }
  async all() {
    return { success: true, results: this.sqlite.prepare(this.sql).all(...this.args).map((r) => ({ ...r })) };
  }
}

const KIM = "3f2a9c4e-8b1d-4e6f-9a2b-7c5d1e0f4a3b";
const ANNA = "0b7e4d21-5c3a-4f89-b6e2-1d9c8a7f6e5d";
const CARLA = "c4d5e6f7-a8b9-4c0d-8e1f-2a3b4c5d6e7f";

const env = () => ({ DB: new FakeD1(), SALT });
const at = (day) => new Date(`${day}T12:00:00Z`);

function post(body, headers = { "content-type": "application/json" }) {
  return new Request("https://palaver-stats.example.workers.dev/ping", {
    method: "POST", headers, body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const sendPing = (e, install, version, macos, day) => handle(post({ install, version, macos }), e, at(day));

test("a ping is one row per day and install, the install id only as a salted hash", async () => {
  const e = env();
  const r = await sendPing(e, KIM, "0.6.8", "15.5", "2026-11-16");
  assert.equal(r.status, 204);
  const rows = e.DB.rows();
  assert.deepEqual(rows, [{ day: "2026-11-16", install: await hashInstall(SALT, KIM), version: "0.6.8", macos: "15.5" }]);
  assert.match(rows[0].install, /^[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(rows).includes(KIM));
  // Another salt, another hash: the id cannot be looked up without the Worker's secret.
  assert.notEqual(await hashInstall("another-salt-of-sixteen", KIM), rows[0].install);
});

test("the table holds only the day, the hashed install, the version and macOS", () => {
  const columns = new FakeD1().sqlite.prepare("SELECT name FROM pragma_table_info('pings')").all().map((c) => c.name);
  assert.deepEqual(columns, ["day", "install", "version", "macos"]);
});

test("more pings the same day change nothing, the next day counts again", async () => {
  const e = env();
  await sendPing(e, KIM, "0.6.7", "15.5", "2026-11-16");
  const again = await sendPing(e, KIM, "0.6.8", "15.6", "2026-11-16");  // updated in between: the first one stays
  assert.equal(again.status, 204);
  assert.deepEqual(e.DB.rows().map((r) => [r.day, r.version, r.macos]), [["2026-11-16", "0.6.7", "15.5"]]);
  await sendPing(e, KIM, "0.6.8", "15.6", "2026-11-17");
  assert.equal(e.DB.rows().length, 2);
});

test("only exactly the three fields in their shapes are taken", () => {
  const good = { install: KIM, version: "0.6.8", macos: "15.5" };
  assert.deepEqual(parsePing(JSON.stringify(good)), good);
  for (const version of ["0.6.8-rc1", "0.6.0rc1", "1.10.12"]) assert.ok(parsePing(JSON.stringify({ ...good, version })), version);
  assert.ok(parsePing(JSON.stringify({ ...good, macos: "26.1" })));
  const bad = [
    "", "null", "[]", "\"x\"", "{", JSON.stringify({ ...good, name: "Timo Strauß" }),
    JSON.stringify({ install: KIM, version: "0.6.8" }),
    JSON.stringify({ ...good, install: KIM.toUpperCase() }),
    JSON.stringify({ ...good, install: "3f2a9c4e-8b1d-1e6f-9a2b-7c5d1e0f4a3b" }),  // v1, not v4
    JSON.stringify({ ...good, install: `${KIM}\n` }),
    JSON.stringify({ ...good, version: "latest" }),
    JSON.stringify({ ...good, version: "0.6" }),
    JSON.stringify({ ...good, version: "0.6.8 " }),
    JSON.stringify({ ...good, version: "0.6.8-<b>" }),
    JSON.stringify({ ...good, version: 68 }),
    JSON.stringify({ ...good, macos: "15" }),
    JSON.stringify({ ...good, macos: "15.5.1" }),
    JSON.stringify({ ...good, macos: "Sequoia" }),
    `{"install": "${KIM}", "version": "0.6.8", "macos": "15.5", "__proto__": {}}`,
  ];
  for (const text of bad) assert.equal(parsePing(text), null, text);
});

test("anything else is refused and stores nothing", async () => {
  const e = env();
  const day = at("2026-11-16");
  const refused = [
    [await handle(post({ install: KIM, version: "0.6.8", macos: "Sequoia" }), e, day), 400],
    [await handle(post("not json"), e, day), 400],
    [await handle(post({ install: KIM, version: "0.6.8", macos: "15.5" }, { "content-type": "text/plain" }), e, day), 400],
    [await handle(post(`{"install":"${KIM}","version":"0.6.8","macos":"15.5","pad":"${"x".repeat(MAX_BODY)}"}`), e, day), 413],
    [await handle(new Request("https://x.example/ping"), e, day), 405],
    [await handle(new Request("https://x.example/rows"), e, day), 404],
    [await handle(new Request("https://x.example/", { method: "POST", body: "{}" }), e, day), 405],
  ];
  for (const [response, status] of refused) assert.equal(response.status, status);
  assert.deepEqual(e.DB.rows(), []);
});

test("a body longer than 1 KB is refused even without a length", async () => {
  const e = env();
  const big = `{"install":"${KIM}","version":"0.6.8","macos":"15.5","pad":"${"x".repeat(2 * MAX_BODY)}"}`;
  const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(big)); c.close(); } });
  const r = await handle(new Request("https://x.example/ping", {
    method: "POST", headers: { "content-type": "application/json" }, body: stream, duplex: "half",
  }), e, at("2026-11-16"));
  assert.equal(r.status, 413);
  assert.deepEqual(e.DB.rows(), []);
});

test("without its salt the Worker stores nothing", async () => {
  for (const SALT of [undefined, "", "short"]) {
    const e = { DB: new FakeD1(), SALT };
    const r = await handle(post({ install: KIM, version: "0.6.8", macos: "15.5" }), e, at("2026-11-16"));
    assert.equal(r.status, 503);
    assert.deepEqual(e.DB.rows(), []);
  }
});

test("nothing about a request is logged", async () => {
  const said = [];
  const saved = { ...console };
  for (const k of ["log", "info", "warn", "error", "debug"]) console[k] = (...a) => said.push(a);
  try {
    const e = env();
    await sendPing(e, KIM, "0.6.8", "15.5", "2026-11-16");
    await handle(post("broken"), e, at("2026-11-16"));
    await handle(post({ install: KIM, version: "0.6.8", macos: "15.5" }), { DB: null, SALT }, at("2026-11-16"));  // a failing DB
    await handle(new Request("https://x.example/"), e, at("2026-11-16"));
  } finally {
    Object.assign(console, saved);
  }
  assert.deepEqual(said, []);
});

test("a failing database answers 500 and says nothing of the request", async () => {
  const r = await handle(post({ install: KIM, version: "0.6.8", macos: "15.5" }), { DB: null, SALT }, at("2026-11-16"));
  assert.equal(r.status, 500);
  assert.ok(!(await r.text()).includes(KIM));
});

test("versions sort in release order", () => {
  const sorted = ["0.6.10", "0.6.8", "0.6.9", "0.6.9-rc1", "0.6.0rc1", "0.5.0", "0.6.0"].sort(compareVersions);
  assert.deepEqual(sorted, ["0.5.0", "0.6.0rc1", "0.6.0", "0.6.8", "0.6.9-rc1", "0.6.9", "0.6.10"]);
});

test("the numbers: active installs, versions, macOS and the spread, counts only", async () => {
  const e = env();
  // Kim updates from 0.6.7 to 0.6.8 on the 15th; Anna stays on 0.6.7; Carla pinged once, three weeks ago.
  await sendPing(e, CARLA, "0.6.6", "14.7", "2026-10-26");
  for (const day of ["2026-11-12", "2026-11-13", "2026-11-14"]) await sendPing(e, KIM, "0.6.7", "15.5", day);
  for (const day of ["2026-11-15", "2026-11-16"]) await sendPing(e, KIM, "0.6.8", "26.1", day);
  for (const day of ["2026-11-14", "2026-11-15"]) await sendPing(e, ANNA, "0.6.7", "15.5", day);

  const n = await numbers(e.DB, "2026-11-16");
  assert.deepEqual(n.active, { day: 1, week: 2, month: 3 });
  assert.deepEqual(n.versions, [{ name: "0.6.8", n: 1 }, { name: "0.6.7", n: 1 }]);  // Kim counted once, as updated
  assert.deepEqual(n.macos, [{ name: "26.1", n: 1 }, { name: "15.5", n: 1 }]);
  assert.deepEqual(n.spread.map((d) => [d.day, d.total, d.versions]), [
    ["2026-11-16", 1, { "0.6.8": 1 }],
    ["2026-11-15", 2, { "0.6.8": 1, "0.6.7": 1 }],
    ["2026-11-14", 2, { "0.6.7": 2 }],
    ["2026-11-13", 1, { "0.6.7": 1 }],
    ["2026-11-12", 1, { "0.6.7": 1 }],
    ["2026-10-26", 1, { "0.6.6": 1 }],
  ]);
});

test("the page shows the totals and no install", async () => {
  const e = env();
  await sendPing(e, KIM, "0.6.7", "15.5", "2026-11-15");
  await sendPing(e, KIM, "0.6.8", "15.5", "2026-11-16");
  await sendPing(e, ANNA, "0.6.7", "26.1", "2026-11-16");
  const r = await handle(new Request("https://palaver-stats.example.workers.dev/"), e, at("2026-11-16"));
  assert.equal(r.status, 200);
  assert.match(r.headers.get("content-type"), /^text\/html/);
  const html = await r.text();
  assert.match(html, /<title>Palaver usage numbers<\/title>/);
  assert.match(html, /Today<strong>2<\/strong>/);
  assert.match(html, /Last 30 days<strong>2<\/strong>/);
  assert.match(html, /<th scope="row">0\.6\.8<\/th><td>1<\/td><td>50%<\/td>/);
  assert.match(html, /The newest version, 0\.6\.8, first appears here on 2026-11-16/);
  assert.match(html, /<th scope="row">2026-11-15<\/th><td>1<\/td><td>0%<\/td><td>100%<\/td>/);
  for (const row of e.DB.rows()) assert.ok(!html.includes(row.install));
  assert.ok(!html.includes(KIM) && !html.includes(ANNA));
});

test("an empty database shows a page", async () => {
  const r = await handle(new Request("https://x.example/"), env(), at("2026-11-16"));
  const html = await r.text();
  assert.match(html, /Today<strong>0<\/strong>/);
  assert.match(html, /No pings in the last 30 days/);
});

test("the cron deletes the daily rows older than 90 days", async () => {
  const e = env();
  for (const day of ["2026-08-17", "2026-08-18", "2026-11-16"]) await sendPing(e, KIM, "0.6.8", "15.5", day);
  let waited;
  worker.scheduled({ scheduledTime: Date.parse("2026-11-16T03:17:00Z") }, e, { waitUntil: (p) => { waited = p; } });
  await waited;
  assert.deepEqual(e.DB.rows().map((r) => r.day), ["2026-08-18", "2026-11-16"]);
  await prune(e.DB, at("2026-11-17"));
  assert.deepEqual(e.DB.rows().map((r) => r.day), ["2026-11-16"]);
});
