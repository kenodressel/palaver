// Palaver's anonymous usage numbers (#6): a Cloudflare Worker with a D1 database (binding DB).
//
// POST /ping  {"install": <UUID v4>, "version": "0.6.8", "macos": "15.5"}, sent once a day and after each update by a
//             Palaver that shares them (on unless turned off). One row per UTC day and install, with the version it
//             runs now; the install id is
//             stored only as a salted SHA-256 (the secret SALT), never as sent. Nothing else of the request is kept
//             or logged: no IP address, no user agent, no time of day.
// GET /       A public page with the totals only: how many installs were active, on which versions, and how fast
//             the latest version spread. No row of a single install ever leaves the database.
// The cron    Deletes the daily rows older than KEEP_DAYS.
//
// No npm dependencies: the tests run it in node (`node --test` in this folder) with node:sqlite standing in for D1.

export const MAX_BODY = 1024;
export const KEEP_DAYS = 90;

// The shapes the app sends, and nothing else: a lowercase UUID v4, a release version (0.6.8, 0.6.8-rc1, 0.6.0rc1),
// macOS as major.minor (15.5, 26.1).
const INSTALL = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const VERSION = /^\d{1,3}\.\d{1,3}\.\d{1,3}(?:-?(?:rc|a|b|alpha|beta|dev)\d{1,3})?$/;
const MACOS = /^\d{2}\.\d{1,2}$/;

export function utcDay(date) {
  return date.toISOString().slice(0, 10);
}

/** The UTC day `n` days before `day` (YYYY-MM-DD). */
export function daysBefore(day, n) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - n);
  return utcDay(d);
}

/** The ping in `text`, or null when it is anything but exactly the three fields in their shapes. */
export function parsePing(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  if (Object.keys(value).sort().join(",") !== "install,macos,version") return null;
  const { install, version, macos } = value;
  if (typeof install !== "string" || !INSTALL.test(install)) return null;
  if (typeof version !== "string" || !VERSION.test(version)) return null;
  if (typeof macos !== "string" || !MACOS.test(macos)) return null;
  return { install, version, macos };
}

