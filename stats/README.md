# palaver-stats

Palaver's anonymous usage numbers (issue #6): a Cloudflare Worker with a D1
database, deployed at https://palaver-stats.ardobras.workers.dev/. Palaver
sends a ping at most once a day, only while "Share anonymous usage numbers"
(Settings → Updates or the setup assistant; on by default) and "Look for
updates automatically" are both on.

## What it does

- `POST /ping` takes exactly `{"install": <UUID v4>, "version": "0.6.8", "macos": "15.5"}`
  (JSON, at most 1 KB). Anything else is refused (400; 413 for a larger body).
  It stores one row per UTC day and install: the day, the install id as a
  salted SHA-256 (the secret `SALT`; the id itself is never stored), the
  version and macOS. A second ping the same day changes nothing. No IP address,
  no user agent, no time of day; the Worker logs nothing, and its request logs
  are off (`[observability] enabled = false` in `wrangler.toml`).
- `GET /` is the public page: active installs today, in the last 7 and 30 days,
  the Palaver and macOS versions of the last 7 days, and per day of the last 30
  the share of installs on each version (how fast the latest one spread). Only
  counts ever leave the database.
- A daily cron (03:17 UTC) deletes the rows older than 90 days.

The app side: `native/Sources/PalaverCore/UsageStats.swift` (the endpoint, the
ping, the install id in `~/Library/Application Support/palaver/install-id`),
`native/Sources/PalaverDaemon/StatsPing.swift` (once a day, from the app's
tick).

## Tests

No dependencies: node's own test runner, with `node:sqlite` (node 22.5 or
later) standing in for D1 and `schema.sql` as deployed.

```bash
cd stats && node --test
```

`make test` runs them (`tests/test_stats_worker.py`) when something in
`stats/` changed.

## Deploying

Once, from this folder (`npx` fetches wrangler; it asks to log in to the
Cloudflare account in the browser):

```bash
cd stats
npx wrangler login
npx wrangler d1 create palaver-stats
```

Put the `database_id` it prints into `wrangler.toml` (in place of
`REPLACE-WITH-THE-DATABASE-ID`), then:

```bash
npx wrangler d1 execute palaver-stats --remote --file schema.sql
npx wrangler deploy
openssl rand -hex 32 | npx wrangler secret put SALT
```

Until the salt is set, `/ping` answers 503 and stores nothing. The salt only
has to stay the same: a new one counts every install as new. Keep it secret,
so nobody can check whether an id they know was counted.

`deploy` prints the Worker's URL; the app's endpoint is
`UsageStats.defaultEndpoint` in `native/Sources/PalaverCore/UsageStats.swift`
(now `https://palaver-stats.ardobras.workers.dev/ping`). An endpoint with
`<placeholder>` in it is never called. `PALAVER_STATS_URL` points a Palaver at
another endpoint (the tests' stub).

Later changes to the Worker: `npx wrangler deploy` again. Cloudflare itself
sees the IP address of every request at its edge, as any host does; this
Worker neither reads nor keeps it.
