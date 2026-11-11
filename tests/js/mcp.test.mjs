// Claude access (MCP, issue #45): the top bar indicator, the access log in
// Settings, and the "Read by …" line on a meeting.
import { test } from "node:test";
import assert from "node:assert/strict";

import { clientName, mcpIndicator, transcriptPart, mcpArgsText, mcpSizeText, mcpReadOf, filterLog,
  logClients, logMeetings, clearedText, logShown } from "../../web/logic.js";

const ID = "2026-10-27T16-03-07";
const CC = { name: "claude-code", version: "2.1.3" };
const DESKTOP = { name: "claude-ai", version: "0.14.1" };
const title = (id) => (id === ID ? "Hiring debrief" : null);

test("clientName says which app it is", () => {
  assert.equal(clientName(CC), "Claude Code 2.1.3");
  assert.equal(clientName(DESKTOP), "Claude Desktop 0.14.1");
  assert.equal(clientName({ name: "cursor" }), "cursor");
  assert.equal(clientName(CC, { version: false }), "Claude Code");
  assert.equal(clientName(null), "Unknown client");
});

test("the indicator shows only while clients are connected", () => {
  assert.equal(mcpIndicator([]), null);
  assert.equal(mcpIndicator(undefined), null);
  assert.deepEqual(mcpIndicator([{ pid: 1, client: CC }]),
    { text: "MCP · 1", title: "Claude can read your meetings: 1 client connected (Claude Code 2.1.3)" });
  assert.deepEqual(mcpIndicator([{ pid: 1, client: CC }, { pid: 2, client: DESKTOP }]),
    { text: "MCP · 2", title: "Claude can read your meetings: 2 clients connected (Claude Code 2.1.3, Claude Desktop 0.14.1)" });
});

test("transcriptPart says which part of the transcript went out", () => {
  assert.equal(transcriptPart({}), null);
  assert.equal(transcriptPart({ include_transcript: true }), "full transcript");
  assert.equal(transcriptPart({ from_minute: 0, to_minute: 20 }), "transcript 0–20 min");
  assert.equal(transcriptPart({ from_minute: 10 }), "transcript from 10 min");
  assert.equal(transcriptPart({ to_minute: 5 }), "transcript 0–5 min");
});

test("mcpArgsText: the arguments in short, a meeting's title rather than its id", () => {
  assert.equal(mcpArgsText({ tool: "get_meeting", args: { meeting_id: ID, to_minute: 20 } }, title),
    "Hiring debrief · transcript 0–20 min");
  assert.equal(mcpArgsText({ tool: "get_meeting", args: { meeting_id: ID } }, title), "Hiring debrief");
  assert.equal(mcpArgsText({ tool: "get_meeting", args: { meeting_id: "2026-01-02T03-04-05" } }, title),
    "2026-01-02T03-04-05");
  assert.equal(mcpArgsText({ tool: "search_meetings", args: { query: "salary", person: "Rico" } }, title),
    "“salary” · person Rico");
  assert.equal(mcpArgsText({ tool: "list_meetings", args: { project: "Hiring", since: "2026-10-01", limit: 5 } }, title),
    "project Hiring · since 2026-10-01 · limit 5");
  assert.equal(mcpArgsText({ tool: "get_project", args: { project: "Hiring" } }, title), "Hiring");
  assert.equal(mcpArgsText({ tool: "open_next_steps", args: { owner: "Timo" } }, title), "owner Timo");
  assert.equal(mcpArgsText({ tool: "list_people", args: {} }, title), "everyone");
  assert.equal(mcpArgsText({ tool: "list_meetings" }, title), "all meetings");
  assert.equal(mcpArgsText({ tool: "something_new", args: {} }, title), "");
});