/** The hex SHA-256 of the salt and the install id: the same install is the same row key, the id is not kept. */
export async function hashInstall(salt, install) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}\n${install}`));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The body as text, read up to MAX_BODY bytes: null when it is longer (a declared length is not trusted, a chunked
 * body is counted as it comes), undefined when it is not UTF-8.
 */
async function readBody(request) {
  const declared = request.headers.get("content-length");
  if (declared !== null && !(Number(declared) <= MAX_BODY)) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    bytes.set(c, at);
    at += c.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

function plain(status, text, headers = {}) {
  return new Response(`${text}\n`, { status, headers: { "content-type": "text/plain; charset=utf-8", ...headers } });
}

async function ping(request, env, now) {
  if (request.method !== "POST") return plain(405, "POST only", { allow: "POST" });
  if (!/^application\/json\s*(;|$)/i.test(request.headers.get("content-type") || "")) {
    return plain(400, "send JSON");
  }
  const body = await readBody(request);
  if (body === null) return plain(413, `at most ${MAX_BODY} bytes`);
  const sent = body === undefined ? null : parsePing(body);
  if (!sent) return plain(400, "expected exactly {install, version, macos}");
  // Without a salt the id could only be stored as it came, or hashed without one: neither.
  if (typeof env.SALT !== "string" || env.SALT.length < 16) return plain(503, "not set up");
  const install = await hashInstall(env.SALT, sent.install);
  // One row a day per install; a later ping that day (after an update) changes its versions to the new ones.
  await env.DB.prepare("INSERT INTO pings (day, install, version, macos) VALUES (?, ?, ?, ?) "
    + "ON CONFLICT (day, install) DO UPDATE SET version = excluded.version, macos = excluded.macos")
    .bind(utcDay(now), install, sent.version, sent.macos)
    .run();
  return new Response(null, { status: 204 });
}

// --- the public page --------------------------------------------------------------------------------------------

/** Release order: 0.6.10 after 0.6.9, a release candidate before its release. */
export function compareVersions(a, b) {
  const parse = (v) => {
    const m = /^(\d+)\.(\d+)\.(\d+)(?:-?([a-z]+)(\d+))?$/.exec(v) || [];
    const pre = m[4] ? ["dev", "a", "alpha", "b", "beta", "rc"].indexOf(m[4]) : 99;
    return [Number(m[1]), Number(m[2]), Number(m[3]), pre, Number(m[5] || 0)];
  };
  const x = parse(a), y = parse(b);
  for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}

const compareMacos = (a, b) => {
  const [x1, x2] = a.split(".").map(Number), [y1, y2] = b.split(".").map(Number);
  return x1 - y1 || x2 - y2;
};

/** Everything the page shows, as of the UTC day `today`: only counts, never a row. */
export async function numbers(db, today) {
  const since = (n) => daysBefore(today, n - 1);  // the last n UTC days, today included
  const active = "SELECT COUNT(DISTINCT install) AS n FROM pings WHERE day >= ?";
  // Each install once, with what it sent last in the window (an update within the week counts as the new version).
  const latest = (column) => `SELECT ${column} AS name, COUNT(*) AS n FROM
      (SELECT install, ${column}, MAX(day) FROM pings WHERE day >= ? GROUP BY install) GROUP BY ${column}`;
  const results = await db.batch([
    db.prepare(active).bind(since(1)),
    db.prepare(active).bind(since(7)),
    db.prepare(active).bind(since(30)),
    db.prepare(latest("version")).bind(since(7)),
    db.prepare(latest("macos")).bind(since(7)),
    db.prepare("SELECT day, version, COUNT(*) AS n FROM pings WHERE day >= ? GROUP BY day, version").bind(since(30)),
  ]);
  const rows = results.map((r) => r.results || []);
  const days = new Map();
  for (const { day, version, n } of rows[5]) {
    if (!days.has(day)) days.set(day, { day, total: 0, versions: {} });
    const d = days.get(day);
    d.total += n;
    d.versions[version] = n;
  }
  return {
    today,
    active: { day: rows[0][0]?.n ?? 0, week: rows[1][0]?.n ?? 0, month: rows[2][0]?.n ?? 0 },
    versions: rows[3].map(({ name, n }) => ({ name, n })).sort((a, b) => compareVersions(b.name, a.name)),
    macos: rows[4].map(({ name, n }) => ({ name, n })).sort((a, b) => compareMacos(b.name, a.name)),
    spread: [...days.values()].sort((a, b) => (a.day < b.day ? 1 : -1)),  // newest first
  };
}

const escape = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const percent = (n, total) => (total ? `${Math.round((100 * n) / total)}%` : "–");

function shareTable(caption, rows) {
  if (!rows.length) return `<h2>${caption}</h2><p class="quiet">No pings in the last 7 days.</p>`;
  const total = rows.reduce((s, r) => s + r.n, 0);
  return `<h2>${caption}</h2><table><thead><tr><th scope="col">Version</th><th scope="col">Installs</th>`
    + `<th scope="col">Share</th></tr></thead><tbody>${rows.map((r) => `<tr><th scope="row">${escape(r.name)}</th>`
      + `<td>${r.n}</td><td>${percent(r.n, total)}</td></tr>`).join("")}</tbody></table>`;
}

/** Per day, the share of that day's installs on the newest versions (the rest as "older"), newest day first. */
function spreadTable(spread) {
  if (!spread.length) return `<p class="quiet">No pings in the last 30 days.</p>`;
  const all = [...new Set(spread.flatMap((d) => Object.keys(d.versions)))].sort((a, b) => compareVersions(b, a));
  const shown = all.slice(0, 3);
  const older = all.length > shown.length;
  const firstSeen = spread.filter((d) => d.versions[all[0]]).at(-1)?.day;
  const head = shown.map((v) => `<th scope="col">${escape(v)}</th>`).join("") + (older ? `<th scope="col">Older</th>` : "");
  const body = spread.map((d) => {
    const parts = shown.map((v) => d.versions[v] || 0);
    if (older) parts.push(d.total - parts.reduce((s, n) => s + n, 0));
    const bar = parts.map((n, i) => (n ? `<span class="c${i}" style="width:${(100 * n) / d.total}%"></span>` : "")).join("");
    return `<tr><th scope="row">${d.day}</th><td>${d.total}</td>${parts.map((n) => `<td>${percent(n, d.total)}</td>`).join("")}`
      + `<td class="bar" aria-hidden="true"><div>${bar}</div></td></tr>`;
  }).join("");
  return `<p>The newest version, ${escape(all[0])}, first appears here on ${firstSeen}. Each row: the installs active that day and the share on each version.</p>`
    + `<table class="spread"><thead><tr><th scope="col">Day (UTC)</th><th scope="col">Installs</th>${head}`
    + `<th scope="col"><span class="sr">Bar</span></th></tr></thead><tbody>${body}</tbody></table>`;
}

export function page(n) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Palaver usage numbers</title>
<style>
:root { --bg: #fbfaf7; --fg: #1f1d1a; --quiet: #6b665e; --line: #e4e0d8; --c0: #2f6f5e; --c1: #7fa99b; --c2: #c9b27c; --c3: #b9b4aa; }
@media (prefers-color-scheme: dark) { :root { --bg: #191817; --fg: #ecebe7; --quiet: #a39e95; --line: #34322e; --c0: #5fb39b; --c1: #3f7a6b; --c2: #9b8550; --c3: #57534c; } }
body { background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0 auto; max-width: 52rem; padding: 2rem 1rem 4rem; }
h1 { font-size: 1.6rem; margin: 0 0 .25rem; } h2 { font-size: 1.15rem; margin: 2.2rem 0 .6rem; }
.quiet, footer { color: var(--quiet); } footer { font-size: .9rem; margin-top: 3rem; border-top: 1px solid var(--line); padding-top: 1rem; }
.totals { display: flex; flex-wrap: wrap; gap: 1rem; margin: 1.2rem 0 0; padding: 0; list-style: none; }
.totals li { border: 1px solid var(--line); border-radius: 8px; padding: .7rem 1rem; min-width: 9rem; }
.totals strong { display: block; font-size: 1.8rem; font-variant-numeric: tabular-nums; }
table { border-collapse: collapse; font-variant-numeric: tabular-nums; width: 100%; }
th, td { border-bottom: 1px solid var(--line); padding: .3rem .6rem .3rem 0; text-align: left; white-space: nowrap; }
thead th { color: var(--quiet); font-weight: 500; }
.spread-wrap { overflow-x: auto; }
.bar { width: 40%; } .bar div { display: flex; height: .8rem; border-radius: 3px; overflow: hidden; min-width: 6rem; }
.c0 { background: var(--c0); } .c1 { background: var(--c1); } .c2 { background: var(--c2); } .c3 { background: var(--c3); }
.sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
</style>
</head>
<body>
<h1>Palaver usage numbers</h1>
<p class="quiet">From the Macs whose users turned on “Share anonymous usage numbers” in Palaver. As of ${n.today} (UTC).</p>
<ul class="totals">
<li>Today<strong>${n.active.day}</strong></li>
<li>Last 7 days<strong>${n.active.week}</strong></li>
<li>Last 30 days<strong>${n.active.month}</strong></li>
</ul>
${shareTable("Palaver versions, last 7 days", n.versions)}
${shareTable("macOS versions, last 7 days", n.macos)}
<h2>How fast the latest version spread</h2>
<div class="spread-wrap">${spreadTable(n.spread)}</div>
<footer>
<p>Each Palaver that shares sends, once a day and after each update: a random install id (stored here only as a salted hash, and
reset in Palaver's Settings), the Palaver version and the macOS version. No IP address, name, meeting or anything
else is stored. Daily rows are deleted after ${KEEP_DAYS} days. On unless turned off in Palaver's Settings → Updates
(or its setup assistant).</p>
</footer>
</body>
</html>
`;
}

async function front(env, now) {
  const html = page(await numbers(env.DB, utcDay(now)));
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=300",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}

// --- the Worker -------------------------------------------------------------------------------------------------

export async function handle(request, env, now = new Date()) {
  const { pathname } = new URL(request.url);
  try {
    if (pathname === "/ping") return await ping(request, env, now);
    if (pathname === "/") {
      if (request.method !== "GET" && request.method !== "HEAD") return plain(405, "GET only", { allow: "GET, HEAD" });
      return await front(env, now);
    }
    return plain(404, "not found");
  } catch {
    // Nothing logged: an error's message could carry what was sent.
    return plain(500, "try again later");
  }
}

/** The retention: the daily rows older than KEEP_DAYS go. */
export async function prune(db, now) {
  await db.prepare("DELETE FROM pings WHERE day < ?").bind(daysBefore(utcDay(now), KEEP_DAYS)).run();
}

export default {
  fetch(request, env) {
    return handle(request, env, new Date());
  },
  scheduled(controller, env, ctx) {
    ctx.waitUntil(prune(env.DB, new Date(controller.scheduledTime)));
  },
};