test("mcpSizeText: how much went out", () => {
  assert.equal(mcpSizeText({ meetings: 3, lines: 12, chars: 18234 }), "3 meetings · 12 lines · 18k chars");
  assert.equal(mcpSizeText({ meetings: 1, lines: 1, chars: 900 }), "1 meeting · 1 line · 900 chars");
  assert.equal(mcpSizeText({ people: 0, chars: 2 }), "0 people · 2 chars");
  assert.equal(mcpSizeText({ projects: 1, meetings: 4, next_steps: 2, chars: 3000 }),
    "1 project · 4 meetings · 2 next steps · 3k chars");
  assert.equal(mcpSizeText({}), "");
  assert.equal(mcpSizeText(undefined), "");
});

test("mcpReadOf: who read the meeting last, and what of it that day", () => {
  const reads = [  // newest first, as /api/mcp?meeting= answers
    { time: "2026-10-29T14:02:11+01:00", client: CC, tool: "get_meeting", args: { meeting_id: ID, from_minute: 0, to_minute: 20 }, meetings: [ID] },
    { time: "2026-10-29T13:50:00+01:00", client: CC, tool: "search_meetings", args: { query: "salary" }, meetings: [ID] },
    { time: "2026-10-29T13:40:00+01:00", client: CC, tool: "get_meeting", args: { meeting_id: ID }, meetings: [ID] },
    { time: "2026-10-29T12:00:00+01:00", client: DESKTOP, tool: "list_meetings", args: {}, meetings: [ID] },
    { time: "2026-10-28T09:00:00+01:00", client: CC, tool: "list_meetings", args: {}, meetings: [ID] },
  ];
  assert.deepEqual(mcpReadOf(reads), { client: CC, time: "2026-10-29T14:02:11+01:00",
    parts: ["notes", "transcript 0–20 min", "search “salary”"] });
  assert.deepEqual(mcpReadOf(reads.slice(3)), { client: DESKTOP, time: "2026-10-29T12:00:00+01:00", parts: ["summary"] });
  const failed = { ...reads[0], error: "no such meeting" };
  assert.deepEqual(mcpReadOf([failed, reads[4]]).parts, ["summary"]);  // a failed call sent nothing
  assert.equal(mcpReadOf([failed]), null);
  assert.equal(mcpReadOf([]), null);
});

test("the log filters by client and by meeting", () => {
  const log = [
    { tool: "get_meeting", client: CC, meetings: [ID] },
    { tool: "list_people", client: DESKTOP },
    { tool: "list_meetings", client: CC, meetings: ["2026-10-26T09-00-00", ID] },
    { tool: "list_projects", client: null },
  ];
  assert.equal(filterLog(log, {}).length, 4);
  assert.deepEqual(filterLog(log, { client: "claude-code" }).map((e) => e.tool), ["get_meeting", "list_meetings"]);
  assert.deepEqual(filterLog(log, { meeting: ID }).map((e) => e.tool), ["get_meeting", "list_meetings"]);
  assert.deepEqual(filterLog(log, { client: "claude-ai", meeting: ID }), []);
  assert.deepEqual(logClients(log), [{ key: "claude-code", label: "Claude Code" }, { key: "claude-ai", label: "Claude Desktop" }]);
  assert.deepEqual(logMeetings(log), [ID, "2026-10-26T09-00-00"]);
});

test("clearedText for the toast", () => {
  assert.equal(clearedText(1), "Access log cleared · 1 entry");
  assert.equal(clearedText(42), "Access log cleared · 42 entries");
});

test("logShown: a meeting's entries come from the server, not from the newest 200", () => {
  const log = [{ tool: "list_people", client: CC }];  // the meeting's reads are older than these
  const reads = new Map([[ID, [{ tool: "get_meeting", client: CC, meetings: [ID] }, { tool: "list_meetings", client: DESKTOP, meetings: [ID] }]]]);
  assert.deepEqual(logShown(log, reads, { meeting: ID }).map((e) => e.tool), ["get_meeting", "list_meetings"]);
  assert.deepEqual(logShown(log, reads, { meeting: ID, client: "claude-ai" }).map((e) => e.tool), ["list_meetings"]);
  assert.deepEqual(logShown(log, new Map(), { meeting: ID }), []);  // still loading: what the log has
  assert.deepEqual(logShown(log, reads, {}).map((e) => e.tool), ["list_people"]);
});
