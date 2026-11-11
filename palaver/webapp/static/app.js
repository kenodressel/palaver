// Meetings: list, notes, transcript and speakers of every recording.

import { $, h, toast, remember, history as undoHistory, commands, isEditable, busy, leave, flash, menu, moreButton, play,
  usage, tracked } from "./ui.js";
import { meetingCommands, nextAfter, laneCommands, laneLines, linesText, namingText, withName, clock, roomText, roomNameText,
  unknownText,
  lineCommands, lineMarks, fixableWord, lineBefore, lineEditedText, cutKind,
  lineSpeakerChoices, nextLineOfSpeaker, lineSpeakerText,
  withProject, projectChange, projectCommands, renameText, voicesText, notesEstimate,
  personCommands, voiceCommands, termCommands, termChangeText, projectEditText,
  placeOf, hashOf, historyStep, navStart, navPush, navArrive, keyNav, mouseNav, inlinePlay,
  samePlace, undoStep, stopQuestionFor, stopAnswerText, recordingLine, audioWarnings, audioHints, gapsBefore,
  engineOptions, sendsText, accessLogText, testText, tokensText,
  transcriberOptions, transcriptionSendsText, priceText, transcriptionTestText, monthText,
  clientName, mcpIndicator, mcpArgsText, mcpSizeText, mcpReadOf, logShown, logClients, logMeetings,
  clearedText, linkTitle, eventLinkView, eventChangeText,
  noteKind, relatedOnly, firstMoment, chipRemoved, untranscribedText, memoryRows, memoryTotalText, memoryPolling,
  sizeText, storageTotalText, audioDaysLabel, audioDaysConfirm,
  SETUP_STEPS, setupStepAfter, setupStepBefore, stepButtons, gbText, downloadsText,
  downloadProgress, permissionText, recommendedHint, setupOfferText, testRecordingText, seedChecked,
  optionLabel, liveCoachFor, speakingText, questionsNote, questionButton, heartbeat, notesFromJobs,
  titleChange, updateCard, withTitle, retitledText, calendarHint, TITLE_MAX } from "./logic.js";
import { notepad, flushNotepads, leaveNotepads, notepadFocus, restoreNotepadFocus } from "./mynotes.js";
import { meetingTime } from "./mynotes-logic.js";
// Today, Needs you and the ⌘K palette (UI spec, phase 2).
import { needsSummary, needCards, needQuestion, startsInText, cutAtPointer, navCount, paletteMatch, paletteCommands,
  paletteRecent, paletteRecentShown, labelDisplay, meetingTabs, meetingTab, TAB_LABELS } from "./logic.js";
import { togglePalette, paletteOpen } from "./palette.js";
// Report a Problem and the usage counts (#59).
import { reportMeeting, reportDraft, reportDoneText, actionCatalog } from "./logic.js";
// Export and import of a meeting (#58).
import { inferredText, importedLine, importedText, GLOBAL_COMMANDS } from "./logic.js";
import { recordingNow, recordingCommand, RECORD_TEXT } from "./logic.js";
import { openExport, pickImport, wireDrop, importFile, askVoices, decideVoices, dialog } from "./exchange.js";
// Updates and uninstalling (#60).
import { updateIndicator, updateView, SETTINGS_PANES, settingsPane, settingsEntries } from "./logic.js";
// One person, one look; the header's people and projects; About this recording (UI cleanup 2026-10-30).
import { personColor, laneColors, attendeeTokens, meetingPeople, ownerTokens, nameMarks, projectView, aboutLines,
  sameTitle } from "./logic.js";

async function api(path, body) {
  const opts = body === undefined ? {} : {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
  const resp = await fetch(path, opts);
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.error || `${resp.status}`);
  if (path === "/api/undo") setTimeout(() => refreshTouched(data.restored));  // after the caller's own refresh
  return data;
}

// After an undo: the open meeting again, if the undo touched it (the answer names the meetings).
async function refreshTouched(ids) {
  const m = state.meeting;
  if (!m || !(ids || []).includes(m.id) || !onPage(m.id)) return;
  let fresh;
  try {
    fresh = await api(`/api/meetings/${encodeURIComponent(m.id)}`);
  } catch {
    return;  // gone (a cut undone): its own undo opens what is there now
  }
  if (state.meeting?.id !== fresh.id || !onPage(fresh.id)) return;
  state.meeting = fresh;
  keepingFocus(renderMeeting);
}

// --- formatting ---------------------------------------------------------

function minutes(seconds) {
  if (!seconds) return "";
  const m = Math.round(seconds / 60);
  if (m === 0) return "<1 min";
  return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} min`;
}

// A voice's badge: initials of its name ("Timo Strauß" → TS), a question mark while it has none.
// Drawn by CSS from data-initials: not part of the text, so "Carla" copies and reads as "Carla", not "CCarla".
function avatar(name) {
  const letters = (name || "").split(/[\s-]+/).filter((w) => /^\p{L}/u.test(w)).map((w) => w[0].toUpperCase());
  const text = letters.length > 1 ? letters[0] + letters[letters.length - 1] : letters[0];
  return h("span", { class: text ? "avatar" : "avatar unknown", "aria-hidden": "true", "data-initials": text || "?" });
}

// A person, looking the same wherever one is listed: the avatar in their
// colour (personColor) with the name beside it, as on the speaker lanes.
// ``color`` null: someone who did not speak, or no person of the meeting (a
// grey outline). ``small``: in a list item or a chip. ``named``: false for a
// voice without a name ("Speaker 2"), whose avatar is a question mark.
function personToken(name, color, { title = null, small = false, named = true } = {}) {
  return h("span", { class: `person-token${color ? "" : " silent"}${small ? " small" : ""}`,
    style: color ? `--c:${color}` : null, title },
  avatar(named ? name : null), h("span", { class: "person-name" }, name));
}

// Text with the names of a meeting's people in their colour (``people``:
// meetingPeople); no chips in running text.
function withNames(text, people) {
  const marks = nameMarks(text, people);
  if (!marks.length) return text;
  const out = [];
  let at = 0;
  for (const x of marks) {
    out.push(text.slice(at, x.a), nameMark(x.name, x.color));
    at = x.b;
  }
  out.push(text.slice(at));
  return out;
}

const nameMark = (name, color) => h("span", { class: "name-mark", style: `--c:${color}` }, name);

// Times on the 24-hour clock (15:00, not 3:00 PM), whatever the system's locale.
const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const dayFmt = new Intl.DateTimeFormat(undefined, { weekday: "long", day: "numeric", month: "long" });
const shortDayFmt = new Intl.DateTimeFormat(undefined, { weekday: "short", day: "numeric", month: "short" });
const weekdayFmt = new Intl.DateTimeFormat(undefined, { weekday: "long" });
const yearFmt = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "long", year: "numeric" });

function dayLabel(date) {
  const today = new Date();
  const d0 = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const d1 = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const diff = Math.round((d0 - d1) / 86400000);
  if (diff === 0) return "Today";
  if (diff === 1) return "Yesterday";
  if (diff === -1) return "Tomorrow";
  if (diff > 1 && diff < 7) return weekdayFmt.format(date);
  return (date.getFullYear() === today.getFullYear() ? dayFmt : yearFmt).format(date);
}

function fallbackTitle(m) {
  return m.start ? `Meeting at ${timeFmt.format(new Date(m.start))}` : m.id;
}

const INVITED_CHIPS = 5;

const STATE_TEXT = {
  recording: "Recording",
  processing: "Transcribing",
  waiting: "Waiting for models",
  failed: "Not transcribed",
  incomplete: "Incomplete",
};

// --- state ----------------------------------------------------------------

const state = {
  view: "meetings", // or "people"
  meetings: [],
  names: [],       // for the name fields' suggestions
  directory: null, // people across meetings
  projects: null,  // projects and the meetings in no project
  settings: null,  // app settings (realtime, auto-record switches)
  lm: null,        // Settings → Language model (/api/language-model); never holds a key
  lmError: null,   // what the last language-model change said
  lmTests: {},     // provider id -> {text} or {error}: the Test button's last answer
  lmReplacing: new Set(),  // providers whose key field is open to replace the key
  tr: null,        // Settings → Transcription (/api/transcription); never holds a key
  trError: null,   // what the last transcription change said
  trTests: {},     // service id -> {text} or {error}: the Test button's last answer
  trReplacing: new Set(),  // services whose key field is open to replace the key
  memory: null,  // what Palaver costs in memory, from the menu bar app (Settings)
  glossary: null,  // terms and suggestions
  review: [],      // finished meetings waiting for a review
  coach: null,     // the open meeting's coach numbers
  reviewAt: 0,     // which of them is open in the review
  notice: null,    // what the last glossary change did
  upcoming: [],    // calendar events still to come
  prepping: null,  // the upcoming meeting open for prep
  stream: null,    // the recording's newest lines and drafts (null until the first answer; {stream: false}: none)
  meeting: null,   // the open meeting
  lastMeeting: null, // the meeting opened last: the Meetings tab goes back to it
  tab: "notes",
  query: "",
  results: null,   // search results, or null when not searching
  understood: [],  // the filters the search read out of the text (chips)
  words: [],       // the words it looks for
  related: null,   // meetings found by meaning, beside the results
  filter: "",      // "p:<project id>" or "n:<person>": show only their meetings
  busy: false,     // cutting a meeting
  writing: new Map(),  // meeting id -> {startedAt, controller}: notes being written
  asking: false,   // the model sorts or describes projects
  remoteAsking: false,  // ... in a run this page did not start (before the server restarted, #57)
  showBrief: false, // unnamed voices under 10 s, folded away by default
  cutAt: null,     // the moment the open meeting would be cut at
  titleEdit: null, // the open meeting's title being typed: {id, draft}
  cutNotice: null, // what the last cut or join did
  sharedAsk: null, // the meeting just unmarked whose series is still remembered (#56)
  respelled: null, // the last spelling fixed in a meeting
  question: null,  // whether to stop the manual recording (/api/recording/question)
  mcp: null,       // Claude access: connected clients, the access log, setup (/api/mcp)
  mcpFilter: { client: "", meeting: "" },  // the access log's filters in Settings
  mcpReads: new Map(),  // meeting id -> what MCP clients read of it, newest first
  recording: null,  // why the running recording records: {meeting, text} (same answer)
  recommended: null, // the setup assistant's recommendations for this Mac, shown in Settings (#55)
  needs: null,     // what waits on the user, per meeting (/api/needs): Today, the strip, the dot, the counter
  todayLive: null, // the meeting being recorded, as Today's "Live now" shows it
  recent: loadRecent(),  // the places opened lately, for the palette
  allInvitees: null, // the meeting whose invitees all show (a big round shows eight and "+N more")
  aboutOpen: null, // the meeting whose "About this recording" is unfolded
  error: null,
};

const audio = $("#audio");
const voice = new Audio(); // speaker clips, from the remote track only

// --- list ------------------------------------------------------------------

// The list first; what needs the user follows (loadNeeds), never holding it up.
async function loadList() {
  try {
    [state.meetings, state.upcoming] = await Promise.all([api("/api/meetings"), api("/api/upcoming").catch(() => [])]);
  } catch (err) {
    state.meetings = [];
  }
  renderList();
  loadNeeds();
}

let needsRun = 0;
async function loadNeeds() {
  const run = ++needsRun;
  const needs = await api("/api/needs").catch(() => null);
  if (run !== needsRun || !needs) return;
  const before = state.needs;
  state.needs = needs;
  showNeeds(before, true);
}

// Show only one project's meetings, or one person's (spoke or was invited),
// most meetings first.
function renderFilter() {
  const people = new Map();
  const projects = new Map();
  for (const m of state.meetings) {
    for (const name of new Set([...m.people, ...m.invited])) people.set(name, (people.get(name) || 0) + 1);
    for (const p of m.projects) projects.set(p.id, [p.name, (projects.get(p.id)?.[1] || 0) + 1]);
  }
  const byCount = (a, b) => b[1] - a[1] || a[0].localeCompare(b[0]);
  const names = [...people].sort(byCount);
  const groups = [...projects].map(([id, [name, n]]) => [name, n, id]).sort(byCount);
  const key = JSON.stringify([state.filter, names, groups]);
  if (key === renderFilter.key) return; // the list refreshes often; keep an open menu open
  renderFilter.key = key;
  const option = (value, label) => h("option", { value, selected: value === state.filter }, label);
  $("#filter").replaceChildren(option("", "All meetings"),
    groups.length ? h("optgroup", { label: "Projects" }, groups.map(([name, n, id]) => option(`p:${id}`, `${name} (${n})`))) : null,
    names.length ? h("optgroup", { label: "People" }, names.map(([name, n]) => option(`n:${name}`, `${name} (${n})`))) : null);
  if (state.filter && !$("#filter").value) state.filter = ""; // its project or person is gone
}

function dropResult(id) {
  if (state.results) state.results = state.results.filter((x) => x.id !== id);
  if (state.related) state.related = state.related.filter((x) => x.id !== id);
}

function shown(m) {
  const [kind, value] = [state.filter.slice(0, 1), state.filter.slice(2)];
  if (kind === "p") return m.projects.some((p) => p.id === value);
  if (kind === "n") return m.people.includes(value) || m.invited.includes(value);
  return true;
}

// Who spoke, as small person tokens in their colours: the first three, "+N" for the rest.
function personLine(m) {
  const shown = m.people.slice(0, 3);
  const nameless = m.nameless ?? m.unnamed;  // every voice without a name, a to-do or not
  const more = m.people.length - shown.length + nameless;
  if (!shown.length) return nameless === 1 ? "1 speaker" : nameless ? `${nameless} speakers` : "";
  return [...shown.map((name) => personToken(name, personColor(name), { small: true })), more ? `+${more}` : null];
}

function todoLine(m) {
  if (m.status !== "ready") return null;
  const todo = [];
  if (m.unnamed) todo.push(`${m.unnamed} to name`);
  if (!m.has_notes) todo.push("no notes");
  else if (m.notes_stale) todo.push("notes out of date");
  return todo.length ? h("span", { class: "item-todo" }, todo.join(" · ")) : null;
}

function renderList() {
  const list = $("#list");
  const current = state.meeting?.id;
  list.replaceChildren();
  renderFilter();
  if (state.results) {
    const results = state.results.filter(shown);
    const related = relatedOnly(results, state.related).filter(shown);
    if (!results.length && !related.length) {
      list.append(h("p", { class: "list-empty" }, `Nothing found for “${state.query}”.`));
      return;
    }
    for (const r of results) list.append(resultItem(r, current));
    if (related.length) {
      list.append(h("div", { class: "day", title: "Similar wording, or the same thing in another language" },
        "Related by meaning"));
      for (const r of related) list.append(resultItem(r, current));
    }
    return;
  }
  list.append(recordCard("list"));
  if (!state.meetings.length) {
    list.append(h("p", { class: "day" }, "No recordings yet. Meetings appear here when a Teams call or Slack huddle ends, or when you record one."));
    return;
  }
  if (state.upcoming.length && !state.filter) {
    list.append(h("div", { class: "day" }, "Coming up"));
    for (const e of state.upcoming) {
      const start = new Date(e.start);
      list.append(h("button", { class: "item upcoming", "aria-current": String(state.prepping?.key === e.key),
        onclick: () => openPrep(e.key) },
        h("span", { class: "item-title" }, e.title || "Meeting"),
        h("span", { class: "item-meta" },
          h("span", {}, `${dayLabel(start) === "Today" ? "" : `${dayLabel(start)}, `}${timeFmt.format(start)}`),
          e.projects.length ? h("span", { class: "item-projects inline" }, e.projects.map((p) => p.name).join(" · ")) : null)));
    }
  }
  const meetings = state.meetings.filter(shown);
  if (!meetings.length) {
    list.append(h("p", { class: "list-empty" }, "No meetings here."));
    return;
  }
  let lastDay = null;
  for (const m of meetings) {
    const day = m.start ? dayLabel(new Date(m.start)) : "Undated";
    if (day !== lastDay) {
      list.append(h("div", { class: "day" }, day));
      lastDay = day;
    }
    list.append(meetingItem(m, current));
  }
}

// What of a meeting needs the user (its strip's summary), or null.
const needsOf = (id) => needsSummary(state.needs?.meetings.find((x) => x.id === id)?.items);

// A meeting in the list (and in Today's "Recent"): what it was, who, its state,
// projects, summary, what is left to do; a dot when something needs the user.
function meetingItem(m, current, { withDay = false } = {}) {
  const date = m.start ? new Date(m.start) : null;
  const stateText = state.writing.has(m.id) ? "Writing notes…" : STATE_TEXT[m.status];
  const who = personLine(m);
  const needs = needsOf(m.id);
  return h("button", { class: "item", "data-id": m.id, "aria-current": String(m.id === current),
    onclick: () => openMeeting(m.id), oncontextmenu: (e) => listMenu(m, e),
    title: m.title_from === "notes" ? "No calendar event; title from the notes" : null },
    needs ? h("span", { class: "needs-dot", title: `Needs you: ${needs.parts.join(", ")}` },
      h("span", { class: "visually-hidden" }, `Needs you: ${needs.parts.join(", ")}`)) : null,
    h("span", { class: "item-title" }, m.title || fallbackTitle(m)),
    h("span", { class: "item-meta" },
      date ? h("span", {}, withDay ? whenText(m.start) : timeFmt.format(date)) : null,  // the list has day headers; Recent has not
      m.duration ? h("span", {}, minutes(m.duration)) : null,
      who ? h("span", { class: "item-people" }, who) : null,
      m.imported ? h("span", { class: "item-state", title: `Imported from ${m.imported.from}` },
        `from ${m.imported.from}`) : null,
      stateText ? h("span", { class: m.status === "recording" ? "item-state recording" : "item-state" }, stateText) : null),
    m.projects.length ? h("span", { class: "item-projects" }, m.projects.map((p) => p.name).join(" · ")) : null,
    m.summary ? h("span", { class: "item-summary" }, m.summary) : null,
    todoLine(m),
  );
}

// The line around the first search word it contains, matched where a word
// starts (as the search does), that word marked (``tag``: mark, or strong
// for the notes, so a result has one mark: its line to jump to).
function mark(text, words, tag = "mark") {
  const escaped = words.flatMap((w) => w.split(/\s+/)).filter(Boolean).map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const m = escaped.length ? new RegExp(`(?<![\\p{L}\\p{N}_])(?:${escaped.join("|")})`, "iu").exec(text) : null;
  if (!m) return text.slice(0, 140);
  const i = m.index, end = i + m[0].length;
  const from = Math.max(0, i - 50);
  return [from ? "…" : "", text.slice(from, i), h(tag, {}, text.slice(i, end)), text.slice(end, end + 80)];
}

const clipText = (text, n = 110) => (text.length > n ? `${text.slice(0, n).replace(/\s+\S*$/, "")}…` : text);

// A meeting found: its decisions and next steps first, then the lines, each
// with who said it and when. The meeting and each line are buttons (Tab,
// Enter); a line opens the meeting at its moment. A click elsewhere on the
// card opens it at its first line.
function resultItem(r, current) {
  const words = state.words;
  const notesHits = r.notes_hits || [];
  const lines = r.hits || [];
  const meaning = r.meaning || [];
  const who = personLine(r);
  const line = (x, marked) => h("button", { type: "button", class: "hit hit-line", title: `Open at ${clock(x.start)}`,
    onclick: (e) => {
      e.stopPropagation();
      openMeeting(r.id, x.start);
    } },
    h("span", { class: "hit-time" }, clock(x.start)), " ",
    h("span", { class: "hit-who" }, `${x.speaker}: `), marked ? mark(x.text, words) : clipText(x.text));
  const note = (x, marked) => h("span", { class: "hit hit-note" },
    h("span", { class: "hit-kind" }, noteKind(x)), " ", marked ? mark(x.text, words, "strong") : clipText(x.text));
  return h("div", { class: "item result", "data-id": r.id, "aria-current": String(r.id === current),
    onclick: () => openMeeting(r.id, firstMoment(r)), oncontextmenu: (e) => listMenu(r, e) },
    h("button", { type: "button", class: "result-open", onclick: (e) => {
      e.stopPropagation();
      openMeeting(r.id, firstMoment(r));
    } },
      h("span", { class: "item-title" }, r.title || fallbackTitle(r)),
      h("span", { class: "item-meta" }, r.start ? h("span", {}, dayFmt.format(new Date(r.start))) : null,
        who ? h("span", { class: "item-people" }, who) : null,
        r.hit_count ? h("span", {}, `${r.hit_count} in transcript`) : null)),
    notesHits.map((x) => note(x, words.length)),
    lines.slice(0, 2).map((x) => line(x, words.length)),
    meaning.slice(0, 2).map((x) => (x.kind === "line" ? line(x, false) : note(x, false))),
    !notesHits.length && !lines.length && !meaning.length && r.summary ? h("span", { class: "item-summary" }, r.summary) : null,
  );
}

// Remembered in this browser only; private windows and blocked storage just show it again.
const HINT_KEY = "palaver.search.quotesHint";
function hintDismissed() {
  try {
    return localStorage.getItem(HINT_KEY) === "1";
  } catch {
    return false;
  }
}
function dismissHint() {
  try {
    localStorage.setItem(HINT_KEY, "1");
  } catch {
    /* shown again next time */
  }
  renderChips();
}

// The filters the search understood, as chips. × takes one out: a name
// stays as a quoted word, so its text is still searched for.
function renderChips() {
  const box = $("#search-chips");
  box.hidden = !state.understood.length || !state.query;
  const chips = state.understood.map((c) => h("span", { class: `search-chip chip-${c.kind}`, title: c.title },
    h("span", { class: "search-chip-label" }, c.label),
    h("button", { type: "button", class: "chip-btn", "aria-label": `Remove ${c.label}`,
      title: ["person", "project", "org"].includes(c.kind) && !c.written ? "Search it as a word instead" : "Remove this filter",
      onclick: () => {
        const field = $("#search");
        field.value = chipRemoved(field.value, c);
        field.focus();
        field.dispatchEvent(new Event("input"));
      } }, "×")));
  const hint = hintDismissed() ? null : h("p", { class: "search-hint" }, "Use \u201cquotes\u201d to search a word as text.",
    h("button", { type: "button", class: "chip-btn", "aria-label": "Dismiss the hint", onclick: dismissHint }, "×"));
  box.replaceChildren(...chips, hint || "");
}

$("#filter").addEventListener("change", (e) => {
  state.filter = e.target.value;
  renderList();
});

// The line around the first of ``words`` it contains, that word in bold.
function snippet(text, words) {
  const lower = text.toLowerCase();
  const word = words.find((w) => lower.includes(w.toLowerCase()));
  if (!word) return text.slice(0, 120);
  const i = lower.indexOf(word.toLowerCase());
  const from = Math.max(0, text.lastIndexOf(" ", Math.max(0, i - 30)) + 1);
  return [from ? "…" : "", text.slice(from, i), h("mark", {}, text.slice(i, i + word.length)),
          text.slice(i + word.length, i + word.length + 90)];
}

let searchTimer;
let searchRun = 0;
// The words and filters first; meetings related by meaning follow, when
// they can (an index, the model on this Mac), without holding up the rest.
async function runSearch() {
  const run = ++searchRun;
  const q = state.query;
  if (!q) {
    Object.assign(state, { results: null, understood: [], words: [], related: null });
    renderChips();
    renderList();
    return;
  }
  const page = await api(`/api/search?q=${encodeURIComponent(q)}`).catch(() => null);
  if (run !== searchRun || !page) return;
  const keep = state.related && state.relatedFor === q ? state.related : null;
  Object.assign(state, { results: page.results, understood: page.understood, words: page.words, related: keep });
  renderChips();
  renderList();
  if (page.meaning !== "ready" || keep) return;
  const related = await api(`/api/search/meaning?q=${encodeURIComponent(q)}`).catch(() => null);
  if (run !== searchRun || !related) return;
  Object.assign(state, { related, relatedFor: q });
  renderList();
}

$("#search").addEventListener("input", (e) => {
  clearTimeout(searchTimer);
  state.query = e.target.value.trim();
  searchTimer = setTimeout(runSearch, 250);
});

// --- meeting ---------------------------------------------------------------

// A named speaker has the person's colour, the same in every meeting; an
// unnamed one keeps its meeting colour while the meeting stays open: a merge,
// a removal or their undo doesn't repaint the other lanes (laneColors).
let palette = { id: null, cache: new Map() };
function colorOf(meeting) {
  if (palette.id !== meeting.id) palette = { id: meeting.id, cache: new Map() };
  const map = laneColors(meeting.speakers, palette.cache);
  return (label) => map.get(label ?? "__you") || "var(--ink-2)";
}

// The user's own organization, as the meeting has it: never shown, it goes without saying.
const ownOrgOf = (m) => m.speakers.find((s) => s.is_user)?.org || null;
const othersOrg = (org, m) => (org && !sameTitle(org, ownOrgOf(m)) ? org : null);

// ``how``: see historyStep; ``tab``: the tab to show, when going back to it.
async function openMeeting(id, at, { how = "push", tab = null } = {}) {
  const here = arrive(hashOf({ view: "meetings", id }), how);
  state.prepping = null;
  state.lastMeeting = id;
  const known = state.meetings.find((x) => x.id === id);
  if (known) keepRecent({ kind: "meeting", id, label: known.title || fallbackTitle(known) });
  setView("meetings");
  try {
    const m = await api(`/api/meetings/${encodeURIComponent(id)}`);
    if (movedOn(here)) return;
    const switching = state.meeting?.id !== m.id;
    state.meeting = m;
    state.cutAt = null;
    state.error = null;
    if (switching) {
      flushNotepads();
      state.cutNotice = null;
      state.respelled = null;
      state.eventPicker?.close?.();  // another meeting: its pop-up goes
      state.eventPicker = null;
      state.stream = null;
      state.editAt = null;
      state.titleEdit = null;
      state.coach = null;
      state.tab = meetingTab(m, { asked: tab, at, current: state.tab });
      audio.pause();
      audio.src = m.has_audio ? `/api/meetings/${encodeURIComponent(id)}/audio?track=mix` : "";
      $("#player").hidden = !m.has_audio;
      $("#duration").textContent = clock(m.duration);
      $("#scrub").max = m.duration || 1;
    }
    renderMeeting();
    renderList();
    if (at != null) seek(at, false);
    if (m.status === "recording") loadQuestion();
    loadMcpReads(m.id);
  } catch (err) {
    if (movedOn(here)) return;
    $("#main").replaceChildren(h("div", { class: "notice error" }, `This meeting could not be opened: ${err.message}`));
  }
}

// The date line's one status: live, still being transcribed, or reviewed.
function statusPill(m) {
  if (m.live) {
    return h("span", { class: "pill live-badge", title: "Updates every few seconds; speakers may still change" },
      `Live · transcribed up to ${clock(m.live.until)}`);
  }
  if (STATE_TEXT[m.status]) return h("span", { class: "pill state" }, STATE_TEXT[m.status]);
  if (m.reviewed) {
    const at = new Date(m.reviewed);
    return h("span", { class: "pill reviewed", title: `Reviewed ${dayFmt.format(at)}, ${timeFmt.format(at)}` }, "✓ Reviewed");
  }
  return null;
}

// "Wed, Oct 28 · 12:00 · 52 min · ✓ Reviewed": when, how long, its one status;
// "from Anna" on an imported meeting.
function dateLine(m, start) {
  const parts = [
    start ? h("span", { title: `${dayFmt.format(start)}, ${timeFmt.format(start)}` }, shortDayFmt.format(start)) : null,
    start ? h("span", {}, timeFmt.format(start)) : null,
    m.duration ? h("span", {}, minutes(m.duration)) : null,
    statusPill(m),
    m.local_only ? h("span", { class: "pill local-only",
      title: "Transcribed on this Mac, no cloud model gets this meeting, and Claude can't read it through MCP" },
    "On this Mac only") : null,
    m.imported ? h("span", { class: "from", title: importedLine(m.imported) }, `from ${m.imported.from}`) : null,
  ].filter(Boolean);
  return h("div", { class: "when" },
    parts.flatMap((p, i) => (i ? [h("span", { class: "sep", "aria-hidden": "true" }, "·"), p] : [p])));
}

// The people on the left, the projects on the right; wrapping when narrow.
function peopleRow(m) {
  const tokens = attendeeTokens(m);
  const projects = m.status === "ready" || m.live ? renderMeetingProjects(m) : null;
  if (!tokens.length && !projects) return null;
  return h("div", { class: "people-row" }, tokens.length ? renderInvitees(m, tokens) : null, projects);
}

// About this recording: what the recording itself says, folded away at the
// bottom of the page; hidden while there is nothing to say. What Claude read
// of it comes later (loadMcpReads) and shows it then.
function aboutSection(m) {
  const lines = aboutLines(m, state.recording);
  const read = mcpReadLine(m.id);
  const about = h("details", { class: "about", open: state.aboutOpen === m.id, hidden: !lines.length && read.hidden,
    ontoggle: () => { state.aboutOpen = about.open ? m.id : null; } },
  h("summary", {}, "About this recording"),
  h("ul", { class: "about-lines" }, lines.map((l) => h("li", { class: `about-${l.kind}${l.kind === "imported" ? " imported-line" : ""}` },
    l.text, l.kind === "audio" ? [" ", h("button", { type: "button", class: "link report-link",
      onclick: () => reportFrom(m, l.text) }, "Report…")] : null))),
  read);
  return about;
}

// A run of this meeting that failed (transcribing, writing the notes) and was
// not done right since, with the offer to report it (#59).
const FAILED_TEXT = { process: "Transcribing this meeting failed", notes: "Writing the notes failed" };
function failureLine(m) {
  const f = m.failure;
  if (!f && m.status !== "incomplete") return null;
  const text = f ? `${FAILED_TEXT[f.step] || "A step failed"}${f.error ? `: ${f.error}` : ""}`
    : "This recording is incomplete: it was not transcribed";
  return h("div", { class: "failure-line", role: "status" }, h("span", {}, text),
    h("button", { type: "button", class: "btn btn-quiet small", onclick: () => reportFrom(m, text) }, "Report a Problem…"));
}

function reportFrom(m, text) {
  usage.count("action", "meeting.reportFromError");
  openReport(m.id, text);
}

// [▶ Play] [Write notes] [⋯]: the frequent actions as buttons, the rare ones in the menu.
function meetingToolbar(m) {
  const c = meetingCommands(m);
  const more = moreButton(() => itemsFor(m, more), "More actions");
  return h("div", { class: "toolbar" },
    m.has_audio ? playButton() : null,
    m.status === "ready" ? h("button", { type: "button", class: "tbtn primary", title: `${c.writeNotes.label} (${c.writeNotes.shortcut})`,
      disabled: state.writing.has(m.id) || !c.writeNotes.enabled, onclick: () => writeNotes(m.id) },
    h("span", { "aria-hidden": "true" }, "✦"), h("span", { "data-writing": m.id }, writingText(m.id) ?? c.writeNotes.label)) : null,
    more);
}

function playButton() {
  const button = h("button", { type: "button", class: "tbtn tbtn-play", onclick: ACTIONS.play });
  showPlaying(button);
  return button;
}

function showPlaying(button) {
  const playing = !audio.paused;
  if (button.dataset.playing === String(playing)) return;
  button.dataset.playing = String(playing);
  button.replaceChildren(icon(playing ? ICONS.pause : ICONS.play), playing ? "Pause" : "Play");
}

// Another tab of the meeting. Leaving my notes saves them at once, before their editor leaves the page.
function setTab(tab) {
  if (state.tab === "mine" && tab !== "mine") leaveNotepads();
  if (tab !== state.tab) usage.count("tab", tab);
  state.tab = tab;
}

// A paragraph of my notes being written: the page is not built again under it by what refreshes on its own
// (the live transcript, the recording's question); that waits for the next poll after it.
const typingMyNotes = () => state.view === "meetings" && state.tab === "mine" && !!notepadFocus();
let renderLater = false;

function renderMeeting() {
  renderLater = false;
  const typing = notepadFocus();  // before the notepad moves into the new page
  if (state.view === "review") {
    renderReview();
    commands.publish();
    return;
  }
  const m = state.meeting;
  const color = colorOf(m);
  const start = m.start ? new Date(m.start) : null;

  // What the recording itself says (how it started, its audio, who transcribed it, what Claude read) is
  // in About this recording at the bottom; only while it records does its line stay up here.
  const live = m.status === "recording" || !!m.live;
  const hint = calendarHint(m);
  const head = h("header", { class: "head" },
    h("div", { class: "head-text" },
      renderTitle(m),
      hint ? h("div", { class: "title-hint", title: linkTitle(m.calendar?.link) }, hint) : null,
      dateLine(m, start),
      renderEventLink(m),
      live && recordingLine(m, state.recording) ? h("div", { class: "recorded" }, recordingLine(m, state.recording)) : null,
      importedVoices(m),
      sharedLine(m),
      (live ? audioWarnings(m, state.recording) : []).map((text) => h("div", { class: "audio-warning", role: "status" }, text,
        h("button", { type: "button", class: "link report-link", onclick: () => reportFrom(m, text) }, "Report…"))),
      failureLine(m),
      audioHints(m, state.recording).map((text) => h("div", { class: "audio-hint" }, text)),
      coachLive(m)),
    meetingToolbar(m),
    peopleRow(m),  // the header's whole width, under the toolbar too
  );

  // Summary: what the language model wrote (✦, as on Write notes); Notes: mine.
  const tabs = h("div", { class: "tabs", role: "tablist" },
    meetingTabs(m).map((t) => h("button", {
      class: "tab", role: "tab", "aria-selected": String(state.tab === t),
      title: t === "notes" ? "AI generated: the language model wrote this from the transcript" : null,
      onclick: () => { setTab(t); renderMeeting(); saveHere(); },
    }, h("span", { class: "tab-label" }, TAB_LABELS[t]),
    t === "notes" ? h("span", { class: "tab-ai", "aria-hidden": "true" }, "✦") : null)));

  const body = state.tab === "notes" ? renderNotes(m, color) : state.tab === "mine" ? myNotes(m)
    : state.tab === "coach" ? renderCoach(m) : renderTranscript(m, color);

  const cutNotice = state.cutNotice ? h("p", { class: "inline-notice" }, state.cutNotice.text, " ",
    state.cutNotice.id ? h("button", { class: "link", onclick: () => { const id = state.cutNotice.id; state.cutNotice = null; openMeeting(id); } },
      "Open it") : null) : null;
  const page = h("article", { class: "meeting" }, head,
    renderNeedsStrip(m),
    renderStopQuestion(m),
    cutNotice,
    respelledNotice(),
    renderCutSuggestion(m),
    renderSilenceSuggestion(m),
    renderSharedSuggestion(m),
    renderSharedAsk(m),
    m.status === "ready" || m.transcript.length ? renderRibbon(m, color) : null,
    tabs,
    body,
    aboutSection(m));
  keepingTitle(() => $("#main").replaceChildren(page));
  restoreNotepadFocus(typing);
  updatePlayhead();
  commands.publish();
}

// The user's own notes (#44), the Notes tab: live, with a time chip per paragraph; afterwards the chip
// plays from there.
function myNotes(m) {
  const id = m.id;
  const live = () => (state.meeting?.id === id && state.meeting.status === "recording" ? state.meeting : null);
  return notepad(`m:${id}`, `/api/meetings/${encodeURIComponent(id)}/my-notes`, {
    timeNow: () => (live() ? meetingTime(live().start, Date.now()) : null),
    seek: m.has_audio ? (at) => { if (state.meeting?.id === id) seek(at, true); } : null,
    revision: m.my_notes_revision,
  });
}

// --- the title, renamed in place ---------------------------------------------------

let replacing = false;  // the title field is being made again: its leaving the page is no blur that saves

// Builds the page, or its title, again: a title being typed keeps focus and what is selected.
function keepingTitle(build) {
  const a = document.activeElement;
  const typing = a?.classList?.contains("title-input") ? { start: a.selectionStart, end: a.selectionEnd } : null;
  replacing = true;
  try {
    build();
  } finally {
    replacing = false;
  }
  const field = typing ? $("#main .title-input") : null;
  if (!field) return;
  field.focus({ preventScroll: true });
  field.setSelectionRange(typing.start, typing.end);
}

// The big title: a click makes it a field (Enter and leaving it save, Esc cancels).
function renderTitle(m) {
  const edit = state.titleEdit?.id === m.id ? state.titleEdit : null;
  if (!edit) {
    return h("h1", {}, h("button", { type: "button", class: "title-button", title: "Rename", onclick: () => startRename() },
      titleOf(m)));
  }
  const field = h("input", { type: "text", class: "title-input", value: edit.draft, maxlength: TITLE_MAX,
    placeholder: titleOf(withTitle(m, "")), "aria-label": "Meeting title", spellcheck: "false",
    oninput: () => { edit.draft = field.value; },
    onkeydown: (e) => {
      if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); endRename(m.id, true, true); }
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); endRename(m.id, false, true); }
    },
    onblur: () => { if (!replacing) endRename(m.id, true, false); } });
  return h("h1", { class: "editing" }, field);
}

// Only the title and the line under it are made again: a click that left the
// field lands on the page as it was.
function showTitle(id) {
  const m = state.meeting;
  if (m?.id !== id || !onPage(id)) return;
  const old = state.view === "meetings" ? $("#main .head h1") : null;
  if (!old) {
    renderMeeting();
    return;
  }
  keepingTitle(() => old.replaceWith(renderTitle(m)));
  const hint = calendarHint(m);
  const line = $("#main .head .title-hint");
  if (hint && line) line.textContent = hint;
  else if (hint) $("#main .head h1").after(h("div", { class: "title-hint" }, hint));
  else line?.remove();
}

function startRename() {
  const m = state.meeting;
  if (!m || state.view !== "meetings") return;
  state.titleEdit = { id: m.id, draft: m.title || "" };
  showTitle(m.id);
  const field = $("#main .title-input");
  field?.focus();
  field?.select();
}

// ``save``: Enter or leaving the field; ``refocus``: by key, focus stays on the title.
function endRename(id, save, refocus) {
  const edit = state.titleEdit;
  if (!edit || edit.id !== id) return;
  state.titleEdit = null;
  const m = state.meeting?.id === id ? state.meeting : null;
  showTitle(id);
  if (refocus) $("#main .title-button")?.focus({ preventScroll: true });
  if (save && m) renameMeeting(m, edit.draft);
}

// A meeting's title in the list and the search results, until they are loaded again.
function retitle(id, m) {
  for (const list of [state.meetings, state.results, state.related]) {
    for (const x of list || []) if (x.id === id) Object.assign(x, { title: m.title, title_from: m.title_from });
  }
  renderList();
}

// Shown at once; the server's answer (or its refusal) follows. Undo sets the title it had.
async function renameMeeting(m, typed) {
  const title = titleChange(m, typed);
  if (title === null) return;
  const id = m.id;
  const shown = withTitle(m, title);
  if (state.meeting?.id === id) {
    state.meeting = { ...state.meeting, title: shown.title, title_from: shown.title_from };
    showTitle(id);
  }
  retitle(id, shown);
  let r;
  try {
    r = await api(`/api/meetings/${encodeURIComponent(id)}/title`, { title });
  } catch (err) {
    if (state.meeting?.id === id) {
      state.meeting = { ...state.meeting, title: m.title, title_from: m.title_from };
      showTitle(id);
    }
    retitle(id, m);
    errorToast(`The title was not saved: ${err.message}`, { action: { label: "Try again", run: () => renameMeeting(m, typed) } });
    return;
  }
  const { undo: token, ...updated } = r;
  showRetitled(id, updated);
  remember(retitledText(updated, titleOf(updated)), () => titleBack(id, token));
}

// The title as the server has it now (only the title: the rest of the page
// may be newer, a live meeting's); the list item flashes.
function showRetitled(id, m) {
  if (state.meeting?.id === id) {
    state.meeting = { ...state.meeting, title: m.title, title_from: m.title_from, calendar: m.calendar };
    showTitle(id);
  }
  retitle(id, m);
  const item = listItem(id);
  if (item) flash(item);
}

async function titleBack(id, token) {
  await api("/api/undo", { token });
  showRetitled(id, await api(`/api/meetings/${encodeURIComponent(id)}`));
  loadList();
}

// --- meeting actions ---------------------------------------------------------

const titleOf = (m) => m.title || fallbackTitle(m);

const SVG_NS = "http://www.w3.org/2000/svg";
function icon(d) {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", d);
  svg.append(path);
  return svg;
}

const ICONS = {
  play: "M7 4l13 8-13 8z",
  rename: "M4 20h4L19 9l-4-4L4 16zM14 6l4 4",
  pause: "M6 5h4v14H6zM14 5h4v14h-4z",
  changeEvent: "M6 5h12a3 3 0 0 1 3 3v10a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V8a3 3 0 0 1 3-3zM3 10h18M8 3v4M16 3v4",
  joinPrevious: "M8 7l-5 5 5 5M3 12h12M21 5v14",
  joinNext: "M16 7l5 5-5 5M21 12H9M3 5v14",
  split: "M9 6a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM20 4L8.1 15.9M14.5 14.5L20 20M8.1 8.1L12 12",
  reviewAgain: "M4 12l5 5L20 6",
  transcribe: "M4 12a8 8 0 0 1 14-5.3M20 4v4h-4M20 12a8 8 0 0 1-14 5.3M4 20v-4h4",
  localOnly: "M6 11h12v10H6zM9 11V7a3 3 0 0 1 6 0v4",
  forgetSeries: "M4 4l16 16M7 5h12a2 2 0 0 1 2 2v10M3 9v10a2 2 0 0 0 2 2h12M3 9h6",
  export: "M12 3v12M7 8l5-5 5 5M5 14v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5",
  shared: "M8 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM16 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM2 20c0-3 3-5 6-5s6 2 6 5M14.5 15.3A6.5 6.5 0 0 1 16 15c3 0 6 2 6 5",
  report: "M5 21V4M5 4h12l-2 4 2 4H5",
  trash: "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
  deleteAudio: "M4 9h4l5-4v14l-5-4H4zM16 9l5 6M21 9l-5 6",
};

// What each command does to a meeting; ``from`` is the button (⋯ or the
// list item) that shows the work is under way. Every call is counted (#59).
const ACTIONS = tracked("meeting", {
  play: () => playPause(),
  writeNotes: () => writeNotes(state.meeting.id),
  rename: async (m) => {
    await showMeeting(m);
    startRename();
  },
  changeEvent: async (m) => {
    await showMeeting(m);
    await openEventPicker(m.id);
  },
  joinPrevious: (m, from) => joinMeeting(m, "previous", from),
  joinNext: (m, from) => joinMeeting(m, "next", from),
  split: async (m) => {
    await showMeeting(m);
    startSplit();
  },
  reviewAgain: (m) => reviewAgain(m),
  transcribe: (m, from) => transcribeAgain(m, from),
  localOnly: (m, from) => toggleLocalOnly(m, from),
  shared: (m, from) => markShared(m, !m.shared?.meeting, from),
  forgetSeries: (m, from) => rememberSeries(m, false, from),
  export: (m) => openExport(m, titleOf(m)),
  report: (m) => openReport(m.id),
  deleteAudio: (m, from) => deleteAudio(m, from),
  trash: (m, from) => trashMeeting(m, from),
});

// The ⋯ menu, in the spec's order: Move to Trash last, red, after a separator.
const MENU_ORDER = ["transcribe", "rename", "changeEvent", "joinPrevious", "joinNext", "split", "reviewAgain", "export", "localOnly",
  "shared", "forgetSeries", "report", null, "deleteAudio", "trash"];
function itemsFor(m, from) {
  const c = meetingCommands(m);
  return MENU_ORDER.filter((name) => !name || !c[name].hidden).map((name) => name && {
    label: c[name].label, shortcut: c[name].shortcut, danger: c[name].danger, disabled: !c[name].enabled,
    icon: icon(ICONS[name]), run: () => ACTIONS[name](m, from),
  });
}

// The native menu bar and the keys run these against the open meeting.
const BOUND_KEYS = { trash: "⌘⌫", joinPrevious: "⌘J", writeNotes: "⌘⇧N" };  // Space (play) is bound below
for (const name of Object.keys(ACTIONS)) {
  commands.register(name, {
    shortcut: BOUND_KEYS[name],
    enabled: () => state.view === "meetings" && !!state.meeting && meetingCommands(state.meeting)[name].enabled
      && !(name === "writeNotes" && state.writing.has(state.meeting?.id)),
    run: () => ACTIONS[name](state.meeting, $("#main .head .more")),
  });
}

async function showMeeting(m) {
  if (state.view !== "meetings" || state.meeting?.id !== m.id) await openMeeting(m.id);
}

const listItem = (id) => document.querySelector(`#list .item[data-id="${CSS.escape(id)}"]`);

// busy() when there is a button to show it on.
const working = (button, work) => (button?.isConnected ? busy(button, work) : work);

// Right-click on a list item: the meeting's ⋯ menu, run against that meeting.
async function listMenu(entry, e) {
  e.preventDefault();
  const item = e.currentTarget;
  let at = { x: e.clientX, y: e.clientY };
  if (!at.x && !at.y) {  // from the keyboard
    const r = item.getBoundingClientRect();
    at = { x: r.left + 12, y: r.bottom - 4 };
  }
  let m = state.meeting?.id === entry.id ? state.meeting : null;
  if (!m) {
    try {
      m = await api(`/api/meetings/${encodeURIComponent(entry.id)}`);
    } catch (err) {
      errorToast(`This meeting could not be opened: ${err.message}`);
      return;
    }
  }
  if (item.isConnected) menu(itemsFor(m, item), at);
}

// Split At…: the cut bar at the line playing, else where a cut is suggested, else the second line.
function startSplit() {
  const m = state.meeting;
  const playing = audio.currentTime ? speakingAt(audio.currentTime) : -1;
  openCut(playing > 0 ? m.transcript[playing].start : m.cut_suggestion?.at ?? m.transcript[1]?.start ?? null);
}

// The cut bar above the line at ``at``; the lines from there on dim.
function openCut(at) {
  state.cutAt = at;
  if (state.view !== "review") setTab("transcript");
  renderMeeting();
  const bar = document.querySelector("#main .cut-bar");
  bar?.scrollIntoView({ block: "nearest" });
  bar?.querySelector("button:not([disabled])")?.focus({ preventScroll: true });
}

// Back on the line once its editor or the cut bar closed, unless focus went elsewhere meanwhile.
function focusLine(start) {
  const a = document.activeElement;
  if (a && a !== document.body) return;
  document.querySelector(`#main .turn[data-start="${start}"]`)?.focus({ preventScroll: true });
}

function closeEditor(start) {
  state.editAt = null;
  renderMeeting();
  focusLine(start);
}

// The meeting's audio changed under the same id (joined, cut, or undone).
function reloadAudio() {
  const m = state.meeting;
  if (!m?.has_audio) return;
  audio.src = `/api/meetings/${encodeURIComponent(m.id)}/audio?track=mix&v=${Date.now()}`;
  $("#duration").textContent = clock(m.duration);
  $("#scrub").max = m.duration || 1;
}

// --- export and import (#58) ---------------------------------------------------------

// The question about the voices that came with an import, while it is open (who sent it is on the
// date line, the rest of the import in About this recording).
function importedVoices(m) {
  const voices = m.imported?.voices || [];
  if (!voices.length) return null;
  return h("div", { class: "recorded imported-voices" },
    `Came with the voices of ${voices.map((v) => v.name).join(", ")}: `,
    h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => answerVoices(m, true, e.currentTarget) },
      "Add to Voice Bank"),
    h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => answerVoices(m, false, e.currentTarget) },
      "Don’t Add"));
}

async function answerVoices(m, add, button) {
  let r;
  try {
    r = await decideVoices(m.id, add, button);
  } catch (err) {
    toast(`Not changed: ${err.message}`);
    return;
  }
  voicesAnswered(m.id, r, add);
}

function voicesAnswered(id, r, add) {
  if (state.meeting?.id === id) {
    state.meeting = r;
    renderMeeting();
  }
  remember(add ? "Their voices are in your voice bank" : "Their voices were not kept", async () => {
    await api("/api/undo", { token: r.undo });
  });
}

// Import…: a picked or dropped exported .zip becomes a meeting; Undo takes it back to the trash.
async function runImport(file) {
  const answer = await importFile(file);
  if (!answer) return;
  await loadList();
  await openMeeting(answer.imported);
  const item = listItem(answer.imported);
  if (item) {
    item.scrollIntoView({ block: "nearest" });
    flash(item);
  }
  const title = titleOf(state.meeting?.id === answer.imported ? state.meeting
    : state.meetings.find((x) => x.id === answer.imported) || { id: answer.imported });
  remember(importedText(title, answer), () => undoImport(answer));
  if (answer.voices?.length) {
    const r = await askVoices(answer.imported, answer.voices, answer.from);
    if (r) voicesAnswered(answer.imported, r, r.added);
  }
}

async function undoImport(answer) {
  await api("/api/undo", { token: answer.undo });
  await loadList();
  if (state.view === "meetings" && state.meeting?.id === answer.imported) {
    state.meeting = null;
    const next = answer.beside || state.meetings[0]?.id;
    if (next) await openMeeting(next, undefined, { how: "replace" });
    else openMeetingsList("replace");
  }
}

commands.register("importMeeting", { enabled: () => true, run: () => pickImport(runImport) });

// --- recording by hand (#11) ---------------------------------------------------------

// Start Recording, as the menu bar icon's: an on-site meeting, a conversation, a call Palaver does not see.
async function startRecording(from) {
  let meeting;
  try {
    ({ meeting } = await working(from, api("/api/recording/start", {})));
  } catch (err) {
    errorToast(`Not started: ${err.message}`);
    return;
  }
  toast("Recording. Stop it here, or from the menu bar icon.", { short: true });
  await loadList();
  if (state.view === "today") await refreshToday();
  else if (state.view === "meetings") openMeeting(meeting);
}

// Stop: whatever records, as the menu's Stop Recording; transcribed after.
async function stopRecording(id, from) {
  try {
    await working(from, api("/api/recording/end", { meeting: id }));
  } catch (err) {
    errorToast(`Not stopped: ${err.message}`);
    loadList();
    return;
  }
  state.question = null;
  toast("Recording stopped. It is transcribed now.", { short: true });
  await loadList();
  if (state.view === "today") await refreshToday();
  else if (onPage(id)) openMeeting(id);
}

commands.register("startRecording", { enabled: () => !recordingNow(state.meetings), run: () => startRecording(),
  shortcut: "⇧⌘R" });
commands.register("stopRecording", { enabled: () => !!recordingNow(state.meetings),
  run: () => stopRecording(recordingNow(state.meetings).id) });

// The card to record by hand, or the recording that runs with its Stop: on Today ("today") and atop the list.
function recordCard(where) {
  const rec = recordingNow(state.meetings);
  const cls = where === "today" ? "record-card" : "record-card compact";
  if (where === "today" && rec && state.todayLive) return h("section", { class: cls, hidden: true });  // Live now has it
  if (rec) {
    const start = rec.start ? new Date(rec.start) : null;
    return h("section", { class: `${cls} recording`, "aria-label": "Recording" },
      h("div", { class: "record-text" },
        h("span", { class: "pill live-badge" }, "Recording"),
        h("span", { class: "meta" }, start ? `since ${timeFmt.format(start)}` : "")),
      h("div", { class: "record-actions" },
        where === "today" ? h("button", { type: "button", class: "tbtn", onclick: () => openMeeting(rec.id) }, "Open") : null,
        h("button", { type: "button", class: "tbtn", onclick: (e) => stopRecording(rec.id, e.currentTarget) },
          h("span", { class: "stop-mark", "aria-hidden": "true" }), "Stop")));
  }
  const button = h("button", { type: "button", class: "tbtn primary record-btn", title: "⇧⌘R",
    onclick: (e) => startRecording(e.currentTarget) }, h("span", { class: "rec-dot", "aria-hidden": "true" }), "Start Recording");
  return h("section", { class: cls, "aria-label": "New recording" },
    h("div", { class: "record-text" }, h("h2", {}, "New recording"), h("p", {}, RECORD_TEXT)), button);
}
wireDrop(runImport);
$("#import-btn")?.addEventListener("click", () => pickImport(runImport));

// Undo of a trash or a join: the meetings come back, ``prefer`` opens, each flashes in the list.
// ``undid``: the meetings whose page the change took (the one gone, the one opened
// in its place); on one of those the meeting takes that page's place again.
async function restoreMeetings(token, prefer, undid = [prefer]) {
  const r = await api("/api/undo", { token });
  if (state.query) await runSearch();
  await loadList();
  const id = r.restored.includes(prefer) ? prefer : r.restored[0];
  if (id) {
    const same = state.view === "meetings" && state.meeting?.id === id;
    await openMeeting(id, undefined, { how: undoStep(location.hash, undid) });
    if (same) reloadAudio();
  }
  for (const x of r.restored) {
    const el = listItem(x);
    if (el) flash(el);
  }
}

// Meetings with a trash or join under way: a second ⌘⌫ or ⌘J meanwhile does nothing.
const pending = new Set();

// To Recordings/.trash: the list item slides out and the next meeting opens; Undo brings it back.
async function trashMeeting(m, from) {
  if (pending.has(m.id)) return;
  pending.add(m.id);
  const title = titleOf(m);
  let r;
  try {
    r = await working(from, api(`/api/meetings/${encodeURIComponent(m.id)}/trash`, {}));
  } catch (err) {
    errorToast(`“${title}” was not moved to Trash: ${err.message}`,
      { action: { label: "Try again", run: () => trashMeeting(m, from) } });
    return;
  } finally {
    pending.delete(m.id);
  }
  const open = state.view === "meetings" && state.meeting?.id === m.id;
  // What the list shows (search results, a filter), not all meetings.
  const shownIds = [...document.querySelectorAll("#list .item[data-id]")].map((el) => ({ id: el.dataset.id }));
  const next = open ? nextAfter(shownIds, m.id) : null;
  state.meetings = state.meetings.filter((x) => x.id !== m.id);
  dropResult(m.id);
  remember(`“${title}” moved to Trash`, () => restoreMeetings(r.undo, m.id, [m.id, next?.id ?? null]));
  if (open) {
    state.meeting = null;
    commands.publish();
    audio.pause();
    listItem(m.id)?.setAttribute("aria-current", "false");
    listItem(next?.id ?? "")?.setAttribute("aria-current", "true");
  }
  const item = listItem(m.id);
  if (item) await leave(item);
  if (open && state.view === "meetings" && !state.meeting) {
    if (next) {
      await openMeeting(next.id, undefined, { how: "replace" });
    } else {
      $("#player").hidden = true;
      $("#main").replaceChildren(h("div", { class: "empty" }, "No recordings."));
    }
  }
  loadList();
}

// Two recordings of one meeting become one: the other's list item goes, the kept one flashes.
async function joinMeeting(m, side, from) {
  const other = m.neighbours?.[side];
  if (!other || pending.has(m.id)) return;
  pending.add(m.id);  // until the joined meeting is open: m may be gone by then
  try {
    let r;
    try {
      r = await working(from, api(`/api/meetings/${encodeURIComponent(m.id)}/join`, { with: other.id }));
    } catch (err) {
      errorToast(`Not joined: ${err.message}`, { action: { label: "Try again", run: () => joinMeeting(m, side, from) } });
      return;
    }
    remember(`Joined with “${other.title || fallbackTitle(other)}”`, () => restoreMeetings(r.undo, m.id, [m.id, other.id]));
    const goneId = r.id === m.id ? other.id : m.id;
    dropResult(goneId);
    const gone = listItem(goneId);
    if (gone) await leave(gone);
    await loadList();
    const same = state.view === "meetings" && state.meeting?.id === r.id;
    await openMeeting(r.id, undefined, { how: "replace" });
    if (same) reloadAudio();
    const kept = listItem(r.id);
    if (kept) flash(kept);
  } finally {
    pending.delete(m.id);
  }
}

const INVITEES_SHOWN = 8;

// Who was invited, as person tokens: who spoke first, in their colour; who
// did not in a grey outline. A big round shows the first eight and "+N more".
function renderInvitees(m, tokens) {
  const all = state.allInvitees === m.id || tokens.length <= INVITEES_SHOWN + 1;
  const shown = all ? tokens : tokens.slice(0, INVITEES_SHOWN);
  return h("div", { class: "invitees", role: "group", "aria-label": "Invited, from your calendar" },
    shown.map((t) => personToken(t.name, t.color, { title: t.title })),
    shown.length < tokens.length ? h("button", { type: "button", class: "btn btn-quiet small more-invitees",
      onclick: () => { state.allInvitees = m.id; renderMeeting(); } }, `+${tokens.length - shown.length} more`) : null);
}

// The meeting's projects: confirmed and unsure chips, the best suggestion
// while none is confirmed; the other suggestions head the "+ Project" picker.
function renderMeetingProjects(m) {
  const sure = (p) => p.by === "you";
  const view = projectView(m);
  const add = (typed) => {
    const name = typed.trim();
    if (!name) return;
    const suggested = view.picker.find((p) => p.suggested && p.name === name);
    setMeetingProject(m.id, suggested ? { project: suggested.id } : { name: typed });
  };
  return h("div", { class: "project-row", "aria-label": "Projects" },
    m.projects.map((p) => h("span", { class: `project-chip${sure(p) ? "" : " unsure"}`, "data-project": p.id ?? "",
      title: sure(p) ? null : linkTitle(p.link) || `Sorted ${p.by === "model" ? "by the model" : `automatically: ${p.why}`}` },
      h("button", { class: "link", onclick: () => openProjects(p.id) }, p.name),
      sure(p) ? null : h("button", { class: "chip-btn", title: `Yes, this is ${p.name}`, "aria-label": `Confirm ${p.name}`,
        onclick: () => setMeetingProject(m.id, { project: p.id }) }, "✓"),
      p.id == null ? null : h("button", { class: "chip-btn", title: `Not ${p.name}`, "aria-label": `Remove from ${p.name}`,
        onclick: () => setMeetingProject(m.id, { project: p.id, remove: true }) }, "×"))),
    view.suggestions.map((s) => h("button", { class: "chip", style: "--c:var(--ink-3)", "data-project": s.id,
      title: `Alike: ${s.why}. Click to add.`, onclick: () => setMeetingProject(m.id, { project: s.id }) }, `${s.name}?`)),
    h("input", { class: "project-input", placeholder: "+ Project", list: "project-names", spellcheck: "false",
      "aria-label": "Add to a project, or name a new one",
      onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = ""; e.target.blur(); } },
      onchange: (e) => add(e.target.value) }),
    h("datalist", { id: "project-names" }, view.picker.map((p) => h("option", { value: p.name,
      label: p.suggested ? `Suggested${p.why ? ` · alike: ${p.why}` : ""}` : null }))));
}

// Renders again; focus that was on a chip goes to the same button if it is
// still there, else to another chip's button, else to the main area: not to
// the "+ Project" field, where ⌘Z would edit text instead of undoing; never to <body>.
function keepingProjectFocus(render) {
  const a = document.activeElement;
  const inRow = a?.closest?.(".project-row");
  const label = inRow ? a.getAttribute("aria-label") : null;
  render();
  if (!inRow) return;
  const row = document.querySelector("#main .project-row");
  const buttons = [...(row?.querySelectorAll("button") || [])];
  const same = label ? [...buttons, row?.querySelector(".project-input")].find((el) => el?.getAttribute("aria-label") === label) : null;
  (same || buttons.find((b) => b.classList.contains("chip-btn")) || buttons[0] || $("#main"))
    ?.focus({ preventScroll: true });
}

function showMeetingProjects(id, m) {
  if (state.meeting?.id !== id) return;
  state.meeting = m;
  if (onPage(id)) keepingProjectFocus(renderMeeting);
}

// A chip added, confirmed or removed: shown at once, rolled back when the
// server says no. ``before``: the meeting as it was at the first try.
async function setMeetingProject(id, change, before = state.meeting?.id === id ? state.meeting : null) {
  const shown = before && state.meeting === before ? withProject(before, change) : null;
  if (shown) showMeetingProjects(id, shown);
  let m;
  try {
    m = await api(`/api/meetings/${encodeURIComponent(id)}/projects`, change);
  } catch (err) {
    if (shown && state.meeting === shown) showMeetingProjects(id, before);
    errorToast(`The project was not changed: ${err.message}`,
      { action: { label: "Try again", run: () => setMeetingProject(id, change, before) } });
    return;
  }
  showMeetingProjects(id, m);
  loadList();
  // Without the meeting from before (a retry from another page), the answer names the project.
  const done = projectChange(before || { projects: [] }, change, m);
  if (done) remember(done.text, () => meetingProjectBack(id, m.undo, done.id));
}

// Undo of a chip change: the projects as they were (a suggestion stays a
// suggestion, an unsure project unsure); a chip back in place flashes.
async function meetingProjectBack(id, token, pid) {
  await api("/api/undo", { token });
  loadList();
  if (state.meeting?.id !== id) return;
  showMeetingProjects(id, await api(`/api/meetings/${encodeURIComponent(id)}`));
  const chip = onPage(id) && pid ? document.querySelector(`#main .project-chip[data-project="${CSS.escape(pid)}"]`) : null;
  if (chip) flash(chip);
}

const laneGroup = (label) => document.querySelector(`.lane-group[data-label="${CSS.escape(label)}"]`);
const laneTurns = (label) => [...document.querySelectorAll(`.turn[data-label="${CSS.escape(label)}"]`)];

function renderRibbon(m, color) {
  const duration = m.duration || Math.max(1, ...m.transcript.map((t) => t.end));
  const ribbon = h("section", { class: "ribbon", "aria-label": "Who spoke when" });
  // Names to pick from: this meeting's invitees first, then everyone known.
  ribbon.append(h("datalist", { id: "meeting-names" },
    [...new Set([...(m.calendar?.invited || []), ...(m.calendar?.attendees || []).map((a) => a.name), ...state.names])]
      .map((n) => h("option", { value: n }))));
  // Unnamed voices of a few seconds are mostly fragments: folded away.
  const brief = m.speakers.filter((s) => !s.is_user && !s.name && !s.shared && s.talk_seconds < 10);
  for (const s of m.speakers) {
    const key = s.label;
    if (brief.includes(s) && !state.showBrief) continue;
    const turns = m.transcript.filter((t) => (s.is_user ? t.label == null : t.label === key));
    const track = h("div", { class: "track", title: "Play from here",
      onclick: (e) => {
        const r = e.currentTarget.getBoundingClientRect();
        seek(((e.clientX - r.left) / r.width) * duration, true);
      } },
      turns.map((t) => h("span", { class: "seg", style: `left:${(100 * t.start) / duration}%;width:${(100 * (t.end - t.start)) / duration}%` })),
      h("span", { class: "playhead", hidden: true }));

    let who;
    let more;
    if (s.shared) {
      // Several people on one microphone (#56): a room with a name, if known, never a person's.
      const name = s.shared === "room" || s.shared === "mic" ? h("input", {
        class: "name-input room-input", value: s.room || "", placeholder: s.is_user ? "Room name (with you)" : "Room name",
        "aria-label": `Room name for ${s.is_user ? "your microphone" : labelDisplay(s.label)}`,
        title: "The room's name, if you know it", spellcheck: "false",
        onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = s.room || ""; e.target.blur(); } },
        onchange: (e) => nameRoom(m.id, s, e.target.value),
      }) : h("span", { class: "you-name" }, s.display);
      who = h("div", { class: "who" }, avatar(s.room || "Room"), name,
        h("span", { class: "named-by", title: "Several people shared one microphone: these lines aren't assigned to people" },
          s.is_user ? "room · with you" : s.shared === "room" ? "room · several people" : "one microphone"),
        h("span", { class: "talk" }, minutes(s.talk_seconds)));
      more = moreButton(() => laneItems(m, s, color, more), `Actions for ${s.display}`);
    } else if (s.is_user) {
      who = h("div", { class: "who" }, avatar(s.name),  // the user's own organization goes without saying
        h("span", { class: "you-name" }, s.name), h("span", { class: "talk" }, minutes(s.talk_seconds)));
      // Several people at my microphone (#56): an in-person meeting around the laptop.
      more = laneCommands(m, s).some(Boolean) ? moreButton(() => laneItems(m, s, color, more), `Actions for ${s.display}`)
        : h("span", { class: "more-gap", "aria-hidden": "true" });
    } else {
      const byVoice = s.named_by === "voice" ? `Recognized by voice (${Math.round((s.recognized?.similarity ?? 0) * 100)}%)` : null;
      const input = h("input", {
        class: `name-input${s.link?.unsure ? " unsure-link" : ""}`, value: s.name || "", placeholder: s.display,
        list: "meeting-names", "aria-label": `Name for ${s.display}`, title: linkTitle(s.link) || byVoice || "Type a name",
        spellcheck: "false",
        onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = s.name || ""; e.target.blur(); } },
        onchange: (e) => nameSpeaker(m.id, s, e.target.value),
      });
      // Hearing the voice is how to tell who it is: its play button stays in sight until the name is sure.
      who = h("div", { class: "who" }, avatar(s.name), input,
        inlinePlay(s) ? playVoiceButton(`Play voice of ${s.display}`, () => playVoice(s), speakerKey(m.id, s)) : null,
        othersOrg(s.org, m) ? h("span", { class: `org${s.org_link?.unsure ? " unsure-link" : ""}`,
          title: linkTitle(s.org_link) || s.org }, s.org) : null,
        byVoice ? h("span", { class: `named-by${s.link?.unsure ? " unsure-link" : ""}`, title: linkTitle(s.link) || byVoice },
          s.link?.unsure ? `by voice · ${Math.round(s.link.confidence * 100)}%` : "by voice") : null,
        h("span", { class: "talk" }, minutes(s.talk_seconds)));
      more = moreButton(() => laneItems(m, s, color, more), `Actions for ${s.display}`);
    }
    // The lane and its rows below: they go, change colour and flash together.
    const group = h("div", { class: "lane-group", style: `--c:${color(key)}`, "data-label": key, "data-you": s.is_user },
      h("div", { class: "lane" }, who, track, more));
    ribbon.append(group);
    if (s.merged?.length) {
      group.append(h("div", { class: "hints merged-row" },
        h("span", { class: "hints-label" }, "Merged in:"),
        s.merged.map((x) => h("button", { class: "by-voice", title: `${x.display} was merged into this speaker. Click to split it off again.`,
          onclick: () => splitOff(m.id, s, x) }, `${x.display} ×`))));
    }
    if (s.named_by === "inferred") {
      // Why the name was inferred, and a yes or no.
      group.append(h("div", { class: "hints inferred-row" },
        h("span", { class: "inferred" }, inferredText(s.inferred)),
        h("span", { class: "inferred-why", title: `${Math.round(s.inferred.confidence * 100)}% sure` }, s.inferred.why),
        h("button", { class: "chip", onclick: () => nameSpeaker(m.id, s, s.name) }, `Yes, ${s.name}`),
        h("button", { type: "button", class: "btn btn-quiet small", onclick: () => nameSpeaker(m.id, s, "") }, "No")));
    }

    const hints = [];
    if (!s.is_user && !s.name && !s.shared) {
      for (const g of s.maybe) hints.push([g.name, `voice ${Math.round(g.similarity * 100)}% alike`]);
      for (const g of s.guesses) hints.push([g.name, `“${g.evidence}”`]);
      // Not a name the user said this voice is not.
      const offered = new Set([...hints.map(([name]) => name), ...(s.rejected || [])]);
      // A big round would bury the lane in chips: the rest are in the name field's list.
      const invited = (m.calendar?.invited || []).filter((name) => !offered.has(name));
      for (const name of invited.slice(0, INVITED_CHIPS)) hints.push([name, "invited"]);
      if (invited.length > INVITED_CHIPS) hints.push([null, `+${invited.length - INVITED_CHIPS} more invited: type a name`]);
    }
    if (hints.length) {
      group.append(h("div", { class: "hints" },
        hints.map(([name, why]) => name == null ? h("span", { class: "hints-label" }, why)
          : h("button", { class: "chip person-chip", title: `Name ${s.display} ${name}`, onclick: () => nameSpeaker(m.id, s, name) },
            personToken(name, personColor(name), { small: true }), " ", h("small", {}, why)))));
    }
  }
  const folded = [];
  if (brief.length) {
    folded.push(h("button", { type: "button", class: "btn btn-quiet small", "aria-expanded": String(!!state.showBrief),
      onclick: () => { state.showBrief = !state.showBrief; renderMeeting(); } },
      state.showBrief ? "Hide brief voices" : `Show ${brief.length} brief ${brief.length === 1 ? "voice" : "voices"} (under 10 s)`));
  }
  for (const r of m.removed || []) {
    folded.push(h("span", { class: "meta" }, `${r.display} removed `,
      h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => restoreSpeaker(m.id, r, e.currentTarget) }, "Restore")));
  }
  if (folded.length) ribbon.append(h("div", { class: "ribbon-foot" }, folded));
  if (meetingCommands(m).split.enabled) addRibbonCut(ribbon, m, duration);
  return ribbon;
}

// Split by hovering the ribbon: over the tracks a cut line follows the
// pointer, snapped to the line where the cut would be; its button opens the cut bar there.
function addRibbonCut(ribbon, m, duration) {
  const button = h("button", { type: "button", class: "ribbon-cut-btn", onclick: () => { if (cut.at != null) openCut(cut.at); } });
  const cut = h("div", { class: "ribbon-cut", hidden: true }, button);
  ribbon.append(cut);
  ribbon.addEventListener("pointermove", (e) => {
    const track = ribbon.querySelector(".track");
    if (!track || e.target.closest?.(".menu")) return;
    const r = track.getBoundingClientRect();
    if (e.clientX < r.left || e.clientX > r.right || e.target.closest?.(".hints, .ribbon-foot")) {
      if (!cut.contains(e.target)) cut.hidden = true;
      return;
    }
    const hit = cutAtPointer((e.clientX - r.left) / r.width, duration, m.transcript);
    if (!hit) return;
    cut.at = hit.at;
    cut.style.left = `${r.left - ribbon.getBoundingClientRect().left + (hit.at / duration) * r.width}px`;
    const text = `Split at ${clock(hit.at)}`;
    if (button.textContent !== text) button.textContent = text;
    cut.hidden = false;
  });
  ribbon.addEventListener("pointerleave", () => { cut.hidden = true; });
  addEventListener("resize", () => { cut.hidden = true; }, { passive: true });  // its place is stale then
}

// The round ▶ beside a name field: plays a few seconds of the voice. While that sample plays it is a
// stop button (#22); `key` says which sample is this button's (speakerKey, clipKey).
function playVoiceButton(label, onPlay, key) {
  const button = h("button", { type: "button", class: "icon-btn voice-play", "data-voice-key": key, "data-label": label,
    onclick: () => (voicePlaying(key) ? stopVoice() : onPlay()) });
  showVoiceButton(button);
  return button;
}

function showVoiceButton(button) {
  const playing = voicePlaying(button.dataset.voiceKey);
  if (button.dataset.playing === String(playing)) return;
  button.dataset.playing = String(playing);
  button.classList.toggle("playing", playing);
  button.title = playing ? "Stop" : "Play voice";
  button.setAttribute("aria-label", playing ? button.dataset.label.replace(/^Play\b/, "Stop") : button.dataset.label);
  button.replaceChildren(h("span", { class: playing ? "mini-stop" : "mini-play" }));
}

// A lane's ⋯: Rename, Play Voice, Merge Into…, Not <Name>, Don't Know Who This Is, and Not a Speaker in red.
function laneItems(m, s, color, from) {
  const run = tracked("lane", {
    rename: () => {
      const group = s.is_user ? document.querySelector("#main .lane-group[data-you]") : laneGroup(s.label);
      const input = group?.querySelector(".name-input");
      input?.focus();
      input?.select();
    },
    playVoice: () => playVoice(s),
    mergeInto: () => menu(m.speakers.filter((o) => !o.is_user && o.label !== s.label).map((o) => ({
      label: o.display, icon: h("span", { class: "swatch", style: `--c:${color(o.label)}` }),
      run: () => mergeSpeakers(m.id, s, o, from),
    })), from),
    notName: () => nameSpeaker(m.id, s, ""),
    unknown: () => markUnknown(m.id, s, !s.unknown, from),
    room: () => markRoom(m.id, s, !s.shared, from),
    notSpeaker: () => removeSpeaker(m.id, s, from),
  });
  return laneCommands(m, s).map((c) => c && { label: c.label, danger: c.danger, disabled: !c.enabled, run: run[c.name] });
}

// --- speaker lanes: changes ----------------------------------------------------

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const onPage = (id) => (state.view === "meetings" || state.view === "review") && state.meeting?.id === id;

// Renders again, keeping focus (and what is typed) in a lane's name field or ⋯ button.
function keepingFocus(render) {
  const a = document.activeElement;
  const label = a?.closest?.(".lane-group")?.dataset.label;
  const kind = a?.classList?.contains("name-input") ? ".name-input" : a?.classList?.contains("more") ? ".more" : null;
  const typed = kind === ".name-input" ? { value: a.value, start: a.selectionStart, end: a.selectionEnd } : null;
  render();
  const el = label && kind ? laneGroup(label)?.querySelector(kind) : null;
  if (!el) return;
  if (typed) el.value = typed.value;
  el.focus({ preventScroll: true });
  if (typed) el.setSelectionRange(typed.start, typed.end);
}

// The server's answer to a speaker change of meeting ``id``, shown while that meeting is.
function showSpeakers(id, m) {
  if (state.meeting?.id === id) {
    state.meeting = m;
    if (onPage(id)) keepingFocus(renderMeeting);
  }
  loadNames();
  loadList();
}

const speakersApi = (id, path, body) => api(`/api/meetings/${encodeURIComponent(id)}/${path}`, body);

// A lane back from an undo or a restore flashes once, in its place.
function flashLane(id, label) {
  const lane = onPage(id) ? laneGroup(label) : null;
  if (!lane) return;
  lane.scrollIntoView({ block: "nearest" });
  flash(lane);
}

async function speakersBack(id, path, body, label) {
  showSpeakers(id, await speakersApi(id, path, body));
  flashLane(id, label);
}

// Undo of a merge, a "Not Tom" or a room (#56): the snapshot from before it (names, earlier merges) comes back.
async function mergeBack(id, token, label) {
  await api("/api/undo", { token });
  showSpeakers(id, await api(`/api/meetings/${encodeURIComponent(id)}`));
  flashLane(id, label);
}

// The name shows at once; the server's answer replaces it, and a failure puts
// the old one back before it throws.
async function saveName(id, label, name) {
  const before = state.meeting?.id === id ? state.meeting : null;
  const shown = before && withName(before, label, name);
  if (shown) state.meeting = shown;
  const saving = speakersApi(id, "speakers", { label, name });
  saving.catch(() => {});  // awaited below, after the render
  // After the change event: focus is where the user tabbed to by now.
  await wait(0);
  if (shown && state.meeting === shown && onPage(id)) keepingFocus(renderMeeting);
  let m;
  try {
    m = await saving;
  } catch (err) {
    if (shown && state.meeting === shown) {
      state.meeting = before;
      if (onPage(id)) keepingFocus(renderMeeting);
    }
    throw err;
  }
  showSpeakers(id, m);
  return m;
}

// Naming from the name field, a chip, Yes/No or Not <Name>; undo sets the previous name.
async function nameSpeaker(id, s, name) {
  const text = namingText(s, name);
  if (text == null) return;
  const previous = s.name || "";
  let m;
  try {
    m = await saveName(id, s.label, name);
  } catch (err) {
    errorToast(`The name was not saved: ${err.message}`, { action: { label: "Try again", run: () => nameSpeaker(id, s, name) } });
    return;
  }
  // "Not Tom": the server keeps what that taught (here and in other meetings), and its way back.
  if (m?.undo) remember(text, () => mergeBack(id, m.undo, s.label));
  // A guess confirmed: it had this name already, there is nothing to set back.
  else if (name.trim() === previous) toast(text);
  else remember(text, () => saveName(id, s.label, previous).then(() => flashLane(id, s.label)));
}

// The merged lane and its lines take the target's colour, then the lane folds away.
async function mergeSpeakers(id, s, o, from, n = laneLines(state.meeting, s.label)) {
  const here = onPage(id);
  const target = here ? colorOf(state.meeting)(o.label) : null;
  const lane = here ? laneGroup(s.label) : null;
  if (here) for (const el of [lane, ...laneTurns(s.label)]) el?.style.setProperty("--c", target);
  let m;
  try {
    [m] = await Promise.all([working(from, speakersApi(id, "merge", { label: s.label, into: o.label })), wait(250)]);
  } catch (err) {
    if (onPage(id)) keepingFocus(renderMeeting);  // the colours go back
    errorToast(`${s.display} was not merged into ${o.display}: ${err.message}`,
      { action: { label: "Try again", run: () => mergeSpeakers(id, s, o, from, n) } });
    return;
  }
  if (lane?.isConnected) await leave(lane);
  showSpeakers(id, m);
  remember(`${s.display} → ${o.display} · ${linesText(n)}`, () => mergeBack(id, m.undo, s.label));
}

// Not a Speaker: noise, a few words. The lane fades and folds away, its lines fade out.
async function removeSpeaker(id, s, from, n = laneLines(state.meeting, s.label)) {
  let m;
  try {
    m = await working(from, speakersApi(id, "remove", { label: s.label, removed: true }));
  } catch (err) {
    errorToast(`${s.display} was not removed: ${err.message}`,
      { action: { label: "Try again", run: () => removeSpeaker(id, s, from, n) } });
    return;
  }
  const lane = onPage(id) ? laneGroup(s.label) : null;
  if (onPage(id)) for (const el of laneTurns(s.label)) el.classList.add("fading");
  if (lane) await leave(lane);
  showSpeakers(id, m);
  remember(`${s.display} removed · ${linesText(n)}`,
    () => speakersBack(id, "remove", { label: s.label, removed: false }, s.label));
}

// Don't Know Who This Is: the lane stays as it is, but the voice is no to-do any more; Ask Me Again takes that back.
async function markUnknown(id, s, on, from) {
  let r;
  try {
    r = await working(from, speakersApi(id, "unknown", { label: s.label, on }));
  } catch (err) {
    errorToast(`Not changed: ${err.message}`, { action: { label: "Try again", run: () => markUnknown(id, s, on, from) } });
    return;
  }
  showSpeakers(id, r);
  remember(unknownText(s.display, on), () => mergeBack(id, r.undo, s.label));
}

// --- voices several people shared (#56) ------------------------------------------

// The quiet line under the title: no warning, nothing to do; for a recurring
// event, the mark can be remembered for its next meetings.
function sharedLine(m) {
  const s = m.shared;
  if (!s?.line) return null;
  const series = s.meeting && s.series?.can ? h("button", { type: "button", class: "btn btn-quiet small",
    onclick: (e) => rememberSeries(m, !s.series.remembered, e.currentTarget) },
  s.series.remembered ? "Forget for this series" : "Remember for this series") : null;
  return h("div", { class: "recorded shared-line" }, s.line, series ? " " : null, series);
}

// Hints that one microphone was shared: offered, never applied.
function renderSharedSuggestion(m) {
  const s = m.shared_suggestion;
  if (!s || m.status !== "ready" || state.view === "review") return null;
  return h("div", { class: "cut-suggest shared-suggest" },
    h("span", {}, `Several people may have shared one microphone here. ${s.why}`),
    h("button", { class: "btn", onclick: (e) => markShared(m, true, e.currentTarget) }, "Speakers can't be separated"),
    h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => dismissSharedSuggestion(m.id, e.currentTarget) },
      "Not this"));
}

// The whole meeting: its voices can't be told apart, or they can after all.
async function markShared(m, on, from) {
  let r;
  try {
    r = await working(from, speakersApi(m.id, "shared", { on }));
  } catch (err) {
    errorToast(`Not changed: ${err.message}`, { action: { label: "Try again", run: () => markShared(m, on, from) } });
    return;
  }
  showSpeakers(m.id, r);
  remember(on ? "Speakers can't be separated in this meeting" : "Speakers can be separated in this meeting again",
    () => mergeBack(m.id, r.undo));
  // Marked because its series is remembered: the next meeting would be marked again, unless the series is forgotten.
  if (!on && r.shared?.series?.remembered) {
    state.sharedAsk = m.id;
    if (onPage(m.id)) renderMeeting();
  }
}

// The small question after unmarking a meeting of a remembered series: forget the series too?
function renderSharedAsk(m) {
  if (state.sharedAsk !== m.id || !m.shared?.series?.remembered || m.shared.meeting) return null;
  const done = () => { state.sharedAsk = null; renderMeeting(); };
  return h("p", { class: "inline-notice shared-ask" },
    `The next meetings of “${titleOf(m)}” still start out with speakers that can't be separated. `,
    h("button", { type: "button", class: "btn", onclick: (e) => { state.sharedAsk = null; rememberSeries(m, false, e.currentTarget); } },
      "Forget for this series"), " ",
    h("button", { type: "button", class: "btn btn-quiet small", onclick: done }, "Keep"));
}

// A lane is a room of several people, or one person after all.
async function markRoom(id, s, on, from, n = laneLines(state.meeting, s.label)) {
  let r;
  try {
    r = await working(from, speakersApi(id, "shared", { label: s.is_user ? "mic" : s.label, on }));
  } catch (err) {
    errorToast(`${s.display} was not changed: ${err.message}`, { action: { label: "Try again", run: () => markRoom(id, s, on, from, n) } });
    return;
  }
  showSpeakers(id, r);
  flashLane(id, s.label);
  remember(roomText(s, on, n), () => mergeBack(id, r.undo, s.label));
}

async function nameRoom(id, s, name) {
  const text = roomNameText(s, name);
  if (text == null) return;
  let r;
  try {
    r = await speakersApi(id, "shared", { label: s.is_user ? "mic" : s.label, on: true, name: name.trim() });
  } catch (err) {
    errorToast(`The room's name was not saved: ${err.message}`, { action: { label: "Try again", run: () => nameRoom(id, s, name) } });
    return;
  }
  showSpeakers(id, r);
  remember(text, () => mergeBack(id, r.undo, s.label));
}

// The next meetings of the event's series start out marked (an All Hands every month), or no longer do.
async function rememberSeries(m, on, from) {
  let r;
  try {
    r = await working(from, speakersApi(m.id, "shared-series", { remember: on }));
  } catch (err) {
    errorToast(`Not changed: ${err.message}`, { action: { label: "Try again", run: () => rememberSeries(m, on, from) } });
    return;
  }
  showSpeakers(m.id, r);
  remember(on ? `The next meetings of “${titleOf(m)}” start out marked` : `The next meetings of “${titleOf(m)}” start out unmarked`,
    () => mergeBack(m.id, r.undo));
}

async function dismissSharedSuggestion(id, button) {
  let m;
  try {
    m = await working(button, speakersApi(id, "shared-suggestion", { dismiss: true }));
  } catch (err) {
    errorToast(`Not saved: ${err.message}`, { action: { label: "Try again", run: () => dismissSharedSuggestion(id, button) } });
    return;
  }
  showSpeakers(id, m);
  remember("Not suggested again for this meeting",
    () => speakersApi(id, "shared-suggestion", { dismiss: false }).then((back) => showSpeakers(id, back)));
}

// "restore" under the ribbon: a removed speaker comes back.
async function restoreSpeaker(id, r, from) {
  try {
    await working(from, speakersBack(id, "remove", { label: r.label, removed: false }, r.label));
  } catch (err) {
    errorToast(`${r.display} was not restored: ${err.message}`, { action: { label: "Try again", run: () => restoreSpeaker(id, r, from) } });
    return;
  }
  remember(`${r.display} restored`, () => speakersApi(id, "remove", { label: r.label, removed: true }).then((m) => showSpeakers(id, m)));
}

// "Merged in: Speaker 4 ×": the merged voice becomes its own lane again.
async function splitOff(id, s, x) {
  try {
    await speakersBack(id, "merge", { label: x.label, into: null }, x.label);
  } catch (err) {
    errorToast(`${x.display} was not split off: ${err.message}`, { action: { label: "Try again", run: () => splitOff(id, s, x) } });
    return;
  }
  remember(`${x.display} split off from ${s.display}`,
    () => speakersBack(id, "merge", { label: x.label, into: s.label }, s.label));
}

function renderNotes(m, color) {
  const n = m.notes;
  const wrap = h("section", { class: "notes" });
  if (m.status === "recording") {
    wrap.append(h("div", { class: "notes-empty" }, "This meeting is still being recorded. Notes are written when it ends."));
    return wrap;
  }
  if (m.status === "processing") {
    wrap.append(h("div", { class: "notes-empty" }, "The recording is being transcribed. Notes follow in a minute or two."));
    return wrap;
  }
  if (m.status === "failed" || m.status === "waiting") {  // the audio is kept: it can be transcribed again
    wrap.append(h("div", { class: "notes-empty" }, h("p", {}, untranscribedText(m)),
      h("div", { class: "actions" },
        h("button", { class: "btn", onclick: (e) => transcribeAgain(m, e.currentTarget) }, "Transcribe Again"),
        m.status === "waiting" ? h("a", { class: "btn btn-quiet", href: "#/settings" }, "Open Settings") : null)));
    return wrap;
  }
  if (state.error) wrap.append(h("p", { class: "notes-empty error" }, state.error));
  if (state.writing.has(m.id)) wrap.append(writingBar(m.id));
  if (!n) {
    wrap.append(h("div", { class: "notes-empty" },
      h("p", {}, "No notes for this meeting yet."),
      m.status === "ready" ? h("button", { class: "btn", disabled: state.writing.has(m.id), onclick: () => writeNotes(m.id) },
        writingText(m.id) ? "Writing notes…" : "Write notes") : null));
    return wrap;
  }
  if (m.notes_stale) {
    wrap.append(h("div", { class: "stale" },
      h("span", {}, m.notes_stale_reason === "my_notes" ? "Your notes changed after these notes were written."
        : m.notes_stale_reason === "shared" ? "Who shared one microphone changed after these notes were written."
          : "The transcript changed after these notes were written."),
      h("button", { class: "btn", disabled: state.writing.has(m.id), onclick: () => writeNotes(m.id) }, writingText(m.id) ? "Writing notes…" : "Rewrite notes")));
  }
  // The meeting's people in their colour wherever the notes name them; a next step's owner as a person token.
  const people = meetingPeople(m);
  const named = (text) => withNames(text, people);
  wrap.append(h("p", { class: "summary" }, named(n.summary)));
  // What was decided and who does what next: up front, before the detail.
  if (n.decisions.length || n.next_steps.length) {
    wrap.append(h("div", { class: "note-cards" },
      n.decisions.length ? h("div", { class: "note-card" }, h("h2", {}, n.decisions.length === 1 ? "Decision" : "Decisions"),
        h("ul", {}, n.decisions.map((d, i) => h("li", { class: "decision" }, named(d),
          (n.decisions_mine || []).includes(i) ? youMark() : null)))) : null,
      n.next_steps.length ? h("div", { class: "note-card todo" }, h("h2", {}, "Next steps"),
        h("ul", {}, n.next_steps.map((s) => {
          const owners = ownerTokens(s.owner, people);
          // The colon is for copying and screen readers; the token says it on screen.
          return h("li", {}, owners.length ? h("span", { class: "owner", title: `For ${s.owner}` },
            owners.flatMap((t, i) => [i ? h("span", { class: "visually-hidden" }, ", ") : null,
              personToken(t.name, t.color, { small: true })]),
            h("span", { class: "visually-hidden" }, ": ")) : null, named(s.task),
          s.mine ? youMark() : null);
        }))) : null));
  }
  for (const s of n.sections) {
    wrap.append(h("h2", {}, s.heading),
      h("ul", {}, s.points.map((p) => h("li", {}, named(p.text), p.mine ? youMark() : null,
        p.details.length ? h("ul", {}, p.details.map((d) => h("li", {}, named(d)))) : null))));
  }
  return wrap;
}

// On what came from the user's own notes (#44).
const youMark = () => h("span", { class: "you-mark", title: "From your notes" }, "you");

function renderTranscript(m, color) {
  const wrap = h("section", { class: "transcript" });
  if (!m.transcript.length) {
    wrap.append(h("div", { class: "notes-empty" }, m.status === "ready" ? "Nobody said anything in this recording."
      : m.live ? "The first minute is being transcribed. Text appears here as the meeting goes on."
      : "The transcript appears when the recording has been transcribed."));
    if (m.live) wrap.append(h("div", { class: "stream-tail" }, ...streamRows(m, color)));
    return wrap;
  }
  let last = null;
  const canCut = m.status === "ready" && !m.live;
  const choosable = canCut && state.view !== "review";  // a line's speaker can be corrected (#12)
  const orgOf = new Map(m.speakers.filter((s) => othersOrg(s.org, m)).map((s) => [s.name || s.display, s.org]));
  const people = meetingPeople(m);
  if (canCut && m.neighbours?.next && state.cutAt == null) {
    wrap.append(h("p", { class: "cut-hint" }, `Did this recording run into “${m.neighbours.next.title || "the next meeting"}”? `,
      "Use Split here on the first line that belongs to it."));
  }
  // While the cut bar is open, the lines on each side of it are a part of their
  // own: the part that goes dims, and leaves when it is discarded.
  const cutting = canCut && m.transcript.some((t) => t.start === state.cutAt);
  let into = wrap;
  if (cutting) {
    into = h("div", { class: "cut-part cut-before" });
    wrap.append(into);
  }
  const pause = (g) => h("p", { class: "gap", role: "note" }, g.text);
  m.transcript.forEach((t, i) => {
    const gaps = gapsBefore(m.gaps, m.transcript, i);
    if (gaps.length) {
      into.append(...gaps.map(pause));
      last = null;  // the speaker is named again after the pause
    }
    const showName = t.speaker !== last;
    last = t.speaker;
    if (cutting && state.cutAt === t.start) {
      into = h("div", { class: "cut-part cut-after" });
      wrap.append(renderCutBar(m, t), into);
    }
    const turn = h("div", { class: `turn${showName ? " new-speaker" : ""}${state.cutAt === t.start ? " cut-here" : ""}`,
      "data-i": i, "data-start": t.start, "data-label": t.label, tabindex: "0", style: `--c:${color(t.label)}`,
      onclick: () => window.getSelection().isCollapsed && seek(t.start, true),
      onpointerenter: () => addLineTools(turn, m, t, i),
      onfocusin: () => addLineTools(turn, m, t, i),
      onmouseup: () => setTimeout(() => showFixable(turn, t)),  // a selection made in the line
      oncontextmenu: (e) => lineMenu(e, turn, m, t, i) },
    h("span", { class: "t" }, clock(t.start)),
    h("span", { class: "bar" }),
    h("div", { class: "said" }, showName ? h("span", choosable ? {
      class: "speaker choosable", role: "button", tabindex: "0", title: "This line is…", "aria-haspopup": "menu",
      onclick: (e) => { e.stopPropagation(); askLineSpeaker(m, t, turn); },
      onkeydown: (e) => {
        if (e.key !== "Enter" && e.key !== " ") return;
        e.preventDefault();
        e.stopPropagation();
        askLineSpeaker(m, t, turn);
      },
    } : { class: "speaker" }, t.speaker,
      orgOf.get(t.speaker) ? h("span", { class: "org" }, ` · ${orgOf.get(t.speaker)}`) : null) : null,
    state.editAt === t.start ? lineEditor(m, t) : lineText(t, people),
    t.edited && state.editAt !== t.start ? h("span", { class: "edited", title: `Heard: “${t.heard}”` }, "edited") : null,
    t.fixed ? h("span", { class: "edited speaker-fixed", title: `Was ${t.fixed.was}` }, "speaker corrected") : null));
    into.append(turn);
  });
  into.append(...gapsBefore(m.gaps, m.transcript, m.transcript.length).map(pause));
  if (m.live) {
    if (!state.stream?.stream) wrap.append(h("p", { class: "notes-empty live-tail" }, "The last minute follows shortly…"));
    wrap.append(h("div", { class: "stream-tail" }, ...streamRows(m, color)));
  }
  return wrap;
}

// The stream's lines after the block text, as transcript rows without a player: settled lines, then the
// others' draft in grey italics. Never the mic's draft: it is the raw mic, which holds the other side's words
// when nobody wears headphones.
function streamRows(m, color) {
  const s = state.stream;
  if (!s?.stream) return [];
  const since = m.live?.until ?? 0;
  const rows = [];
  let last = m.transcript.at(-1)?.speaker ?? null;
  const row = (speaker, tint, time, text, cls) => {
    const showName = speaker !== last;
    last = speaker;
    return h("div", { class: `turn${showName ? " new-speaker" : ""}${cls ? ` ${cls}` : ""}`, style: `--c:${tint}` },
      h("span", { class: "t" }, time),
      h("span", { class: "bar" }),
      h("div", { class: "said" }, showName ? h("span", { class: "speaker" }, speaker) : null, text));
  };
  for (const l of s.lines.filter((l) => l.start >= since)) {
    rows.push(row(l.speaker, l.label ? "var(--ink-3)" : color(null), clock(l.start), lineText(l), l.label ? "others" : ""));
  }
  if (s.draft?.system) rows.push(row("Others", "var(--ink-3)", "", s.draft.system, "draft"));
  return rows;
}

// Replaces only the tail's children: the page, the scroll position and a selection elsewhere stay as they are.
// A selection inside the tail is left alone until it is let go; the next second catches up.
let streamShown = "";
function renderStreamTail() {
  const tail = $("#main .stream-tail");
  const m = state.meeting;
  if (!tail || !m?.live) return;
  const sel = window.getSelection();
  if (!sel.isCollapsed && tail.contains(sel.anchorNode)) return;
  const rows = streamRows(m, colorOf(m));
  const signature = JSON.stringify(rows.map((r) => r.textContent));
  if (signature === streamShown && tail.children.length === rows.length) return;
  streamShown = signature;
  const main = $("#main");
  const following = main.scrollHeight - main.scrollTop - main.clientHeight < 120;
  tail.replaceChildren(...rows);
  if (state.stream?.stream) $("#main .live-tail")?.remove();
  if (following) main.scrollTop = main.scrollHeight;
}

// Once a second while a recording is open: what the stream has beyond the block text. While a stream starts
// (its model loads) it asks every second too; without one (none yet, or one gone stale) every 10 s, so a
// stream started later is still picked up.
const STREAM_RECHECK_MS = 10000;
let streamBusy = false;
let streamAskedAt = 0;
setInterval(async () => {
  const m = state.meeting;
  if (streamBusy || state.view !== "meetings" || state.tab !== "transcript" || !m?.live || m.status !== "recording") return;
  const prev = state.stream;
  if (prev && !prev.stream && !prev.starting && Date.now() - streamAskedAt < STREAM_RECHECK_MS) return;
  streamBusy = true;
  streamAskedAt = Date.now();
  try {
    const s = await api(`/api/meetings/${encodeURIComponent(m.id)}/stream?since=${m.live.until ?? 0}`);
    if (state.meeting?.id !== m.id) return;
    state.stream = s;
    renderStreamTail();
  } catch (err) {
    // the next second tries again
  } finally {
    streamBusy = false;
  }
}, 1000);

// --- the live coach (#41, #42) ----------------------------------------------------
// While a meeting records: who talks now, the talk share and the coach's nudge, as a quiet line under the
// header, and "Best next question" on demand. Updated in place every second (the button keeps its focus);
// nothing pops up over the call.

function coachLive(m) {
  if (!(m.status === "recording" || m.live)) return null;
  const el = h("section", { class: "coach-live", "aria-label": "Live coach" });
  fillCoachLive(el, m);
  return el;
}

function fillCoachLive(el, m) {
  if (!el.firstChild) {
    el.append(
      h("div", { class: "coach-line" },
        h("span", { class: "coach-status" }),
        h("button", { type: "button", class: "btn small coach-ask", onclick: () => askNextQuestion(m.id) }),
        h("span", { class: "coach-reason" })),
      h("div", { class: "coach-answer" }));
  }
  const [line, answer] = el.children;
  const [status, button, reason] = line.children;
  const c = liveCoachFor(state.liveCoach, m);
  status.replaceChildren(...(c ? [
    h("span", { class: `coach-now ${c.talk?.speaking || "quiet"}` }, speakingText(c.talk)),
    c.text ? h("span", { class: "coach-talk" }, c.text) : null,
    c.nudge?.text ? h("span", { class: "coach-nudge", role: "status" }, c.nudge.text) : null,
  ].filter(Boolean) : []));
  const q = state.nextQuestion?.id === m.id ? state.nextQuestion : null;
  const b = questionButton(state.questionInfo?.id === m.id ? state.questionInfo : null, q);
  button.textContent = b.label;
  button.disabled = b.disabled;
  button.title = "1–3 questions to ask next, from the last minutes and your prep";
  reason.textContent = b.reason || "";
  const key = JSON.stringify(q && !q.loading ? q : null);
  if (answer.dataset.key === key) return;
  answer.dataset.key = key;
  answer.replaceChildren(...(q && !q.loading ? renderQuestions(q) : []));
}

function renderQuestions(q) {
  const hide = h("button", { type: "button", class: "btn btn-quiet small", onclick: () => {
    state.nextQuestion = null;
    refreshCoachLive();
  } }, q.confirm ? "Cancel" : "Hide");
  if (q.confirm) {  // the local model during a call: said first, run on a second click
    return [h("p", { class: "coach-warning", role: "status" }, q.confirm, " ",
      h("button", { type: "button", class: "btn small", onclick: () => askNextQuestion(q.id, true) }, "Run anyway"),
      " ", hide)];
  }
  if (q.error) return [h("p", { class: "coach-error", role: "status" }, q.error), hide];
  return [
    q.questions.length ? h("ol", { class: "next-questions" }, q.questions.map((x) => h("li", {},
      h("span", { class: "q" }, x.question), x.why ? h("span", { class: "why" }, x.why) : null))) : null,
    h("p", { class: "next-questions-note" }, questionsNote(q), " ", hide),
  ];
}

function refreshCoachLive() {
  const el = $("#main .coach-live");
  if (el && state.meeting) fillCoachLive(el, state.meeting);
}

async function askNextQuestion(id, confirmed = false) {
  const info = state.questionInfo?.id === id ? state.questionInfo : null;
  if (info?.warning && !confirmed) {
    state.nextQuestion = { id, confirm: info.warning };
    refreshCoachLive();
    return;
  }
  state.nextQuestion = { id, loading: true };
  refreshCoachLive();
  let answer;
  try {
    answer = { id, ...await api(`/api/meetings/${encodeURIComponent(id)}/next-question`, confirmed ? { confirmed: true } : {}) };
  } catch (err) {
    answer = { id, error: err.message };
  }
  if (state.nextQuestion?.id === id) state.nextQuestion = answer;
  refreshCoachLive();
}

// Which model the button runs, asked again every 10 s: the choice can change in Settings.
const QUESTION_INFO_MS = 10000;
let coachAsking = false;
setInterval(async () => {
  const m = state.meeting;
  if (coachAsking || document.hidden || state.view !== "meetings" || !m || !(m.status === "recording" || m.live)) return;
  coachAsking = true;
  try {
    if (state.questionInfo?.id !== m.id || Date.now() - state.questionInfo.at > QUESTION_INFO_MS) {
      const info = await api(`/api/meetings/${encodeURIComponent(m.id)}/next-question`);
      state.questionInfo = { ...info, id: m.id, at: Date.now() };
    }
    state.liveCoach = (await api("/api/recording/coach")).coach;
  } catch {
    return;  // the next second tries again
  } finally {
    coachAsking = false;
  }
  refreshCoachLive();
}, 1000);

// A line's text, marked where the glossary respelled it (what was heard
// shows on hover) and where the transcriber was unsure of a word (dotted:
// on recorded meetings, such words were wrong far more often); the names of
// the meeting's ``people`` in their colour, never in place of those marks.
function lineText(t, people = null) {
  const marks = lineMarks(t, people);
  if (!marks.length) return t.text;
  const out = [];
  let at = 0;
  for (const x of marks) {
    const words = t.text.slice(x.a, x.b);
    out.push(t.text.slice(at, x.a), x.kind === "name" ? nameMark(words, x.color) : x.kind === "glossed"
      ? h("span", { class: "glossed", title: `Glossary: heard “${x.heard}”`, "data-heard": x.heard }, words)
      : h("span", { class: "unsure",
        title: "Palaver wasn't sure about this word. Double-click it, or use Fix spelling on the line." }, words));
    at = x.b;
  }
  out.push(t.text.slice(at));
  return out;
}

// --- transcript lines: toolbar and right-click ---------------------------------

const LINE_ICONS = {
  play: ICONS.play,
  edit: "M4 20h4L19 9l-4-4L4 16zM14 6l4 4",
  speaker: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 20c0-4 4-6 8-6s8 2 8 6",
  fixSpelling: "M3 18l5-12 5 12M5 14h6M14.5 15l2.5 2.5L21.5 12",
  copy: "M9 9h11v11H9zM5 15H4V4h11v1",
  split: ICONS.split,
};

// What the line's buttons and menu items do. ``found``: the words "Fix
// spelling" starts from, when they were picked before the menu opened.
const LINE_ACTIONS = tracked("line", {
  play: (m, t) => seek(t.start, true),
  edit: (m, t) => {
    state.editAt = t.start;
    renderMeeting();
  },
  fixSpelling: (m, t, turn, found = respellTarget(turn, t)) => {
    closeRespell();
    if (found) respellForm(found);
    else toast("Select the words to fix first, then choose Fix spelling.");
  },
  speaker: (m, t, turn) => askLineSpeaker(m, t, turn),
  copy: (m, t) => copyLine(t),
  split: (m, t) => openCut(t.start),
});

// The toolbar at the line's right end, made the first time the pointer or
// focus comes by (hundreds of lines need no buttons until then).
function addLineTools(turn, m, t, i) {
  if (state.editAt === t.start || state.meeting !== m) return;
  if (!turn.querySelector(".line-tools")) {
    turn.append(h("div", { class: "line-tools", role: "toolbar", "aria-label": `Line at ${clock(t.start)}`,
      onclick: (e) => e.stopPropagation() },
    lineCommands(m, i, true, { review: state.view === "review" }).map((c) => h("button", {
      type: "button", class: "line-tool", title: c.label, "aria-label": c.label, "data-name": c.name,
      onmousedown: (e) => e.preventDefault(),  // the selected words stay selected, for Fix spelling
      onclick: (e) => { e.stopPropagation(); LINE_ACTIONS[c.name](m, t, turn); },
    }, icon(LINE_ICONS[c.name])))));
  }
  showFixable(turn, t);
}

// Fix spelling works when words in the line are selected, or the line has
// a marked word; asked again whenever the pointer, focus or a selection comes by.
function showFixable(turn, t) {
  const button = turn.querySelector('.line-tool[data-name="fixSpelling"]');
  if (button) button.disabled = !fixableWord(t) && !respellTarget(turn, t);
}

// Right-click on a line: the toolbar's actions as a menu.
function lineMenu(e, turn, m, t, i) {
  if (e.target.closest(".line-editor") || state.meeting !== m) return;  // the text field keeps its own menu
  e.preventDefault();
  let at = { x: e.clientX, y: e.clientY };
  if (!at.x && !at.y) {  // from the keyboard
    const r = turn.getBoundingClientRect();
    at = { x: r.left + 12, y: r.bottom - 4 };
  }
  const found = respellTarget(turn, t);
  closeRespell();
  menu(lineCommands(m, i, !!found, { review: state.view === "review" }).map((c) => ({
    label: c.label, icon: icon(LINE_ICONS[c.name]), disabled: !c.enabled,
    run: () => LINE_ACTIONS[c.name](m, t, turn, found),
  })), at);
}

// The words selected in this line, else its first unsure or respelled word.
function respellTarget(turn, t) {
  const selected = selectedWords();
  if (selected && turn.contains(selected.box)) return selected;
  const word = fixableWord(t);
  const el = word && turn.querySelector(".said .glossed, .said .unsure");
  return el ? { text: word.text, rect: el.getBoundingClientRect(), heard: el.dataset.heard } : null;
}

function copyText(text) {
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text);
  const box = h("textarea", { style: "position: fixed; opacity: 0" }, text);
  document.body.append(box);
  box.select();
  const ok = document.execCommand("copy");
  box.remove();
  return ok ? Promise.resolve() : Promise.reject(new Error("the clipboard can't be reached"));
}

async function copyLine(t) {
  try {
    await copyText(t.text);
  } catch (err) {
    errorToast(`Not copied: ${err.message}`, { action: { label: "Try again", run: () => copyLine(t) } });
    return;
  }
  toast("Copied", { short: true });
}

// --- transcript lines: who said it (#12) -------------------------------------------

// "This line is…": the meeting's people and Me, by the line's speaker.
function askLineSpeaker(m, t, turn) {
  if (state.meeting !== m || m.status !== "ready" || m.live || state.view === "review" || !turn?.isConnected) return;
  const anchor = turn.querySelector(".said .speaker") || turn.querySelector(".said") || turn;
  turn.classList.add("line-asking");
  menu(lineSpeakerChoices(m, t).map((c) => c && { label: c.label, run: () => setLineSpeaker(m.id, t, c) }), anchor,
    { title: "This line is…", onClose: () => turn.classList.remove("line-asking") });
}

// Saves who said line ``t``, then asks the same about the next line of the
// voice it was heard as, so they can be gone through one after another (Esc stops).
async function setLineSpeaker(id, t, choice) {
  let m;
  try {
    m = await api(`/api/meetings/${encodeURIComponent(id)}/line-speaker`, { start: t.start, track: t.track, to: choice.to });
  } catch (err) {
    errorToast(`The line's speaker was not changed: ${err.message}`,
      { action: { label: "Try again", run: () => setLineSpeaker(id, t, choice) } });
    return;
  }
  const token = m.undo;
  remember(lineSpeakerText(t, choice.to == null ? null : choice.label, t.fixed?.was),
    () => lineSpeakerBack(id, token, t.start));
  if (state.meeting?.id !== id) return;
  state.meeting = m;
  if (!onPage(id)) return;
  renderMeeting();
  const next = choice.to == null ? null : nextLineOfSpeaker(m, t.start, t.label);
  const turn = next && document.querySelector(`#main .turn[data-start="${next.start}"]`);
  if (!turn) {
    focusLine(t.start);
    return;
  }
  turn.scrollIntoView({ block: "nearest" });
  await new Promise((done) => requestAnimationFrame(done));  // its scroll would close the menu
  if (state.meeting === m && turn.isConnected) askLineSpeaker(m, next, turn);
}

async function lineSpeakerBack(id, token, start) {
  await api("/api/undo", { token });
  showLine(id, await api(`/api/meetings/${encodeURIComponent(id)}`), start, true);
}

// --- transcript lines: editing -----------------------------------------------------

// One transcript line rewritten by hand; what was heard stays kept.
function lineEditor(m, t) {
  const error = h("p", { class: "error line-error", role: "alert" });
  error.hidden = true;
  const save = (text, button) => saveLine(m.id, t, text, { button, error });
  const box = h("textarea", { class: "line-input", rows: 2, "aria-label": `The line at ${clock(t.start)}`,
    onkeydown: (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); save(box.value, saveButton); }
      if (e.key === "Escape") closeEditor(t.start);
    },
    oninput: () => { box.style.height = "auto"; box.style.height = `${box.scrollHeight}px`; } }, t.text);
  const saveButton = h("button", { type: "button", class: "btn", onclick: () => save(box.value, saveButton) }, "Save");
  setTimeout(() => {
    box.style.height = `${box.scrollHeight}px`;
    box.focus();
    box.setSelectionRange(box.value.length, box.value.length);
  });
  return h("div", { class: "line-editor", onclick: (e) => e.stopPropagation() }, box, error,
    h("div", { class: "line-actions" },
      saveButton,
      t.edited ? h("button", { type: "button", class: "btn btn-quiet small", title: `“${t.heard}”`,
        onclick: (e) => save(null, e.currentTarget) }, "Back to what was heard") : null,
      h("button", { type: "button", class: "btn btn-quiet small", onclick: () => closeEditor(t.start) }, "Cancel"),
      h("span", { class: "meta" }, "Enter saves · Shift+Enter new line · Esc cancels")));
}

// Saves line ``t`` as ``text`` (null: what was heard). A failure is said
// under the editor, which keeps what was typed; Undo puts the line back.
async function saveLine(id, t, text, { button, error } = {}) {
  const before = lineBefore(t);
  if (text != null && text.trim() === t.text) text = before;  // nothing changed
  if (text === before || button?.disabled) {
    if (text === before && state.editAt === t.start && state.meeting?.id === id) closeEditor(t.start);
    return;
  }
  let m;
  try {
    m = await working(button, api(`/api/meetings/${encodeURIComponent(id)}/line`, { start: t.start, text }));
  } catch (err) {
    if (error?.isConnected) {
      error.textContent = `Not saved: ${err.message}. What you typed is still here.`;
      error.hidden = false;
    } else {
      errorToast(`The line was not saved: ${err.message}`);
    }
    return;
  }
  showLine(id, m, t.start);
  remember(lineEditedText(t), () => api(`/api/meetings/${encodeURIComponent(id)}/line`, { start: t.start, text: before })
    .then((back) => showLine(id, back, t.start, true)));
}

// The meeting after a line changed; the line flashes when an undo put it back.
function showLine(id, m, start, back = false) {
  if (state.meeting?.id !== id) return;
  state.meeting = m;
  if (state.editAt === start) state.editAt = null;
  if (!onPage(id)) return;
  renderMeeting();
  if (!back) focusLine(start);
  const turn = back ? document.querySelector(`#main .turn[data-start="${start}"]`) : null;
  if (turn) {
    turn.scrollIntoView({ block: "nearest" });
    flash(turn);
  }
}

// A manual recording ran on after its call ended (or went silent): ask
// whether to stop it. The menu bar and a notification ask the same.
function renderStopQuestion(m) {
  const q = stopQuestionFor(state.question, m);
  if (!q) return null;
  return h("div", { class: "stop-question", role: "alert" },
    h("span", {}, q.message),
    h("div", { class: "stop-question-actions" },
      h("button", { type: "button", class: "btn primary", onclick: (e) => answerStopQuestion(m.id, "stop", e.currentTarget) },
        "Stop recording"),
      h("button", { type: "button", class: "btn", onclick: (e) => answerStopQuestion(m.id, "keep", e.currentTarget) },
        "Keep recording")));
}

async function loadQuestion() {
  let q, rec;
  try {
    ({ question: q, recording: rec = null } = await api("/api/recording/question"));
  } catch {
    return;  // asked again with the next poll
  }
  if (JSON.stringify([q, rec]) === JSON.stringify([state.question, state.recording])) return;
  state.question = q;
  state.recording = rec;
  if (state.view !== "meetings" || !state.meeting || state.busy) return;
  if (typingMyNotes()) renderLater = true;
  else keepingFocus(renderMeeting);
}

async function answerStopQuestion(id, choice, button) {
  try {
    await working(button, api(`/api/recording/${choice}`, { meeting: id }));
  } catch (err) {
    errorToast(`${choice === "stop" ? "Not stopped" : "Not answered"}: ${err.message}`,
      { action: { label: "Try again", run: () => answerStopQuestion(id, choice, button) } });
    loadQuestion();
    return;
  }
  state.question = null;
  toast(stopAnswerText(choice));
  if (choice === "stop") {
    await loadList();
    if (onPage(id)) openMeeting(id);
  } else if (onPage(id)) keepingFocus(renderMeeting);
}

// The recording seems to run into another meeting: say where, offer the cut.
function renderCutSuggestion(m) {
  const s = m.cut_suggestion;
  if (!s || state.cutAt != null || m.status !== "ready") return null;
  const when = timeFmt.format(new Date(s.event_start));
  return h("div", { class: "cut-suggest" },
    h("span", {}, `This recording seems to run into “${s.event}” (${when}): ${s.why}.`),
    h("button", { class: "btn", onclick: () => openCut(s.at) }, `Cut at ${clock(s.at)}…`),
    h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => dismissCut(m.id, e.currentTarget) }, "Not this"));
}

// Long silence before the first word or after the last (a call joined early,
// a recording left running): offered for removal, the same cut as "Everything before/after it".
function renderSilenceSuggestion(m) {
  const found = m.silence || [];
  if (!found.length || state.cutAt != null || m.status !== "ready") return null;
  const text = found.map((s) => `${minutes(s.seconds)} of silence ${s.edge === "start" ? "before anyone speaks" : "after the last word"}`);
  return h("div", { class: "cut-suggest silence-suggest" },
    h("span", {}, `${text.join(", and ")}.`),
    ...found.map((s) => h("button", { class: "btn", onclick: (e) => cutMeeting(m.id, s.at, { discard: s.edge === "start" ? "before" : "after" },
      e.currentTarget) }, found.length > 1 ? `Remove the ${s.edge === "start" ? "start" : "end"}` : "Remove it")),
    h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => dismissCut(m.id, e.currentTarget, "silence") }, "Keep it"));
}

async function dismissCut(id, button, what = "cut") {
  let m;
  try {
    m = await working(button, api(`/api/meetings/${encodeURIComponent(id)}/cut-suggestion`, { dismiss: true, what }));
  } catch (err) {
    errorToast(`Not saved: ${err.message}`, { action: { label: "Try again", run: () => dismissCut(id, button, what) } });
    return;
  }
  if (state.meeting?.id === id) {
    state.meeting = m;
    if (onPage(id)) renderMeeting();
  }
}

// Where the rest of a meeting goes when it is cut at a line. The lines that
// would go are dimmed: those after the cut, or those before it while the
// "Everything before it" choice is pointed at.
function renderCutBar(m, t) {
  const next = m.neighbours?.next;
  const busy = state.busy;
  const cut = (how) => (e) => cutMeeting(m.id, t.start, how, e.currentTarget);
  const preview = (on) => (e) => e.currentTarget.closest(".transcript")?.classList.toggle("cut-preview-before", on);
  return h("div", { class: "cut-bar" },
    h("div", { class: "cut-row" },
      h("span", {}, `This line (${clock(t.start)}) and everything after it`),
      h("button", { type: "button", class: "btn", disabled: busy, onclick: cut({}) }, "becomes its own meeting"),
      next ? h("button", { type: "button", class: "btn", disabled: busy, onclick: cut({ join_next: true }) },
        `goes to the start of “${next.title || "the next meeting"}”`) : null,
      h("button", { type: "button", class: "btn danger", disabled: busy, onclick: cut({ discard: "after" }) },
        "goes to Trash")),
    h("div", { class: "cut-row" },
      h("span", {}, "Everything before it"),
      h("button", { type: "button", class: "btn danger", disabled: busy, onclick: cut({ discard: "before" }),
        onpointerenter: preview(true), onpointerleave: preview(false), onfocus: preview(true), onblur: preview(false) },
      "goes to Trash"),
      h("span", { class: "spacer" }),
      h("button", { type: "button", class: "btn btn-quiet small", onclick: () => {
        state.cutAt = null;
        renderMeeting();
        focusLine(t.start);
      } }, "Cancel")));
}

const CUT_DONE = {
  own: "The rest is now a meeting of its own.",
  next: "The rest is now the start of the next meeting.",
  after: "Everything from there on is in Trash (Recordings/.trash).",
  before: "Everything before that is in Trash (Recordings/.trash).",
};

// One of the cut bar's four choices. The rest's list item flashes where it
// went; a discarded part leaves the page. Undo puts the meeting back whole.
async function cutMeeting(id, at, how, button) {
  if (pending.has(id)) return;
  pending.add(id);
  const bar = button?.closest(".cut-bar");
  const others = [...(bar?.querySelectorAll("button") || [])].filter((b) => b !== button && !b.disabled);
  for (const b of others) b.disabled = true;
  state.busy = true;
  commands.publish();
  let r;
  try {
    r = await working(button, api(`/api/meetings/${encodeURIComponent(id)}/split`, { at, ...how }));
  } catch (err) {
    for (const b of others) b.disabled = false;
    errorToast(`Not cut: ${err.message}`, { action: { label: "Try again", run: () => cutMeeting(id, at, how, button) } });
    return;
  } finally {
    state.busy = false;
    pending.delete(id);
  }
  const kind = cutKind(r);
  state.cutNotice = { text: CUT_DONE[kind], id: r.rest };
  remember(CUT_DONE[kind], () => cutBack(id, r.undo, r.rest));
  const part = r.discarded && onPage(id) ? document.querySelector(`#main .cut-part.cut-${r.discarded}`) : null;
  if (part) await Promise.all([leave(part), bar?.isConnected ? leave(bar) : null]);
  state.cutAt = null;
  await loadList();
  if (state.view === "review" && state.meeting?.id === id) {
    state.meeting = null;  // load it again, audio too
    await openReview(state.reviewAt);
  } else if (onPage(id)) {
    await openMeeting(id);
    reloadAudio();  // the audio is shorter now
  }
  const rest = r.rest && listItem(r.rest);
  if (rest) {
    rest.scrollIntoView({ block: "nearest" });
    flash(rest);
  }
}

// Undo of a cut: the meeting is whole again (the rest gone, or the next one
// as it was), audio too.
async function cutBack(id, token, rest) {
  await api("/api/undo", { token });
  state.cutNotice = null;
  await loadList();
  const open = state.meeting?.id;
  if (state.view === "review" && open === id) {
    state.meeting = null;
    await openReview(state.reviewAt);
  } else if (state.view === "meetings" && (open === id || (rest && open === rest))) {
    const back = state.meetings.some((x) => x.id === open) ? open : id;
    // The rest that was open is gone: its page becomes the whole meeting's.
    await openMeeting(back, undefined, back === open ? {} : { how: "replace" });
    if (back === open) reloadAudio();
  }
  const item = listItem(id);
  if (item) flash(item);
}

// Writing notes takes tens of seconds: show the time, the usual time, and Cancel.
const NOTES_KEY = "palaver.notesDurations";
function notesDurations() {
  try {
    const x = JSON.parse(localStorage.getItem(NOTES_KEY));
    return Array.isArray(x) ? x : [];
  } catch { return []; }
}
function recordNotesDuration(seconds) {
  try { localStorage.setItem(NOTES_KEY, JSON.stringify([...notesDurations(), seconds].slice(-5))); } catch { /* no storage */ }
}

// "Writing notes · 0:12 · ~40 s" while meeting ``id`` is being written, else null.
function writingText(id) {
  const w = state.writing.get(id);
  if (!w) return null;
  const est = notesEstimate(notesDurations());
  return `Writing notes · ${clock((Date.now() - w.startedAt) / 1000)}${est ? ` · ~${Math.round(est)} s` : ""}`;
}

function writingBar(id) {
  return h("div", { class: "writing", role: "status" },
    h("span", { class: "writing-dot", "aria-hidden": "true" }),
    h("span", { "data-writing": id }, writingText(id)),
    // A run from before the server restarted (#57) is not this page's to cancel.
    state.writing.get(id)?.remote ? null : h("button", { type: "button", class: "btn", onclick: () => cancelWriting(id) }, "Cancel"));
}

function cancelWriting(id) { state.writing.get(id)?.controller?.abort(); }

async function writeNotes(id) {
  if (state.writing.has(id)) return;
  const controller = new AbortController();
  const writing = { id, startedAt: Date.now(), controller };
  state.writing.set(id, writing);
  const tick = setInterval(() => {
    for (const el of document.querySelectorAll(`[data-writing="${id}"]`)) el.textContent = writingText(id) ?? el.textContent;
  }, 1000);
  state.error = null;
  if (state.meeting?.id === id) setTab("notes");
  renderMeeting();
  renderList();
  let written = false;
  try {
    const resp = await fetch(`/api/meetings/${encodeURIComponent(id)}/notes`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", signal: controller.signal });
    const m = await resp.json().catch(() => ({}));
    if (!resp.ok) throw new Error(m.error || `${resp.status}`);
    recordNotesDuration((Date.now() - writing.startedAt) / 1000);
    if (state.meeting?.id === id) state.meeting = m;
    loadList();
    written = true;
  } catch (err) {
    // Cancelled: the server may finish anyway; reopening the meeting shows it.
    if (err.name !== "AbortError") {
      errorToast(`Notes were not written: ${err.message}`, { action: { label: "Try again", run: () => writeNotes(id) } });
    }
  } finally {
    clearInterval(tick);
    if (state.writing.get(id) === writing) state.writing.delete(id);
    renderList();
    if (state.meeting?.id === id) {
      renderMeeting();
      const area = written && $(".notes");
      if (area) flash(area);
    }
  }
}

async function loadNames() {
  state.names = await api("/api/names").catch(() => []);
  let list = $("#names");
  if (!list) document.body.append(list = h("datalist", { id: "names" }));
  list.replaceChildren(...state.names.map((p) => h("option", { value: p })));
}

// --- people ------------------------------------------------------------------

// aria-current="page" on the control of the page shown, none on the others.
function markCurrent(el, on) {
  if (on) el.setAttribute("aria-current", "page");
  else el.removeAttribute("aria-current");
}

// The page shown: its tab in the top bar (review, prep and the coach overview
// are under Meetings), and body[data-page] for the layout (the meeting list
// column is there under Meetings only).
function setView(view) {
  state.view = view;
  markTab(view);
  commands.publish();
}

function markTab(view) {
  const tab = view === "review" ? "meetings" : view;
  for (const b of document.querySelectorAll(".views [data-view]")) markCurrent(b, b.dataset.view === tab);
  markCurrent($("#settings-btn"), view === "settings");
  document.body.dataset.page = tab;
}

// ``focus``: a person to scroll to; ``how``: see historyStep.
async function openPeople(focus = null, how = "push") {
  const here = leaveMeeting("people", hashOf({ view: "people", focus }), how);
  if (focus) keepRecent({ kind: "person", id: focus, label: focus, detail: "Person" });
  try {
    state.directory = await api("/api/people");
    state.error = null;
  } catch (err) {
    state.error = `People could not be loaded: ${err.message}`;
  }
  if (movedOn(here)) return;
  renderPeople();
  if (focus) {
    openPersonMeetings(personSection(focus));
    personSection(focus)?.scrollIntoView({ block: "start" });
  }
}

function meetingTitle(x) {
  return x.title || (x.start ? `Meeting at ${timeFmt.format(new Date(x.start))}` : x.id);
}

// One meeting someone was in: title, day and project, in columns.
function appearance(x, label) {
  return h("li", { class: "appearance appearance-row" },
    x.clip ? h("button", { class: "icon-btn", title: "Hear this voice here", "aria-label": `Hear ${label} in ${meetingTitle(x)}`,
      onclick: () => playClip(x.id, x.clip) }, h("span", { class: "mini-play" })) : h("span", { class: "icon-gap" }),
    h("button", { class: "link appearance-title", title: meetingTitle(x), onclick: () => openMeeting(x.id) }, meetingTitle(x)),
    h("span", { class: "meta", title: x.start ? dayFmt.format(new Date(x.start)) : null },
      x.start ? shortDayFmt.format(new Date(x.start)) : ""),
    h("span", { class: "meta appearance-project" }, (x.projects || []).flatMap((p, i) => [i ? ", " : "",
      h("button", { class: "link", title: `Open ${p.name}`, onclick: () => openProjects(p.id) }, p.name)])));
}

function renderPeople() {
  const d = state.directory;
  const page = h("article", { class: "meeting people" }, h("h1", {}, "People"),
    h("p", { class: "lede" }, "Name a voice once and it is recognized in your other meetings too. Renaming someone here renames them everywhere."));
  if (state.error) page.append(h("p", { class: "error" }, state.error));
  if (!d) {
    $("#main").replaceChildren(page);
    return;
  }

  if (d.unknown.length) {
    page.append(h("h2", {}, "Heard in several meetings, no name yet"));
    const voicesList = h("div", { class: "people-grid" });
    page.append(voicesList);
    d.unknown.forEach((g, i) => {
      const voices = g.voices.map((v) => [v.id, v.label]);
      const clip = g.voices.find((v) => v.clip);
      voicesList.append(personCell({ style: `--c:var(--v${i % 8})`, "data-voice": voices[0].join("|") },
        [avatar(null),
          h("input", { class: "name-input", placeholder: "Who is this?", list: "names", spellcheck: "false",
            "aria-label": "Name for this voice",
            onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); },
            onchange: (e) => e.target.value.trim() && nameVoices(voices, e.target.value) }),
          clip ? playVoiceButton("Play this voice", () => playClip(clip.id, clip.clip), clipKey(clip.id, clip.clip)) : null],
        g.voices, { talk: g.talk_seconds, label: "this voice" }, moreButton(() => voiceItems(g, voices), "Actions for this voice")));
    });
  }

  page.append(h("datalist", { id: "org-names" }, [...new Set([...(d.organizations || []).map((o) => o.name),
    ...d.people.map((p) => p.org).filter(Boolean)])].map((n) => h("option", { value: n }))));
  if (!d.people.length) {
    page.append(h("h2", {}, "Named"),
      h("p", { class: "notes-empty" }, "Nobody has a name yet. Name a speaker in a meeting, or a voice above."));
  }
  // Everyone under their organization, the biggest first; who has none comes last.
  for (const group of peopleByOrg(d)) {
    const o = group.org;
    page.append(h("div", { class: "org-head" },
      // The field as wide as its name: a hidden copy of the text beside it sets the width.
      o ? h("h2", { class: "fits", "data-value": o.name }, h("input", { class: "cell-input org-input", value: o.name, size: 1, spellcheck: "false",
        "aria-label": `Name of ${o.key}`, oninput: (e) => { e.target.parentNode.dataset.value = e.target.value; },
        title: "Rename, e.g. “Fabrikamcontoso” → “Fabrikam Contoso”",
        onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = o.name; e.target.blur(); } },
        onchange: (e) => e.target.value.trim() ? changeOrgs("/api/organizations", { key: o.key, name: e.target.value })
          : (e.target.value = o.name) }))
        : h("h2", {}, group.name || "No organization"),
      h("span", { class: "meta" }, [group.people.length === 1 ? "1 person" : `${group.people.length} people`,
        o ? (o.key === "extern" ? "private addresses" : o.key) : null].filter(Boolean).join(" · "))),
    h("div", { class: "people-grid" }, group.people.map((p) => namedCell(p))));
  }
  $("#main").replaceChildren(page);
}

// The named people in groups by organization: ``org`` the organization from
// the invitees' addresses (renamed here), or null for an organization given by
// hand (``name``) or none (last).
function peopleByOrg(d) {
  const orgs = new Map((d.organizations || []).map((o) => [o.name, o]));
  const groups = new Map();
  for (const p of d.people) {
    const name = p.org || "";
    if (!groups.has(name)) groups.set(name, { name, org: orgs.get(name) || null, people: [] });
    groups.get(name).people.push(p);
  }
  return [...groups.values()].sort((a, b) => (!a.name - !b.name) || (b.people.length - a.people.length)
    || a.name.localeCompare(b.name));
}

// One person or voice on the People page: ``head`` (avatar, name, …) and a
// line that says how often and how long they spoke, and opens their meetings.
function personCell(attrs, head, meetings, { talk, label, badge = null, org = null }, more) {
  const last = meetings.map((x) => x.start).filter(Boolean).sort().at(-1);
  const list = h("ul", { class: "appearances", hidden: true }, meetings.map((x) => appearance(x, label)));
  const toggle = h("button", { class: "link person-meta", "aria-expanded": "false",
    title: "Show the meetings", onclick: () => {
      const open = list.hidden;
      list.hidden = !open;
      toggle.setAttribute("aria-expanded", String(open));
    } },
    [meetings.length === 1 ? "1 meeting" : `${meetings.length} meetings`, minutes(talk),
      last ? shortDayFmt.format(new Date(last)) : null].filter(Boolean).join(" · "));
  return h("section", { class: "person", ...attrs },
    h("div", { class: "person-head" }, ...head, badge, more),
    h("div", { class: "person-sub" }, toggle, org), list);
}

function namedCell(p) {
  // The organization's field shows once asked for (⋯ Change Organization); the group says it otherwise.
  const org = h("input", { class: "cell-input org-input person-org", value: p.org || "", placeholder: "Organization", list: "org-names",
    spellcheck: "false", "aria-label": `Organization of ${p.name}`, hidden: true,
    title: p.org_given ? "Given by hand; empty it to use the email address again" : "From the email address; type to change",
    onkeydown: (e) => { if (e.key === "Enter" || e.key === "Escape") e.target.blur(); },
    onblur: (e) => { if (e.target.value === (p.org || "")) e.target.hidden = true; },
    onchange: (e) => changeOrgs("/api/people/org", { name: p.name, org: e.target.value }) });
  // In their colour, as on the lanes and wherever else they are named.
  return personCell({ style: `--c:${personColor(p.name, p.you ? p.name : null)}`, "data-person": p.name },
    [avatar(p.name),
      h("input", { class: "cell-input name-input", value: p.name, spellcheck: "false", "aria-label": `Rename ${p.name}`,
        title: "Rename everywhere; an existing name merges the two",
        onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = p.name; e.target.blur(); } },
        onchange: (e) => e.target.value.trim() ? renamePerson(p.name, e.target.value) : (e.target.value = p.name) }),
      p.you ? h("span", { class: "pill", title: "One of your names (an earlier one counts too)" }, "You") : null],
    p.meetings, { talk: p.talk_seconds, label: p.name, org,
      // Only the exception is said: a voice it can't recognize yet.
      badge: p.voice_samples || p.you ? null : h("span", { class: "badge", title: "Too little speech yet to learn the voice" },
        "voice not learned") },
    moreButton(() => personItems(p), `Actions for ${p.name}`));
}

// A person's meetings, open (from a link to them).
function openPersonMeetings(section) {
  const toggle = section?.querySelector(".person-meta");
  if (toggle?.getAttribute("aria-expanded") === "false") toggle.click();
}

// Focus (and select) a field of a section on the page, e.g. a name to rename.
function focusField(section, selector) {
  const el = section?.querySelector(selector);
  el?.focus();
  el?.select?.();
}

// A named person's ⋯: Rename and Change Organization go to their fields; Play Voice plays a clip of them.
function personItems(p) {
  const clip = p.meetings.find((x) => x.clip);
  const run = tracked("person", {
    rename: () => focusField(personSection(p.name), ".person-head .name-input"),
    organization: () => {
      const field = personSection(p.name)?.querySelector(".person-org");
      if (field) field.hidden = false;
      focusField(personSection(p.name), ".person-org");
    },
    playVoice: () => playClip(clip.id, clip.clip),
  });
  return personCommands(p).map((c) => c && { label: c.label, danger: c.danger, disabled: !c.enabled, run: run[c.name] });
}

// An unnamed voice's ⋯: Name This Voice goes to its field; Play Voice plays it.
function voiceItems(g, voices) {
  const clip = g.voices.find((v) => v.clip);
  const run = tracked("voice", {
    name: () => focusField(voiceSection(voices), ".person-head .name-input"),
    playVoice: () => playClip(clip.id, clip.clip),
  });
  return voiceCommands(g).map((c) => c && { label: c.label, danger: c.danger, disabled: !c.enabled, run: run[c.name] });
}

// The People page again with ``d``, while it is the page shown.
function showPeople(d) {
  state.directory = d;
  if (state.view === "people") renderPeople();
}

const personSection = (name) => document.querySelector(`#main .person[data-person="${CSS.escape(name)}"]`);
const voiceSection = (voices) => document.querySelector(`#main .person[data-voice="${CSS.escape(voices[0].join("|"))}"]`);

// A call from the People page: the server's answer, or null after a toast
// that says what did not happen, with Try again (``retry``: the same call).
async function peopleCall(path, body, failed, retry) {
  try {
    return await api(path, body);
  } catch (err) {
    errorToast(`${failed}: ${err.message}`, { action: { label: "Try again", run: retry } });
    if (state.view === "people") renderPeople();  // a field shows what is saved again
    return null;
  }
}

async function changeOrgs(path, body) {
  const d = await peopleCall(path, body, "Not saved", () => changeOrgs(path, body));
  if (d) showPeople(d);
}

// Undo of a rename or a naming: the people and voices as they were; ``flashed`` comes back and flashes.
async function peopleBack(token, flashed) {
  await api("/api/undo", { token });
  showPeople(await api("/api/people"));
  loadNames();
  loadList();
  const el = state.view === "people" ? flashed() : null;
  if (el) {
    el.scrollIntoView({ block: "nearest" });
    flash(el);
  }
}

// A voice heard in several meetings gets a name: it leaves the unnamed, and
// the person it now is flashes.
async function nameVoices(voices, name) {
  const d = await peopleCall("/api/voices/name", { voices, name }, "The name was not saved", () => nameVoices(voices, name));
  if (!d) return;
  const who = name.trim();
  const entry = remember(voicesText(voices.length, who), () => peopleBack(d.undo, () => voiceSection(voices)));
  const group = state.view === "people" ? voiceSection(voices) : null;
  if (group) await leave(group);
  if (!undoHistory.has(entry)) return;  // undone while it left: the undo shows the people as they are
  showPeople(d);
  loadNames();
  loadList();
  const person = state.view === "people" ? personSection(who) : null;
  if (person) {
    person.scrollIntoView({ block: "nearest" });
    flash(person);
  }
}

// Renamed everywhere; a name someone has already merges the two.
async function renamePerson(oldName, name) {
  const text = renameText(state.directory || { people: [] }, oldName, name);
  const d = await peopleCall("/api/people/rename", { old: oldName, new: name }, `${oldName} was not renamed`,
    () => renamePerson(oldName, name));
  if (!d) return;
  showPeople(d);
  loadNames();
  loadList();
  if (text) remember(text, () => peopleBack(d.undo, () => personSection(oldName)));
}

// --- projects ------------------------------------------------------------------

// Answers the hash shown, for movedOn.
function leaveMeeting(view, hash, how) {
  const here = arrive(hash, how);
  setView(view);
  state.meeting = null;
  state.prepping = null;
  audio.pause();
  audio.removeAttribute("src");
  $("#player").hidden = true;
  renderList();
  return here;
}

async function openProjects(focus = null, how = "push") {
  const here = leaveMeeting("projects", hashOf({ view: "projects", focus }), how);
  try {
    state.projects = await api("/api/projects");
    state.error = null;
  } catch (err) {
    state.error = `Projects could not be loaded: ${err.message}`;
  }
  const named = focus && (state.projects?.projects || []).find((p) => p.id === focus);
  if (named) keepRecent({ kind: "project", id: focus, label: named.name, detail: "Project" });
  if (movedOn(here)) return;
  renderProjects();
  if (focus) projectSection(focus)?.scrollIntoView({ block: "start" });
}

const projectSection = (pid) => document.getElementById(`project-${pid}`);

// The Projects page again with ``d``, while it is the page shown.
function showProjects(d) {
  state.projects = d;
  if (state.view === "projects") renderProjects();
  loadList();
}

// A call from the Projects page: the server's answer, or null after a toast
// that says what did not happen, with Try again (``retry``: the same call).
async function projectsCall(path, body, failed, retry, from) {
  try {
    return await working(from, api(path, body));
  } catch (err) {
    errorToast(`${failed}: ${err.message}`, { action: { label: "Try again", run: retry } });
    return null;
  }
}

// A change on the Projects page; one with an undo token (a project's name or
// description) is remembered as ``label``, its Undo flashes project ``pid``.
async function changeProjects(path, body, failed, { label, pid } = {}) {
  const d = await projectsCall(path, body, failed, () => changeProjects(path, body, failed, { label, pid }));
  if (d) showProjects(d);
  else if (state.view === "projects") renderProjects();  // a rename that failed shows the old name again
  if (d?.undo && label) remember(label, () => projectsBack(d.undo, pid));
}

// The local model sorts or describes: the page shows it is busy meanwhile.
// Undo puts the projects back as they were before it ran.
async function askModel(path, failed, label, pid) {
  state.asking = true;
  if (state.view === "projects") renderProjects();
  // The label goes along: if the server restarts before the run ends, the next one hands its undo back (#57).
  const d = await projectsCall(path, { label }, failed, () => askModel(path, failed, label, pid));
  state.asking = false;
  if (d) showProjects(d);
  else if (state.view === "projects") renderProjects();
  if (d?.undo) remember(label, () => projectsBack(d.undo, pid));
}

// Undo of a delete or a merge: the projects store as it was; the project is back in its place and flashes.
async function projectsBack(token, pid) {
  await api("/api/undo", { token });
  showProjects(await api("/api/projects"));
  const el = state.view === "projects" ? projectSection(pid) : null;
  if (el) {
    el.scrollIntoView({ block: "nearest" });
    flash(el);
  }
}

// A project's section slides out, the page shows ``d``; focus that was in the
// section goes to ``then``'s ⋯ (else the next project's), never to <body>.
// False when the change (history ``entry``) was undone while it left: the
// undo shows the projects as they are, ``d`` is out of date.
async function projectLeaves(pid, d, then, entry) {
  const section = state.view === "projects" ? projectSection(pid) : null;
  const sections = [...document.querySelectorAll("#main section.project")].map((el) => ({ id: el.id }));
  const next = then ? `project-${then}` : nextAfter(sections, `project-${pid}`)?.id;
  if (section) await leave(section);
  if (!undoHistory.has(entry)) return false;
  showProjects(d);
  const a = document.activeElement;
  if (state.view === "projects" && (!a || a === document.body)) {
    ((next && document.getElementById(next)?.querySelector(".more")) || $("#main")).focus({ preventScroll: true });
  }
  return true;
}

// Delete: no question asked; Undo brings the project back with its meetings.
async function deleteProject(p, from) {
  const d = await projectsCall(`/api/projects/${p.id}/delete`, {}, `“${p.name}” was not deleted`,
    () => deleteProject(p, from), from);
  if (!d) return;
  const entry = remember(`“${p.name}” deleted`, () => projectsBack(d.undo, p.id));
  await projectLeaves(p.id, d, null, entry);
}

// Merge: the project's section goes, the one it went into flashes.
async function mergeProject(p, into, from) {
  const d = await projectsCall(`/api/projects/${p.id}/merge`, { into: into.id }, `“${p.name}” was not merged into ${into.name}`,
    () => mergeProject(p, into, from), from);
  if (!d) return;
  const entry = remember(`Merged into ${into.name}`, () => projectsBack(d.undo, p.id));
  if (!await projectLeaves(p.id, d, into.id, entry)) return;
  const target = state.view === "projects" ? projectSection(into.id) : null;
  if (target) {
    target.scrollIntoView({ block: "nearest" });
    flash(target);
  }
}

// A project's ⋯: Rename, Merge Into… (a second menu of the other projects), and Delete in red.
function projectItems(d, p, from) {
  const run = tracked("project", {
    rename: () => {
      const input = projectSection(p.id)?.querySelector(".name-input");
      input?.focus();
      input?.select();
    },
    mergeInto: () => menu(d.projects.filter((o) => o.id !== p.id).map((o) => ({
      label: o.name, run: () => mergeProject(p, o, from),
    })), from),
    delete: () => deleteProject(p, from),
  });
  return projectCommands(d, p).map((c) => c && { label: c.label, danger: c.danger, disabled: !c.enabled, run: run[c.name] });
}

function projectMeeting(p, x) {
  const sure = x.by === "you";
  const people = x.people || [];
  // A log: the day first, then the title, who was there; × when pointed at.
  return h("li", { class: "appearance project-meeting", "data-meeting": x.id },
    h("span", { class: "meta project-meeting-day", title: x.start ? dayFmt.format(new Date(x.start)) : null },
      x.start ? shortDayFmt.format(new Date(x.start)) : ""),
    h("button", { class: "link appearance-title", title: meetingTitle(x), onclick: () => openMeeting(x.id) }, meetingTitle(x)),
    h("span", { class: "meta project-meeting-by", title: x.why || null },
      sure ? "" : x.by === "model" ? "sorted by the model" : "sorted automatically",
      sure ? null : h("button", { class: "chip-btn", title: "Yes, it belongs here", "aria-label": `Confirm ${meetingTitle(x)}`,
        onclick: (e) => setProjectMeeting(x, p, {}, e.currentTarget) }, "✓")),
    h("span", { class: "faces", title: people.join(", ") || null },
      people.slice(0, 4).map((n) => h("span", { style: `--c:${personColor(n)}` }, avatar(n))),
      people.length > 4 ? h("span", { class: "meta" }, `+${people.length - 4}`) : null),
    h("button", { class: "chip-btn row-tool", title: `Take it out of ${p.name}`, "aria-label": `Remove ${meetingTitle(x)}`,
      onclick: (e) => setProjectMeeting(x, p, { remove: true }, e.currentTarget) }, "×"));
}

// A meeting put in project ``p``, confirmed in it or taken out, from the Projects page.
async function setProjectMeeting(x, p, { remove = false } = {}, from) {
  const title = meetingTitle(x);
  const r = await projectsCall(`/api/meetings/${encodeURIComponent(x.id)}/projects`,
    remove ? { project: p.id, remove: true } : { project: p.id },
    "The project was not changed", () => setProjectMeeting(x, p, { remove }, from), from);
  if (!r) {
    if (state.view === "projects") renderProjects();  // a select shows "Add to…" again
    return;
  }
  showProjects(await api("/api/projects").catch(() => state.projects));
  const text = remove ? `“${title}” removed from ${p.name}`
    : x.by && x.by !== "you" ? `“${title}” confirmed in ${p.name}` : `“${title}” added to ${p.name}`;
  // Undo: the projects as they were; the meeting back in its row flashes.
  remember(text, async () => {
    await api("/api/undo", { token: r.undo });
    showProjects(await api("/api/projects"));
    const row = state.view === "projects"
      ? document.querySelector(`#main li[data-meeting="${CSS.escape(x.id)}"]`) : null;
    if (row) {
      row.scrollIntoView({ block: "nearest" });
      flash(row);
    }
  });
}

function autoGrow(e) {
  e.target.style.height = "auto";
  e.target.style.height = `${e.target.scrollHeight}px`;
}

const PROJECT_PEOPLE = 8;  // on a project's card, then "+N"

function renderProjects() {
  const d = state.projects;
  const modelBusy = state.asking || state.remoteAsking;
  const page = h("article", { class: "meeting people" },
    h("div", { class: "head" },
      h("div", { class: "head-text" }, h("h1", {}, "Projects"),
        h("p", { class: "lede" }, "Meetings are sorted into projects by who was there, the title and what was said. Fix what is wrong: names and descriptions are yours to edit, and a meeting you take out of a project stays out.")),
      h("button", { class: "btn", disabled: modelBusy || !d || !d.unsorted.length,
        title: d && !d.unsorted.length ? "Every meeting is in a project"
          : "Palaver's language model reads the meetings that are in no project yet and puts each into one, on this Mac. Undo takes it back.",
        onclick: () => askModel("/api/projects/suggest", "The meetings were not sorted", "Meetings sorted into projects") },
        modelBusy ? "Sorting…" : "Sort meetings into projects")));
  if (state.error) page.append(h("p", { class: "error" }, state.error));
  if (!d) {
    $("#main").replaceChildren(page);
    return;
  }

  page.append(h("form", { class: "new-project", onsubmit: (e) => {
      e.preventDefault();
      const name = e.target.elements.name.value.trim();
      if (name) changeProjects("/api/projects", { name }, "The project was not created");
    } },
    h("input", { name: "name", class: "name-input", placeholder: "New project…", spellcheck: "false", "aria-label": "New project name" }),
    h("button", { class: "btn", type: "submit" }, "Add")));

  if (d.unsorted.length) {
    page.append(h("h2", {}, "Not in a project yet"));
    page.append(h("ul", { class: "appearances unsorted" }, d.unsorted.map((x) => h("li", { class: "appearance", "data-meeting": x.id },
      h("button", { class: "link", onclick: () => openMeeting(x.id) }, meetingTitle(x)),
      x.start ? h("span", { class: "meta" }, dayFmt.format(new Date(x.start))) : null,
      x.suggestions.map((s) => h("button", { class: "chip", style: "--c:var(--ink-3)", title: `Alike: ${s.why}`,
        onclick: (e) => setProjectMeeting(x, s, {}, e.currentTarget) }, `${s.name}?`)),
      h("select", { class: "filter inline", "aria-label": `Project for ${meetingTitle(x)}`,
        onchange: (e) => {
          const p = d.projects.find((o) => o.id === e.target.value);
          if (p) setProjectMeeting(x, p, {}, e.target);
        } },
        h("option", { value: "" }, "Add to…"), d.projects.map((p) => h("option", { value: p.id }, p.name)))))));
  }

  if (d.projects.length) page.append(h("h2", {}, "Projects"));
  for (const p of d.projects) {
    let more;
    page.append(h("section", { class: "person project", id: `project-${p.id}` },
      h("div", { class: "person-head" },
        h("input", { class: "name-input", value: p.name, spellcheck: "false", "aria-label": `Rename ${p.name}`,
          size: Math.max(4, p.name.length), oninput: (e) => { e.target.size = Math.max(4, e.target.value.length); },
          onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = p.name; e.target.blur(); } },
          onchange: (e) => e.target.value.trim()
            ? changeProjects(`/api/projects/${p.id}`, { name: e.target.value }, `${p.name} was not renamed`,
              { label: projectEditText(p, { name: e.target.value }), pid: p.id })
            : (e.target.value = p.name) }),
        h("span", { class: "meta" }, p.meetings.length === 1 ? "1 meeting" : `${p.meetings.length} meetings`),
        h("span", { class: "spacer" }),
        more = moreButton(() => projectItems(state.projects, p, more), `Actions for ${p.name}`)),
      p.people.length ? h("p", { class: "meta project-people" },
        p.people.slice(0, PROJECT_PEOPLE).map((name) => personToken(name, personColor(name), { small: true })),
        p.people.length > PROJECT_PEOPLE ? h("span", { class: "meta", title: p.people.slice(PROJECT_PEOPLE).join(", ") },
          `+${p.people.length - PROJECT_PEOPLE}`) : null) : null,
      h("div", { class: "description" },
        h("textarea", { class: "description-input", rows: "1", placeholder: "No description yet", spellcheck: "true",
          "aria-label": `Description of ${p.name}`, oninput: autoGrow,
          onchange: (e) => changeProjects(`/api/projects/${p.id}`, { description: e.target.value }, "The description was not saved",
            { label: projectEditText(p, { description: e.target.value }), pid: p.id }) },
          p.description),
        h("div", { class: "description-meta" },
          p.description && p.description_by === "model" ? h("span", { class: "meta" }, "written by the model") : null,
          h("button", { class: "btn btn-quiet small", disabled: modelBusy,
            onclick: () => askModel(`/api/projects/${p.id}/describe`, "The model could not describe it",
              `Description of “${p.name}” written by the model`, p.id) },
            p.description ? "Rewrite with the model" : "Write with the model"))),
      h("ul", { class: "appearances" }, p.meetings.map((x) => projectMeeting(p, x)))));
  }
  if (!d.projects.length) {
    page.append(h("p", { class: "notes-empty" }, "No projects yet. Add one above, or let the model sort your meetings."));
  }
  $("#main").replaceChildren(page);
  for (const t of document.querySelectorAll(".description-input")) autoGrow({ target: t });
}

// --- coach ------------------------------------------------------------------------

const pct = (x) => (x == null ? "–" : `${Math.round(100 * x)} %`);
const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, "0")}`;

// A moment in the meeting: click to hear it.
function at(seconds, label) {
  return h("button", { class: "link moment", title: "Play from here", onclick: () => seek(seconds, true) },
    label ?? clock(seconds));
}

function renderCoach(m) {
  const wrap = h("section", { class: "coach" });
  const c = state.coach;
  if (!c || c.id !== m.id) {
    wrap.append(h("p", { class: "notes-empty" }, "Looking at how you talked…"));
    api(`/api/meetings/${encodeURIComponent(m.id)}/coach`).then((r) => {
      state.coach = { ...r, id: m.id };
      if (state.meeting?.id === m.id && state.tab === "coach") renderMeeting();
    }).catch((err) => { wrap.replaceChildren(h("p", { class: "error" }, `Not available: ${err.message}`)); });
    return wrap;
  }
  const b = c.baseline;
  const usualShare = c.talk.people === 2 ? b.share_1on1 : b.share_group;
  const usualFillers = b.fillers_per_minute?.[c.language];
  const card = (title, ...body) => h("div", { class: "coach-card" }, h("h3", {}, title), ...body);

  if (c.highlights.length) {
    wrap.append(h("ul", { class: "coach-highlights" }, c.highlights.map((x) => h("li", {}, x))));
  } else {
    wrap.append(h("p", { class: "lede" }, "Nothing stands out: this is how you usually talk."));
  }
  const share = c.talk.share ?? 0;
  // Several people on one microphone (#56): how much each talked is unknown, so is the share.
  // A new note for each card: an element shows in one place only.
  const shared = () => h("p", { class: "meta" }, "Left out: several people shared one microphone here.");
  const atMic = () => h("p", { class: "meta" }, "Left out: several people sat at your microphone.");
  wrap.append(h("div", { class: "coach-grid" },
    c.talk.shared ? card("You talked", shared()) : card("You talked",
      h("div", { class: "big-number" }, pct(c.talk.share)),
      h("div", { class: "share-bar", title: `You ${pct(share)}` },
        h("span", { class: "share-me", style: `width:${100 * share}%` }),
        h("span", { class: "share-fair", style: `left:${100 * c.talk.fair}%`, title: `A fair share: ${pct(c.talk.fair)}` })),
      h("p", {}, `You ${pct(c.talk.share)} · fair share ${pct(c.talk.fair)} (${c.talk.people} people)`),
      usualShare != null ? h("p", { class: "meta" }, `Usual for you in ${c.talk.people === 2 ? "1:1s" : "groups"}: ${pct(usualShare)}`) : null),
    c.talk.shared ? card("Monologues", shared()) : card("Monologues",
      c.monologues.length ? h("p", {}, `${c.monologues.length} ${c.monologues.length === 1 ? "stretch" : "stretches"} over 1:30 without anyone else`)
        : h("p", {}, "None over 1:30."),
      c.monologues.length ? h("div", { class: "moments" }, c.monologues.slice(0, 6).map((x) => at(x.start, `${mmss(x.seconds)} at ${clock(x.start)}`))) : null),
    // Several people at my microphone: its words aren't mine alone.
    c.talk.at_mic ? card("Pace", atMic()) : card("Pace",
      h("p", {}, c.pace.wpm ? `${c.pace.wpm} words a minute` : "Too little speech to tell"),
      b.wpm ? h("p", { class: "meta" }, `Usual for you: ${Math.round(b.wpm)}`) : null,
      c.pace.fastest ? h("p", { class: "meta" }, "Fastest: ", at(c.pace.fastest.start, `${c.pace.fastest.wpm} at ${clock(c.pace.fastest.start)}`)) : null),
    c.talk.at_mic ? card("Filler words", atMic()) : card("Filler words",
      c.fillers.top.length ? h("div", { class: "moments" }, c.fillers.top.map((f) => h("span", { class: "word-chip" }, `${f.word} ${f.count}×`))) : h("p", {}, "Hardly any."),
      c.fillers.per_minute != null ? h("p", {}, `${c.fillers.per_minute.toFixed(1)} a minute`
        + (usualFillers ? ` · usual ${usualFillers.toFixed(1)} in ${c.language === "de" ? "German" : "English"}` : "")) : null,
      h("p", { class: "meta" }, `“äh” and the like: ${c.fillers.hesitations}+ — the transcription leaves most of them out.`)),
    card("Questions",
      h("p", {}, `${c.questions.count} asked · ${c.questions.open} open`
        + (c.questions.per_hour != null ? ` · ${Math.round(c.questions.per_hour)} an hour` : "")),
      b.questions_per_hour ? h("p", { class: "meta" }, `Usual: ${Math.round(b.questions_per_hour)} an hour`) : null,
      c.questions.kept_talking ? h("p", { class: "meta" },
        `After ${c.questions.kept_talking} of them you went on talking instead of waiting for an answer.`) : null,
      c.questions.wait != null ? h("p", { class: "meta" }, `When others answered, they started after ${c.questions.wait} s (median).`) : null,
      c.questions.list.length ? h("ul", { class: "coach-questions" }, c.questions.list.slice(0, 5).map((q) =>
        h("li", {}, at(q.start), " ", q.text))) : null),
    card("Interruptions",
      h("p", {}, `You cut in ${c.interruptions.by_me}× · you were cut off ${c.interruptions.of_me}×`),
      c.interruptions.by_me_at.length ? h("div", { class: "moments" },
        c.interruptions.by_me_at.map((x) => at(x.start, `${clock(x.start)} (${x.who})`))) : null),
    c.quiet_invitees.length ? card("Barely heard",
      h("p", { class: "quiet-invitees" }, c.quiet_invitees.map((q) => h("span", {},
        personToken(q.name, q.seconds ? personColor(q.name) : null, { small: true }), ` ${q.seconds} s`))),
      h("p", { class: "meta" }, "Invited, but said little or nothing — or not named in this meeting yet.")) : null));
  wrap.append(h("p", {}, h("button", { class: "link", onclick: () => openCoach() }, "All meetings →")));
  return wrap;
}

async function openCoach(how = "push") {
  const here = leaveMeeting("meetings", "#/coach", how);
  let d;
  try {
    d = await api("/api/coach");
  } catch (err) {
    if (movedOn(here)) return;
    $("#main").replaceChildren(h("p", { class: "error" }, `Not available: ${err.message}`));
    return;
  }
  if (movedOn(here)) return;
  const b = d.baseline;
  const page = h("article", { class: "meeting coach-overview" }, h("h1", {}, "How you talk"),
    h("p", { class: "lede" }, `Across ${b.meetings} meetings: you talk ${pct(b.share_1on1)} in 1:1s and ${pct(b.share_group)} in groups, `
      + `${b.wpm ? Math.round(b.wpm) : "–"} words a minute, `
      + `${b.fillers_per_minute?.de != null ? b.fillers_per_minute.de.toFixed(1) : "–"} filler words a minute in German.`),
    renderTrends(d.trends, b),
    h("h2", {}, "Meetings"),
    h("table", { class: "coach-table" },
      h("thead", {}, h("tr", {}, ["Meeting", "People", "You", "Words/min", "Fillers/min", "Longest", "Questions", "Cut in"]
        .map((x) => h("th", {}, x)))),
      h("tbody", {}, d.meetings.map((r) => h("tr", { onclick: () => { setTab("coach"); openMeeting(r.id); } },
        // The title is the row's button, so the keyboard reaches it too (the row's click does the same).
        h("td", {}, h("button", { type: "button", class: "link item-title",
          onclick: (e) => { e.stopPropagation(); setTab("coach"); openMeeting(r.id); } }, r.title || r.id),
          h("span", { class: "meta" }, r.start ? `${dayFmt.format(new Date(r.start))}, ${timeFmt.format(new Date(r.start))}` : "")),
        h("td", {}, r.people), h("td", {}, pct(r.share)), h("td", {}, r.wpm ?? "–"),
        h("td", {}, r.fillers != null ? r.fillers.toFixed(1) : "–"), h("td", {}, r.longest ? mmss(r.longest) : "–"),
        h("td", {}, r.questions), h("td", {}, r.interruptions))))));
  $("#main").replaceChildren(page);
}

// How the user's talking changed: per week and per kind of meeting (#41). The live coach's nudges compare
// with the same numbers (the last 30 meetings).
function renderTrends(t, b) {
  if (!t?.weeks?.length) return null;
  const weekFmt = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short" });
  const bar = (share, what) => share == null ? "–" : h("span", { class: "trend-share", title: `You talked ${pct(share)} ${what}` },
    h("span", { class: "trend-bar", "aria-hidden": "true" }, h("span", { style: `width:${Math.round(100 * share)}%` })),
    h("span", { class: "trend-value" }, pct(share)));
  const row = (label, r, what) => h("tr", {}, h("td", {}, label), h("td", {}, r.meetings), h("td", {}, bar(r.share, what)),
    h("td", {}, r.wpm ?? "–"), h("td", {}, r.fillers != null ? r.fillers.toFixed(1) : "–"));
  const head = (first) => h("thead", {}, h("tr", {}, [first, "Meetings", "You talked", "Words/min", "Fillers/min"].map((x) => h("th", {}, x))));
  const kinds = { "1:1": "1:1s", group: "Groups" };
  return h("section", { class: "coach-trends", "aria-label": "Over time" },
    h("h2", {}, "Over time"),
    h("table", { class: "coach-table trend-table" }, head("Week of"),
      h("tbody", {}, t.weeks.map((w) => {
        const label = weekFmt.format(new Date(`${w.week}T12:00:00`));
        return row(label, w, `in the week of ${label}`);
      }))),
    t.kinds.length ? h("table", { class: "coach-table trend-table" }, head("Kind"),
      h("tbody", {}, t.kinds.map((k) => row(kinds[k.kind] || k.kind, k, `in ${(kinds[k.kind] || k.kind).toLowerCase()}`)))) : null,
    h("p", { class: "meta" }, `The live coach nudges you only well above your usual: your last ${Math.min(b.meetings, 30)} meetings. `
      + "Filler words count words like “halt” or “basically”; compare weeks in the same language."));
}

// --- glossary --------------------------------------------------------------------

const SUGGESTION_KIND = {
  variant: "Spelled like a known name?",
  cluster: "One word, several spellings?",
  term: "A term worth keeping?",
};

async function openGlossary(how = "push") {
  const here = leaveMeeting("glossary", "#/glossary", how);
  try {
    state.glossary = await api("/api/glossary");
    state.error = null;
  } catch (err) {
    state.error = `The glossary could not be loaded: ${err.message}`;
  }
  if (movedOn(here)) return;
  renderGlossary();
}

function changedText(c) {
  if (!c) return null;
  if (!c.replacements && !c.in_notes) return "Saved. Nothing in your meetings changes.";
  const n = c.meetings.length;
  const notes = c.in_notes ? ` (${c.in_notes} of them in notes)` : "";
  const words = c.replacements + (c.in_notes || 0);
  return `Respelled ${words} ${words === 1 ? "word" : "words"}${notes} in ${n} ${n === 1 ? "meeting" : "meetings"}.`;
}

// A glossary change; ``after`` shows the page again either way. A failure
// says what did not happen, with Try again (``retry``: the same call).
// Answers the server's answer, or null.
async function changeGlossary(path, body, failed, after, { retry, from } = {}) {
  let d;
  try {
    d = await working(from, api(path, body));
  } catch (err) {
    errorToast(`${failed}: ${err.message}`,
      { action: { label: "Try again", run: retry || (() => changeGlossary(path, body, failed, after, { from })) } });
    after();  // a field shows what is saved again
    return null;
  }
  state.glossary = { terms: d.terms, suggestions: d.suggestions };
  state.notice = changedText(d.changed);
  after();
  return d;
}

const glossaryPage = () => { if (state.view === "glossary") renderGlossary(); };
const termRow = (tid) => document.querySelector(`#main .term-row[data-term="${CSS.escape(tid)}"]`);

// Delete: no question asked. The term slides out; Undo brings it back, with
// the spellings it fixed in the meetings.
async function deleteTerm(t, from) {
  const row = state.view === "glossary" ? termRow(t.id) : null;
  const next = row?.nextElementSibling?.dataset.term || row?.previousElementSibling?.dataset.term;
  const d = await changeGlossary(`/api/glossary/${t.id}`, { delete: true }, `“${t.term}” was not deleted`, () => {},
    { from, retry: () => deleteTerm(t, from) });
  if (!d) return;
  const entry = remember(`“${t.term}” deleted from the glossary`, () => termBack(d.undo, t.id));
  if (row?.isConnected && state.view === "glossary") await leave(row);
  if (!undoHistory.has(entry)) return;  // undone while it left: the undo shows the glossary as it is
  glossaryPage();
  const a = document.activeElement;
  if (state.view === "glossary" && (!a || a === document.body)) {
    ((next && termRow(next)?.querySelector(".more")) || $("#main")).focus({ preventScroll: true });
  }
}

// A term renamed, its note, a spelling added or removed; Undo puts the glossary back.
async function changeTerm(t, body, failed) {
  const d = await changeGlossary(`/api/glossary/${t.id}`, body, failed, glossaryPage,
    { retry: () => changeTerm(t, body, failed) });
  if (d?.undo) remember(termChangeText(t, body), () => termBack(d.undo, t.id));
}

// A term's ⋯: Rename and Edit Note go to its fields; Delete in red, last.
function termItems(t, from) {
  const run = tracked("term", {
    rename: () => focusField(termRow(t.id), ".term-input"),
    editNote: () => focusField(termRow(t.id), ".note-input"),
    delete: () => deleteTerm(t, from),
  });
  return termCommands().map((c) => c && { label: c.label, danger: c.danger, disabled: !c.enabled, run: run[c.name] });
}

// A known name's spelling has a key of its own; other suggestions are one key.
const variantKey = (s, v) => `variant:${v.toLowerCase()}:${s.term.toLowerCase()}`;
const suggestionKeys = (s) => (s.kind === "variant" ? s.variants.map((v) => variantKey(s, v)) : [s.key]);

// "Not this": the suggestion goes, each of its spellings; Undo brings it back.
async function dismissSuggestion(s, after, from) {
  const d = await changeGlossary("/api/glossary/reject", { keys: suggestionKeys(s) }, "The suggestion was not dismissed",
    after, { from, retry: () => dismissSuggestion(s, after, from) });
  if (d?.undo) remember(`“${s.term}” is no longer suggested`, () => termBack(d.undo, null));
}

// One spelling is no spelling of the name ("team" is not "Timo"): it goes, the rest stay.
async function dismissVariant(s, v, after, from) {
  const d = await changeGlossary("/api/glossary/reject", { keys: [variantKey(s, v)] }, `“${v}” was not dismissed`,
    after, { from, retry: () => dismissVariant(s, v, after, from) });
  if (d?.undo) remember(`“${v}” is no longer suggested for “${s.term}”`, () => termBack(d.undo, null));
}

// Undo of a glossary change: the glossary as it was; the term (``tid``) is back in its place and flashes.
async function termBack(token, tid) {
  await api("/api/undo", { token });
  state.glossary = await api("/api/glossary");
  state.notice = null;
  if (state.view !== "glossary") return;
  renderGlossary();
  const row = termRow(tid);
  if (row) {
    row.scrollIntoView({ block: "nearest" });
    flash(row);
  }
}

// One suggestion: the spellings found, the spelling to use (editable), where it occurs.
function suggestionCard(s, after) {
  const term = h("input", { class: "name-input term-input", value: s.term, spellcheck: "false",
    "aria-label": "The right spelling" });
  let kept = [...s.variants];
  const variants = s.variants.filter((v) => v !== s.term);
  // A click takes a spelling out: a known name's for good (Undo), another's from what is added.
  const chip = (v) => {
    const b = h("button", { type: "button", class: "variant drop", title: `Not a spelling of “${s.term}”`,
      "aria-label": `“${v}” is not “${s.term}”` }, v, h("span", { class: "x", "aria-hidden": "true" }, "×"));
    b.onclick = (e) => {
      if (s.kind === "variant") return dismissVariant(s, v, after, e.currentTarget);
      kept = kept.filter((k) => k !== v);
      b.remove();
    };
    return b;
  };
  return h("div", { class: "gloss-card" },
    h("div", { class: "gloss-kind" }, SUGGESTION_KIND[s.kind],
      h("span", { class: "meta" }, `${s.count}× in ${s.meetings.length} ${s.meetings.length === 1 ? "meeting" : "meetings"}`
        + (s.unsure ? " · Palaver wasn't sure it heard this" : ""))),
    h("div", { class: "gloss-line" },
      ...variants.map(chip),
      variants.length ? h("span", { class: "arrow" }, "→") : null,
      term),
    s.examples.slice(0, 2).map((e) => h("button", { class: "example", title: "Open the meeting here",
      onclick: () => openMeeting(e.meeting, e.start) },
      h("span", { class: "example-title" }, e.title || e.meeting),
      h("span", { class: "example-text" }, snippet(e.text, [...s.variants, s.term])))),
    h("div", { class: "gloss-actions" },
      h("button", { class: "btn", onclick: (e) => {
        const chosen = term.value.trim() || s.term;
        changeGlossary("/api/glossary/accept", { term: chosen, variants: kept }, `“${chosen}” was not added`, after,
          { from: e.currentTarget });
      } }, "Add to glossary"),
      h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => dismissSuggestion(s, after, e.currentTarget) },
        "Not this")));
}

function renderGlossary() {
  const d = state.glossary;
  const page = h("article", { class: "meeting people glossary" }, h("h1", {}, "Glossary"),
    h("p", { class: "lede" }, "How names and terms are really spelled. Meetings are shown, searched and summarized with these spellings; the original transcript is kept, so nothing is lost."));
  if (state.error) page.append(h("p", { class: "error" }, state.error));
  if (state.notice) page.append(h("p", { class: "inline-notice" }, state.notice));
  if (!d) {
    $("#main").replaceChildren(page);
    return;
  }
  page.append(h("form", { class: "new-project", onsubmit: (e) => {
      e.preventDefault();
      const f = e.target.elements;
      const term = f.term.value.trim();
      if (term) changeGlossary("/api/glossary/accept",
        { term, variants: f.variants.value.split(",").map((v) => v.trim()).filter(Boolean) }, `“${term}” was not added`,
        glossaryPage, { from: e.submitter });
    } },
    h("input", { name: "term", class: "name-input", placeholder: "Term, e.g. Databricks", spellcheck: "false", "aria-label": "New term" }),
    h("input", { name: "variants", class: "name-input", placeholder: "Heard as… (comma separated)", spellcheck: "false", "aria-label": "Misheard spellings" }),
    h("button", { class: "btn", type: "submit" }, "Add")));

  if (d.suggestions.length) {
    page.append(h("h2", {}, "Suggestions"),
      h("div", { class: "gloss-cards" }, d.suggestions.map((s) => suggestionCard(s, glossaryPage))));
  }
  page.append(h("h2", {}, "Terms"));
  if (!d.terms.length) page.append(h("p", { class: "notes-empty" }, "No terms yet. Accept a suggestion, or add one above."));
  else page.append(h("ul", { class: "data-list terms" },
    d.terms.map((t) => {
      let more;
      // Fields read as text until pointed at: the table stays calm, every cell still edits in place.
      return h("li", { class: "data-row term-row", "data-term": t.id },
        h("input", { class: "cell-input term-input", value: t.term, spellcheck: "false", "aria-label": `Rename ${t.term}`,
          onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = t.term; e.target.blur(); } },
          onchange: (e) => e.target.value.trim() ? changeTerm(t, { term: e.target.value }, `${t.term} was not renamed`)
            : (e.target.value = t.term) }),
        // Heard as text, the note below it; × and the empty fields show when the row is pointed at.
        h("div", { class: "term-variants" },
          t.variants.length ? h("span", { class: "heard-as" }, "heard as") : null,
          t.variants.map((v) => h("span", { class: "variant" }, v,
            h("button", { class: "chip-btn", title: `Stop respelling “${v}”`, "aria-label": `Remove ${v}`,
              onclick: () => changeTerm(t, { remove_variant: v }, `“${v}” was not removed`) }, "×"))),
          h("input", { class: "cell-input add-variant", placeholder: "+ heard as", spellcheck: "false", "aria-label": `Add a spelling of ${t.term}`,
            onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); },
            onchange: (e) => e.target.value.trim() && changeTerm(t, { add_variants: [e.target.value.trim()] }, `“${e.target.value.trim()}” was not added`) }),
          h("input", { class: `cell-input note-input${t.note ? " has-note" : ""}`, value: t.note || "", placeholder: "+ note", spellcheck: "true",
            "aria-label": `Note on ${t.term}`, title: t.note || "A note on what it is",
            onkeydown: (e) => { if (e.key === "Enter") e.target.blur(); if (e.key === "Escape") { e.target.value = t.note || ""; e.target.blur(); } },
            onchange: (e) => e.target.value.trim() !== (t.note || "")
              && changeTerm(t, { note: e.target.value.trim() }, `The note on ${t.term} was not saved`) })),
        more = moreButton(() => termItems(t, more), `Actions for ${t.term}`));
    })));
  $("#main").replaceChildren(page);
}

// --- spelling fixed in a meeting ------------------------------------------------

// Select a misheard name in a transcript or in the notes and say how it is
// spelled: it goes into the glossary and is respelled in every meeting.
const RESPELL_MAX_WORDS = 4;
let respellBox = null;

// The words selected in one line of a transcript or in the notes, without
// the punctuation around them; ``box`` is the line's text or the notes.
function selectedWords() {
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
  const range = sel.getRangeAt(0);
  const el = (n) => (n.nodeType === Node.TEXT_NODE ? n.parentElement : n);
  const start = el(range.startContainer), end = el(range.endContainer);
  const box = start?.closest("#main .said, #main .notes");
  if (!box || !box.contains(end) || [start, end].some((e) => e.closest(".speaker, button, input, textarea, .line-editor"))) return null;
  const text = sel.toString().replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, "").replace(/\s+/g, " ");
  if (!text || text.split(" ").length > RESPELL_MAX_WORDS) return null;
  const glossed = start.closest(".glossed");  // a word the glossary respelled: what was heard, to undo that
  return { text, rect: range.getBoundingClientRect(), box,
    heard: glossed && glossed.contains(end) ? glossed.dataset.heard : undefined };
}

function closeRespell() {
  respellBox?.remove();
  respellBox = null;
}

// Below the selection, or above it near the bottom of the window.
function placeRespell(rect) {
  const b = respellBox;
  b.style.left = `${Math.max(8, Math.min(rect.left, innerWidth - b.offsetWidth - 8))}px`;
  b.style.top = `${rect.bottom + 8 + b.offsetHeight > innerHeight ? rect.top - b.offsetHeight - 8 : rect.bottom + 8}px`;
}

const respellPopover = () => h("div", { class: "respell", role: "dialog", "aria-label": "Fix the spelling" });

// A small button by the selection; it opens a field for the right spelling.
// Until it is pressed the selection stays, to be copied as usual.
function offerRespell() {
  closeRespell();
  const found = selectedWords();
  if (!found || !state.meeting) return;
  respellBox = respellPopover();
  respellBox.append(h("button", { class: "respell-offer", onclick: () => respellForm(found) }, "Fix spelling…"));
  document.body.append(respellBox);
  placeRespell(found.rect);
}

// The field for how ``found.text`` is spelled, by those words on the page
// (``found.rect``): from the selection's button or a line's Fix spelling.
function respellForm(found) {
  if (!state.meeting) return;
  const id = state.meeting.id;
  if (!respellBox) {
    respellBox = respellPopover();
    document.body.append(respellBox);
  }
  const input = h("input", { class: "name-input", value: found.text, spellcheck: "false",
    "aria-label": `How “${found.text}” is spelled` });
  const form = h("form", { class: "respell-form", onsubmit: (e) => {
    e.preventDefault();
    const term = input.value.trim();
    closeRespell();
    if (term && term !== found.text) respellEverywhere(id, found.text, term);
  } }, input, h("button", { class: "btn" }, "Fix everywhere"));
  respellBox.replaceChildren(h("span", { class: "respell-label" }, `“${found.text}” is spelled`), form,
    h("p", { class: "meta" }, "Goes into the glossary, so every meeting shows it this way. What was heard is kept."),
    found.heard ? h("div", { class: "respell-undo" },
      h("span", { class: "meta" }, `The glossary made “${found.text}” of “${found.heard}”.`),
      h("button", { type: "button", class: "btn btn-quiet small", onclick: () => {
        closeRespell();
        unrespell(id, found.heard, found.text);
      } }, `Keep “${found.heard}”`)) : null);
  placeRespell(found.rect);
  input.focus();
  input.select();
}

async function respellEverywhere(id, heard, term) {
  let d;
  try {
    d = await api("/api/glossary/respell", { heard, term });
  } catch (err) {
    errorToast(`“${heard}” was not respelled: ${err.message}`,
      { action: { label: "Try again", run: () => respellEverywhere(id, heard, term) } });
    return;
  }
  state.respelled = `“${heard}” is now “${d.term.term}”. ${changedText(d.changed)}`;
  remember(`“${heard}” is now “${d.term.term}” everywhere`, () => respellBack(id, d.undo));
  await showRespelled(id);
}

// A wrong respelling found in a meeting: the glossary stops making ``term``
// of ``heard`` (that mapping only; the term and its other spellings stay).
async function unrespell(id, heard, term) {
  let d;
  try {
    d = await api("/api/glossary/unrespell", { heard });
  } catch (err) {
    errorToast(`“${heard}” still shows as “${term}”: ${err.message}`,
      { action: { label: "Try again", run: () => unrespell(id, heard, term) } });
    return;
  }
  state.respelled = `“${heard}” is no longer “${d.term.term}”. ${changedText(d.changed)}`;
  remember(`“${heard}” is no longer “${d.term.term}”`, () => respellBack(id, d.undo));
  await showRespelled(id);
}

// Undo of Fix everywhere: the glossary as it was, and every meeting with it.
async function respellBack(id, token) {
  await api("/api/undo", { token });
  state.respelled = null;
  await showRespelled(id);
}

async function showRespelled(id) {
  if (state.view === "review") await openReview(state.reviewAt);
  else if (state.view === "meetings" && state.meeting?.id === id) await openMeeting(id);
  else if (state.view === "glossary") await openGlossary();
}

function respelledNotice() {
  return state.respelled ? h("p", { class: "inline-notice" }, state.respelled, " ",
    h("button", { class: "link", onclick: () => { state.respelled = null; openGlossary(); } }, "Open the glossary")) : null;
}

// The selection is final once the mouse is up.
// Not for a right-click or ⌃-click (the line's menu opens), nor a click in a menu or a line's toolbar.
document.addEventListener("mouseup", (e) => {
  if (e.button !== 0 || e.ctrlKey || respellBox?.contains(e.target) || e.target.closest?.(".menu, .line-tools")) return;
  setTimeout(offerRespell);
});
document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeRespell(); });
$("#main").addEventListener("scroll", closeRespell);

// --- prep ------------------------------------------------------------------------

async function openPrep(key, how = "push") {
  const here = arrive(hashOf({ view: "prep", key }), how);
  setView("meetings");
  state.meeting = null;
  audio.pause();
  $("#player").hidden = true;
  try {
    const prepping = await api(`/api/upcoming/${encodeURIComponent(key)}`);
    if (movedOn(here)) return;
    state.prepping = prepping;
    state.error = null;
  } catch (err) {
    if (movedOn(here)) return;
    state.prepping = null;
    $("#main").replaceChildren(h("div", { class: "notice error" }, `This meeting could not be opened: ${err.message}`));
    return;
  }
  renderList();
  renderPrep();
}

async function setPrepProject(change) {
  const key = state.prepping.key;
  try {
    state.prepping = await api(`/api/upcoming/${encodeURIComponent(key)}/projects`, change);
    state.error = null;
  } catch (err) {
    state.error = `The project was not changed: ${err.message}`;
  }
  renderPrep();
  loadList();
}

function renderPrep() {
  const typing = notepadFocus();
  const e = state.prepping;
  const start = new Date(e.start);
  const page = h("article", { class: "meeting prep" },
    h("header", { class: "head" }, h("div", { class: "head-text" },
      h("p", { class: "eyebrow" }, "Coming up"),
      h("h1", {}, e.title || "Meeting"),
      h("div", { class: "when" },
        h("span", {}, `${dayFmt.format(start)}, ${timeFmt.format(start)}–${timeFmt.format(new Date(e.end))}`),
        e.series ? h("span", {}, "recurring") : null),
      e.attendees.length ? h("div", { class: "invitees" }, e.attendees.filter((a) => a.response !== "declined").map((a) =>
        // Someone already known has their colour; the rest a grey outline until they speak.
        personToken(a.name, state.names.some((n) => sameTitle(n, a.name)) ? personColor(a.name) : null,
          { title: a.organizer ? `${a.name} · organized it` : a.name }))) : null)));
  if (state.error) page.append(h("p", { class: "error" }, state.error));
  // Notes before the meeting: they join its recording once it is recorded.
  page.append(notepad(`p:${e.key}`, `/api/upcoming/${encodeURIComponent(e.key)}/my-notes`,
    { timeNow: () => null, seek: null, flat: true }));
  page.append(h("section", { class: "review-step" }, h("h2", {}, "Project"),
    h("p", { class: "lede" }, e.projects.length ? "The recording joins it automatically." : "Pick it now and the recording joins it automatically."),
    h("div", { class: "project-row" },
      e.projects.map((p) => h("span", { class: "project-chip" },
        h("button", { class: "link", onclick: () => openProjects(p.id) }, p.name),
        h("button", { class: "chip-btn", "aria-label": `Remove ${p.name}`,
          onclick: () => setPrepProject({ project: p.id, remove: true }) }, "×"))),
      e.suggestions.map((s) => h("button", { class: "chip", style: "--c:var(--ink-3)", title: `Alike: ${s.why}`,
        onclick: () => setPrepProject({ project: s.id }) }, `${s.name}?`)),
      h("input", { class: "project-input", placeholder: "+ Project", list: "prep-project-names", spellcheck: "false",
        "aria-label": "Add to a project, or name a new one",
        onkeydown: (ev) => { if (ev.key === "Enter") ev.target.blur(); },
        onchange: (ev) => ev.target.value.trim() && setPrepProject({ name: ev.target.value }) }),
      h("datalist", { id: "prep-project-names" }, e.all_projects.map((p) => h("option", { value: p.name }))))));
  page.append(h("section", { class: "review-step" }, h("h2", {}, "Last time"),
    e.context.length ? e.context.map((c) => h("div", { class: "context" },
      h("button", { class: "link context-title", onclick: () => openMeeting(c.id) }, c.title || "Meeting"),
      h("span", { class: "meta" }, ` ${c.start ? dayFmt.format(new Date(c.start)) : ""} · ${c.why}`),
      c.summary ? h("p", { class: "summary" }, c.summary) : h("p", { class: "lede" }, "No notes for it yet."),
      c.next_steps.length ? h("ul", { class: "steps" }, c.next_steps.map((s) =>
        h("li", {}, s.owner ? [h("span", { class: "owner" }, s.owner), ": "] : null, s.task))) : null))
      : h("p", { class: "lede" }, "No earlier meeting with these people.")));
  $("#main").replaceChildren(page);
  restoreNotepadFocus(typing);
}

// --- review ----------------------------------------------------------------------

// The meetings waiting for a review, in order: "Review all in order" on Today goes through them.
async function loadReview() {
  const [review] = await Promise.all([api("/api/review").catch(() => state.review), loadNeeds()]);
  state.review = review;
}

// ``at``: which meeting of the review; Back comes back to the one it left.
async function openReview(at = 0, how = "push") {
  const here = arrive("#/review", how);
  setView("review");
  state.prepping = null;
  await loadReview();
  if (movedOn(here)) return;
  state.reviewAt = Math.min(at, Math.max(0, state.review.length - 1));
  saveHere();  // the entry knows which meeting of the review it shows
  const item = state.review[state.reviewAt];
  if (!item) {
    state.meeting = null;
    $("#player").hidden = true;
    renderList();
    $("#main").replaceChildren(h("article", { class: "meeting" }, h("h1", {}, "Review"),
      h("p", { class: "notes-empty" }, "Nothing waits on you. Finished meetings show up here for a quick check.")));
    return;
  }
  try {
    const m = await api(`/api/meetings/${encodeURIComponent(item.id)}`);
    if (movedOn(here)) return;
    if (state.meeting?.id !== m.id) {
      audio.pause();
      audio.src = m.has_audio ? `/api/meetings/${encodeURIComponent(m.id)}/audio?track=mix` : "";
      $("#player").hidden = !m.has_audio;
      $("#duration").textContent = clock(m.duration);
      $("#scrub").max = m.duration || 1;
    }
    state.meeting = m;
    state.error = null;
  } catch (err) {
    if (movedOn(here)) return;
    state.error = `This meeting could not be opened: ${err.message}`;
  }
  renderList();
  renderReview();
}

async function finishReview(done) {
  const item = state.review[state.reviewAt];
  // A second click while saving would mark the next meeting reviewed too.
  if (!item || state.reviewSaving) return;
  state.notice = null;
  state.cutNotice = null;
  if (!done) return openReview(state.reviewAt + 1 < state.review.length ? state.reviewAt + 1 : 0);
  state.reviewSaving = true;
  renderReview();
  try {
    state.review = await api(`/api/meetings/${encodeURIComponent(item.id)}/reviewed`, { done: true });
    const id = item.id;
    remember(`“${item.title || fallbackTitle(item)}” is marked reviewed.`, () => putBackInReview(id));
  } catch (err) {
    state.error = `Not saved: ${err.message}`;
  } finally {
    state.reviewSaving = false;
  }
  await openReview(state.reviewAt);
}

// Which calendar event a recording was. The one matched by time is wrong
// when an ad-hoc call took another meeting's slot, or two meetings overlap.
// A pop-up: on the page it went unnoticed.
async function openEventPicker(id) {
  let picker;
  try {
    picker = { id, events: await api(`/api/meetings/${encodeURIComponent(id)}/events`) };
  } catch (err) {
    picker = { id, events: [], error: `Calendar events could not be loaded: ${err.message}` };
  }
  state.eventPicker?.close?.();
  const holder = h("div", { class: "event-picker" });
  const d = dialog({ title: "Which calendar event was this recording?", body: [holder], buttons: [{ label: "Cancel" }] });
  d.el.classList.add("event-dialog");
  state.eventPicker = { ...picker, holder, close: d.close };
  renderEventPicker();
  d.result.then(() => { if (state.eventPicker?.holder === holder) state.eventPicker = null; });
}

// ``key``: an event's, null for none of them, "current" to confirm the one it
// has. From the picker, the question on the event chip, or its ✓.
async function chooseEvent(id, key, title = null, button = null) {
  const events = state.eventPicker?.events || [];
  // Picked in the picker: the event it had (no toast when that is picked again); else any answer changes something.
  const before = state.eventPicker ? events.find((e) => e.current)?.key ?? null : undefined;
  title = title ?? (key === null ? "none" : events.find((e) => e.key === key)?.title || "the event");
  let token = null;
  if (button) button.disabled = true;
  try {
    const { undo: t, ...m } = await api(`/api/meetings/${encodeURIComponent(id)}/event`, { key });
    token = t;
    if (state.meeting?.id === id) state.meeting = m;
    state.eventPicker?.close?.();
    state.eventPicker = null;
    await loadList();
  } catch (err) {
    if (button) button.disabled = false;
    if (state.eventPicker) {
      state.eventPicker = { ...state.eventPicker, error: `Not changed: ${err.message}` };
      renderEventPicker();
    } else {
      errorToast(`The event was not changed: ${err.message}`, { action: { label: "Try again", run: () => chooseEvent(id, key, title) } });
      return;
    }
  }
  if (state.meeting?.id === id && onPage(id)) renderMeeting();
  const chip = token && onPage(id) ? document.querySelector("#main .event-link") : null;
  if (chip) flash(chip);
  if (token && before !== key) remember(eventChangeText(key, title), () => eventBack(id, token));
}

// The event the recording is linked to and why ("time match, 2 events
// overlapped"): dotted when Palaver is not sure, with ✓ and Change…; when
// events overlapped the recording about as much, the question which one.
function renderEventLink(m) {
  const v = eventLinkView(m);
  if (!v) return null;
  if (v.kind === "question") {
    return h("div", { class: "event-link asking", role: "group", "aria-label": "Which calendar event was this recording?" },
      h("span", { class: "link-chip unsure", title: `${v.why}. Palaver did not guess: which one was it?` },
        h("span", { class: "link-kind" }, "Event"), "Which one?", h("span", { class: "link-why" }, v.why)),
      v.choices.map((c) => h("button", { type: "button", class: "chip event-choice", style: "--c:var(--v2)", "data-key": c.key,
        title: `${timeFmt.format(new Date(c.start))}–${timeFmt.format(new Date(c.end))}${c.invited ? ` · ${c.invited} invited` : ""}`,
        onclick: (e) => chooseEvent(m.id, c.key, c.title, e.currentTarget) }, c.title)),
      h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => chooseEvent(m.id, null, null, e.currentTarget) },
        "None of these"));
  }
  const link = m.calendar.link;
  return h("div", { class: "event-link" },
    h("span", { class: `link-chip${v.unsure ? " unsure" : ""}`, title: linkTitle(link) },
      h("span", { class: "link-kind" }, "Event"), v.title,
      v.why ? h("span", { class: "link-why" }, v.why) : null,
      v.canConfirm ? h("button", { type: "button", class: "chip-btn", title: `Yes, this was ${v.title}`,
        "aria-label": `Confirm the event ${v.title}`, onclick: (e) => chooseEvent(m.id, "current", v.title, e.currentTarget) }, "✓") : null,
      v.unsure ? h("button", { type: "button", class: "chip-btn", title: "Another event, or none",
        "aria-label": "Change the event", onclick: () => ACTIONS.changeEvent(m) }, "Change…") : null));
}

// Undo of a change of event: the meeting's event, projects and preparation as they were.
async function eventBack(id, token) {
  await api("/api/undo", { token });
  if (state.view === "meetings" && state.meeting?.id === id) await openMeeting(id);
  loadList();
}

// The pop-up's content, again after a change (an error, a rule forgotten).
function renderEventPicker() {
  const p = state.eventPicker;
  if (!p?.holder) return;
  const id = p.id;
  const span = (e) => `${timeFmt.format(new Date(e.start))}–${timeFmt.format(new Date(e.end))}`;
  p.holder.replaceChildren(...[
    p.error ? h("p", { class: "error" }, p.error) : null,
    p.events.length ? null : h("p", { class: "meta" }, "No calendar events around this recording."),
    ...p.events.map((e) => h("button", { type: "button", class: `event-option${e.current ? " current" : ""}`,
      onclick: () => chooseEvent(id, e.key) },
      h("span", { class: "event-time" }, span(e)),
      h("span", { class: "event-title" }, e.title),
      e.invited ? h("span", { class: "meta" }, `${e.invited} invited`) : null,
      e.rejected ? h("span", { class: "meta", title: "Recordings you said were not this event. Said twice, Palaver no longer links it by time." },
        `not it ${e.rejected}×`) : null,
      e.current ? h("span", { class: "meta" }, "✓ now") : null)),
    // Rules the user's corrections made: say them, and a way to drop one.
    ...[...new Map(p.events.filter((e) => e.rule).map((e) => [e.rule.series, e])).values()].map((e) =>
      h("p", { class: "event-rule" }, h("span", {}, e.rule.text),
        h("button", { type: "button", class: "btn btn-quiet small", onclick: (ev) => forgetRule(id, e, ev.currentTarget) },
          "Forget this rule"))),
    h("div", { class: "event-actions" },
      h("button", { type: "button", class: "btn", onclick: () => chooseEvent(id, null) }, "None of these (an ad-hoc call)")),
    h("p", { class: "meta" }, "The notes keep the old event until you rewrite them."),
  ].filter(Boolean));  // replaceChildren, unlike h(), would show a null
}

// "Not linked by time any more": forgotten, so the series is linked by time again.
async function forgetRule(id, e, button) {
  button.disabled = true;
  let token;
  try {
    ({ undo: token } = await api("/api/rules/forget", { series: e.rule.series }));
  } catch (err) {
    button.disabled = false;
    errorToast(`The rule was not forgotten: ${err.message}`, { action: { label: "Try again", run: () => forgetRule(id, e, button) } });
    return;
  }
  await refreshPicker(id);
  remember(`“${e.title}” is linked by time again`, async () => {
    await api("/api/undo", { token });
    await refreshPicker(id);
  });
}

// The picker again, with what the server says now (its rules), if it is still open.
async function refreshPicker(id) {
  if (state.eventPicker?.id !== id) return;
  state.eventPicker = { ...state.eventPicker, events: await api(`/api/meetings/${encodeURIComponent(id)}/events`), error: null };
  renderEventPicker();
}

// Put a meeting back in the review, and open it there.
async function putBackInReview(id) {
  const queue = await api(`/api/meetings/${encodeURIComponent(id)}/reviewed`, { done: false });
  await openReview(Math.max(0, queue.findIndex((x) => x.id === id)));
}

// Keep a meeting on this Mac (no cloud model gets it), or allow it again.
async function toggleLocalOnly(m, from) {
  const on = !m.local_only;
  try {
    const updated = await working(from, api(`/api/meetings/${encodeURIComponent(m.id)}/local-only`, { on }));
    if (state.meeting?.id === m.id) {
      state.meeting = updated;
      renderMeeting();
    }
  } catch (err) {
    errorToast(`Not changed: ${err.message}`);
    return;
  }
  toast(on ? "Kept on this Mac: it is transcribed here, no cloud model gets it, and Claude can't read it through MCP."
    : "Cloud models chosen in Settings, and Claude through MCP, may get this meeting again.", { short: true });
}

// Transcribe Again: the menu bar app transcribes the meeting next; the page shows it transcribing.
async function transcribeAgain(m, from) {
  try {
    const updated = await working(from, api(`/api/meetings/${encodeURIComponent(m.id)}/transcribe`, {}));
    if (state.meeting?.id === m.id) {
      state.meeting = updated;
      renderMeeting();
    }
  } catch (err) {
    errorToast(`Not transcribed: ${err.message}`, { action: { label: "Try again", run: () => transcribeAgain(m, from) } });
    return;
  }
  toast(`Transcribing “${titleOf(m)}”. Notes follow once it is done.`, { short: true });
  loadList();  // its state in the list too
}

// #9: asked first; the audio can't come back.
async function deleteAudio(m, from) {
  const answer = await dialog({
    title: "Delete this meeting's audio?",
    body: [h("p", { class: "meta" }, `“${titleOf(m)}” keeps its transcript, notes and speakers. Without the audio it `,
      "can't be played, exported with its audio or transcribed again. This can't be undone.")],
    buttons: [{ label: "Cancel" }, { label: "Delete Audio", value: "delete" }],
  }).result;
  if (answer !== "delete") return;
  let updated;
  try {
    updated = await working(from, api(`/api/meetings/${encodeURIComponent(m.id)}/delete-audio`, {}));
  } catch (err) {
    errorToast(`Audio not deleted: ${err.message}`);
    return;
  }
  if (state.meeting?.id === m.id) {
    audio.pause();
    audio.removeAttribute("src");
    $("#player").hidden = true;
    state.meeting = updated;
    renderMeeting();
  }
  toast(`Audio deleted: ${sizeText(updated.freed)} free again.`, { short: true });
}

async function reviewAgain(m) {
  try {
    await putBackInReview(m.id);
  } catch (err) {
    errorToast(`Not put back in the review: ${err.message}`, { action: { label: "Try again", run: () => reviewAgain(m) } });
    return;
  }
  remember(`“${titleOf(m)}” is back in the review`, () => markReviewed(m.id));
}

// Undo of Review Again: reviewed again, and back on the meeting.
async function markReviewed(id) {
  await api(`/api/meetings/${encodeURIComponent(id)}/reviewed`, { done: true });
  await loadReview();
  if (state.view === "review" || state.meeting?.id === id) await openMeeting(id, undefined, { how: "replace" });
}

function renderReview() {
  const item = state.review[state.reviewAt];
  const m = state.meeting;
  if (!item || !m || m.id !== item.id) return;
  const start = m.start ? new Date(m.start) : null;
  const cutNotice = state.cutNotice ? h("p", { class: "inline-notice" }, state.cutNotice.text) : null;
  const glossary = (item.open.glossary || []);
  const after = () => { if (state.view === "review") openReview(state.reviewAt); };
  const step = (title, done, ...body) => h("section", { class: `review-step${done ? " done" : ""}` },
    h("h2", {}, h("span", { class: "tick" }, done ? "✓" : "•"), title), ...body);

  const page = h("article", { class: "meeting review" },
    h("div", { class: "review-bar" },
      h("span", { class: "meta" }, `Review · ${state.reviewAt + 1} of ${state.review.length}`),
      h("span", { class: "spacer" }),
      h("button", { type: "button", class: "btn btn-quiet", disabled: state.reviewSaving, onclick: () => finishReview(false) }, "Skip"),
      h("button", { class: "btn primary", disabled: state.reviewSaving, onclick: () => finishReview(true) },
        state.reviewSaving ? "Saving…" : "Done, next →")),
    cutNotice,
    respelledNotice(),
    renderCutSuggestion(m),
    renderSilenceSuggestion(m),
    h("header", { class: "head" }, h("div", { class: "head-text" },
      h("h1", {}, h("button", { class: "link", title: "Open the meeting", onclick: () => openMeeting(m.id) },
        titleOf(m))),
      h("div", { class: "when" },
        start ? h("span", {}, `${dayFmt.format(start)}, ${timeFmt.format(start)}`) : null,
        m.duration ? h("span", {}, minutes(m.duration)) : null))));
  if (state.error) page.append(h("p", { class: "error" }, state.error));
  if (state.notice) page.append(h("p", { class: "inline-notice" }, state.notice));

  const sure = m.projects.length && m.projects.every((p) => p.by === "you");
  page.append(step("Project", sure,
    h("p", { class: "lede" }, m.projects.length ? (sure ? "Confirmed." : "Sorted automatically — confirm with ✓ or fix it.")
      : "In no project yet."), renderMeetingProjects(m)));

  const unnamed = m.speakers.filter((s) => !s.is_user && !s.name && !s.shared && !s.unknown && s.talk_seconds >= 10).length;
  const guessed = m.speakers.filter((s) => s.named_by === "inferred").length;
  page.append(step("Speakers", !unnamed && !guessed,
    h("p", { class: "lede" }, [
      unnamed ? `${unnamed} without a name. Play a voice with ▶, type a name or pick a suggestion.` : null,
      guessed ? `${guessed} named by inference — confirm with “Yes” or reject with “No”.` : null,
    ].filter(Boolean).join(" ") || "Everyone has a name."),
    renderRibbon(m, colorOf(m))));

  page.append(step("Glossary", !glossary.length,
    glossary.length ? h("div", { class: "gloss-cards" }, glossary.map((s) => suggestionCard(s, after)))
      : h("p", { class: "lede" }, "Nothing new to spell here.")));

  page.append(h("section", { class: "review-step" }, h("h2", {}, "Transcript"),
    h("p", { class: "lede" }, "Something in here that doesn’t belong? Split here, in a line’s toolbar, cuts the meeting there."),
    h("div", { class: "review-transcript" }, renderTranscript(m, colorOf(m)))));

  page.append(step("Notes", m.notes && !m.notes_stale,
    m.notes ? h("p", { class: "summary" }, m.notes.summary) : h("p", { class: "lede" }, "No notes yet."),
    !m.notes || m.notes_stale ? h("button", { class: "btn", disabled: state.writing.has(m.id), onclick: () => writeNotes(m.id) },
      writingText(m.id) ? "Writing notes…" : m.notes ? "Rewrite notes" : "Write notes") : null));
  $("#main").replaceChildren(page);
  updatePlayhead();
}

for (const b of document.querySelectorAll(".views [data-view]")) b.addEventListener("click", () => goTo(b.dataset.view));

// The Meetings tab goes back to the meeting open last, else to the newest.
function lastMeeting() {
  const known = state.meetings.some((m) => m.id === state.lastMeeting);
  return known ? state.lastMeeting : state.meetings[0]?.id;
}

// --- playback --------------------------------------------------------------

function seek(t, andPlay) {
  if (!audio.src) return;
  voice.pause();
  audio.currentTime = t;
  if (andPlay) play(audio);
  updatePlayhead();
}

// Play/Pause of the meeting: the button, Space, the native menu.
function playPause() {
  if (audio.paused) { voice.pause(); play(audio); }
  else audio.pause();
}

// The voice sample playing (or last played): its key, so its button shows Stop also after a re-render.
let voiceKey = null;
const speakerKey = (meetingId, s) => `speaker:${meetingId}:${s.label}`;
const clipKey = (meetingId, clip) => `clip:${meetingId}:${clip.start}`;
const voicePlaying = (key) => key != null && key === voiceKey && !voice.paused;

let clipIndex = new Map();
function playVoice(s) {
  const i = clipIndex.get(s.label) || 0;
  clipIndex.set(s.label, i + 1);
  playClip(state.meeting.id, s.clips[i % s.clips.length], speakerKey(state.meeting.id, s));
}

// Starting a sample ends the one playing (one element plays them all).
function playClip(meetingId, clip, key = clipKey(meetingId, clip)) {
  audio.pause();
  const src = `/api/meetings/${encodeURIComponent(meetingId)}/audio?track=system`;
  if (!voice.src.endsWith(src)) voice.src = src;
  voiceKey = key;
  voice.currentTime = clip.start;
  voice.dataset.until = clip.end;
  play(voice);
  showVoiceButtons();
}

function stopVoice() {
  voice.pause();
  showVoiceButtons();
}

function showVoiceButtons() {
  document.querySelectorAll(".voice-play").forEach(showVoiceButton);
}
voice.addEventListener("timeupdate", () => {
  if (voice.currentTime >= Number(voice.dataset.until)) voice.pause();
});
for (const type of ["play", "pause", "ended", "emptied"]) voice.addEventListener(type, showVoiceButtons);
// Escape stops a sample (whatever else Escape does there goes on).
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !voice.paused) stopVoice(); });

function speakingAt(t) {
  const m = state.meeting;
  if (!m) return -1;
  let found = -1;
  m.transcript.forEach((u, i) => { if (u.start <= t && t < u.end + 0.3) found = i; });
  return found;
}

let lastPlaying = -1;
function updatePlayhead() {
  const m = state.meeting;
  if (!m) return;
  const t = audio.currentTime || 0;
  const duration = m.duration || 1;
  for (const ph of document.querySelectorAll(".playhead")) {
    ph.hidden = t === 0 && audio.paused;
    ph.style.left = `${(100 * t) / duration}%`;
  }
  $("#clock").textContent = clock(t);
  if (document.activeElement !== $("#scrub")) $("#scrub").value = t;
  $("#play").classList.toggle("on", !audio.paused);
  $("#play").setAttribute("aria-label", audio.paused ? "Play" : "Pause");
  const playing = document.querySelector("#main .tbtn-play");
  if (playing) showPlaying(playing);

  const i = speakingAt(t);
  const now = $("#now-speaking");
  if (i >= 0) {
    now.textContent = m.transcript[i].speaker;
    now.style.setProperty("--c", colorOf(m)(m.transcript[i].label));
  } else {
    now.textContent = "";
  }
  if (i !== lastPlaying) {
    document.querySelector(".turn.playing")?.classList.remove("playing");
    const row = document.querySelector(`.turn[data-i="${i}"]`);
    if (row) {
      row.classList.add("playing");
      if (!audio.paused) row.scrollIntoView({ block: "nearest" });
    }
    lastPlaying = i;
  }
}

audio.addEventListener("timeupdate", updatePlayhead);
audio.addEventListener("play", updatePlayhead);
audio.addEventListener("pause", updatePlayhead);
$("#play").addEventListener("click", () => playPause());
$("#scrub").addEventListener("input", (e) => { audio.currentTime = Number(e.target.value); });

// ⌘Z undoes the last change (or the typing, in a text field).
commands.bindKeys();

document.addEventListener("keydown", (e) => {
  // Space belongs to a field, or presses the focused button or menu item.
  const focus = document.activeElement;
  const typing = isEditable(focus) || !!focus?.closest?.("input, button, [role=menuitem]");
  if (e.key === " " && !typing && audio.src) {
    e.preventDefault();
    playPause();
  }
  if ((e.metaKey || e.ctrlKey) && e.key === "f") {
    e.preventDefault();
    // The search is in the meeting list, which is beside the Meetings pages only.
    if (document.body.dataset.page !== "meetings" && lastMeeting()) openMeeting(lastMeeting());
    $("#search").focus();
  }
});

// --- settings --------------------------------------------------------------------

async function openSettings(how = "push", pane = null) {
  const before = state.view;
  if (pane) state.settingsPane = settingsPane(pane);
  const shown = settingsPane(state.settingsPane);
  const here = leaveMeeting("settings", `#/settings/${shown}`, how);
  if (before === "settings" && state.settings) {  // another pane: what was loaded stays
    renderSettings();
    $("#main .settings-pane")?.scrollIntoView?.({ block: "start" });
    return;
  }
  try {
    let rec;
    [state.settings, state.lm, state.tr, , , , , rec, state.update, state.calendar] = await Promise.all([api("/api/settings"),
      api("/api/language-model"), api("/api/transcription"), refreshMcp(), refreshMemory(), refreshStorage(),
      refreshNotifications(),
      // "Recommended for this Mac" (#55): the setup assistant's recommendations; the page works without them.
      api("/api/setup/recommendations").catch(() => null),
      api("/api/update").catch(() => null), api("/api/setup/calendar").catch(() => null)]);
    state.recommended = rec?.recommendations || null;
    showUpdateIndicator();
    state.error = state.lmError = state.trError = null;
  } catch (err) {
    state.error = `Settings could not be loaded: ${err.message}`;
  }
  if (movedOn(here)) return;
  renderSettings();
  watchCalendar();
}

// The calendar on the Settings page (it was in the menu bar's menu): connected,
// or a button that asks macOS, or opens System Settings once refused. Until it
// is connected the page looks every 1.5 s, so a "yes" anywhere shows here.
function calendarCard() {
  const cal = state.calendar;
  const t = permissionText(cal);
  return h("div", { class: "gloss-card settings-card", id: "calendar-card" },
    h("div", { class: "lm-row" },
      h("span", {}, h("strong", {}, "Calendar"), " ", h("span", { class: `setup-check-detail calendar-${t.status}` }, t.text), h("br"),
        h("span", { class: "meta" }, "Each meeting's title and invitees come from the macOS calendar, on this Mac. Palaver never changes anything in it."),
        // #10: Microsoft 365 comes in through macOS, not a sign-in of Palaver's own.
        h("br"), h("span", { class: "meta" }, "Microsoft 365, Exchange or Google: add the account in System Settings → Internet Accounts ",
          "with Calendars on. If your organization blocks that, its admin approves it once.")),
      cal && cal.state !== "granted" ? h("button", { type: "button", class: "btn", onclick: (e) => connectCalendarHere(e.currentTarget) },
        cal.state === "denied" ? "Open System Settings" : "Connect Calendar") : null));
}

// Whether macOS lets Palaver notify, as its launcher last asked: off, Palaver
// can't ask whether to stop a recording or say an update is ready.
async function refreshNotifications() {
  try {
    state.notifications = await api("/api/notifications");
  } catch {
    return;
  }
  document.getElementById("notifications-section")?.replaceWith(notificationsSection());
}

function notificationsSection() {
  const n = state.notifications;
  const section = h("section", { id: "notifications-section" });
  if (!n || n.state === "unknown") {  // outside the app nobody knows
    section.append(h("h2", {}, "Notifications"), h("div", { class: "gloss-card settings-card" },
      h("p", { class: "meta" }, "Shown in the Palaver app: run from a terminal, Palaver can't ask macOS.")));
    return section;
  }
  const on = n.state === "granted";
  section.append(h("h2", {}, "Notifications"), h("div", { class: "gloss-card settings-card" },
    h("div", { class: "lm-row" },
      h("span", {}, h("strong", {}, on ? "On" : "Off"), h("br"),
        h("span", { class: "meta" }, on
          ? "Palaver says when a meeting is recorded, asks before a recording that ran on is stopped, and tells of updates."
          : "Palaver can't ask whether to stop a recording that ran on, or say that an update is ready. Those questions also show in the menu bar menu.")),
      on ? null : h("button", { type: "button", class: "btn", onclick: (e) => openNotificationSettings(e.currentTarget) },
        "Open System Settings"))));
  return section;
}

async function openNotificationSettings(button) {
  try {
    state.notifications = await working(button, api("/api/notifications/open", {}));
  } catch (err) {
    errorToast(`System Settings did not open: ${err.message}`);
    return;
  }
  toast("Allow notifications for Palaver there; this page follows.", { short: true });
  watchNotifications(Date.now() + 120_000);
}

// Until they are on, or two minutes passed: the launcher asks macOS every 10 s.
function watchNotifications(until) {
  clearTimeout(state.notificationsTimer);
  if (state.view !== "settings" || state.notifications?.state === "granted" || Date.now() > until) return;
  state.notificationsTimer = setTimeout(async () => {
    await refreshNotifications();
    watchNotifications(until);
  }, 2000);
}

async function connectCalendarHere(button) {
  try {
    const answer = await working(button, api("/api/setup/calendar", { action: "connect" }));
    if (answer.opened_settings) toast("System Settings is open at Calendars: allow Palaver there, and this page follows.");
  } catch (err) {
    errorToast(`Calendar not connected: ${err.message}`);
    return;
  }
  watchCalendar();
}

function watchCalendar() {
  clearTimeout(state.calendarTimer);
  if (state.view !== "settings" || !state.calendar || state.calendar.state === "granted") return;
  state.calendarTimer = setTimeout(async () => {
    const now = await api("/api/setup/calendar").catch(() => null);
    if (state.view !== "settings") return;
    if (now && now.state !== state.calendar?.state) {
      state.calendar = now;
      $("#calendar-card")?.replaceWith(calendarCard());
    }
    watchCalendar();
  }, 1500);
}

async function changeSetting(key, value) {
  try {
    state.settings = await api("/api/settings", { [key]: value });
    state.error = null;
    // Whether each switch follows the recommendation now: a hint shows only under one that does not.
    const rec = await api("/api/setup/recommendations").catch(() => null);
    if (rec?.recommendations) state.recommended = rec.recommendations;
  } catch (err) {
    state.error = `Not saved: ${err.message}`;
  }
  renderSettings();
  // The page was rebuilt: keep keyboard focus on the switch that was used.
  $(`#main [data-key="${key}"]`)?.focus();
}

function settingSwitch(key, label) {
  const box = h("input", { type: "checkbox", role: "switch", class: "switch-input", "data-key": key,
    onchange: (e) => changeSetting(key, e.target.checked) });
  box.checked = !!state.settings[key];
  const row = h("label", { class: "switch-row" }, h("span", { class: "switch-label" }, label),
    box, h("span", { class: "switch-track", "aria-hidden": "true" }));
  const hint = recommendedHint(state.recommended, key);
  return hint ? [row, recommendedLine(hint)] : row;
}

// "Recommended for this Mac" under a setting: the same reasons as in the setup assistant.
function recommendedLine(hint) {
  return h("p", { class: hint.matches ? "meta setup-hint ok" : "meta setup-hint" }, hint.text);
}

function setupCard() {
  return h("div", { class: "gloss-card settings-card setup-entry" },
    h("div", { class: "lm-row" },
      h("span", {}, h("strong", {}, "Setup assistant"), h("br"),
        h("span", { class: "meta" }, "The settings worth choosing up front, recommended for this Mac, with the downloads and a test recording.")),
      h("button", { type: "button", class: "btn", onclick: () => openSetup() }, "Open setup assistant")));
}

// Settings as panes beside a list, like the Mac's System Settings: one pane at
// a time, each at #/settings/<pane> (a notification or a button opens the one meant).
function renderSettings() {
  const pane = settingsPane(state.settingsPane);
  const nav = h("nav", { class: "settings-nav", "aria-label": "Settings" }, SETTINGS_PANES.map(([id, label]) => {
    const flag = settingsFlag(id);
    return h("a", { href: `#/settings/${id}`, class: "settings-nav-item", "data-pane": id,
      "aria-current": id === pane ? "page" : false,
      onclick: (e) => { e.preventDefault(); openSettings("push", id); } },
    h("span", {}, label), flag ? h("span", { class: "settings-flag", title: flag, "aria-label": flag }) : null);
  }));
  const page = h("article", { class: "meeting settings" }, h("h1", {}, "Settings"),
    state.error ? h("p", { class: "error" }, state.error) : null,
    h("div", { class: "settings-layout" }, nav, h("div", { class: "settings-pane", "data-pane": pane }, settingsContent(pane))));
  $("#main").replaceChildren(page);
}

// What wants the user's eye in a pane, said beside its name in the list.
function settingsFlag(id) {
  if (id === "notifications" && ["denied", "not_asked"].includes(state.notifications?.state)) return "Notifications are off";
  if (id === "update" && updateIndicator(state.update)) return "An update is available";
  if (id === "calendar" && state.calendar && state.calendar.state !== "granted") return "The calendar is not connected";
  return null;
}

function settingsContent(pane) {
  const s = !!state.settings;
  switch (pane) {
    case "recording": return s ? [
      h("h2", {}, "Recording"),
      h("div", { class: "gloss-card settings-card" },
        settingSwitch("record_teams", "Record Teams calls automatically"),
        settingSwitch("record_slack", "Record Slack huddles automatically"),
        h("p", { class: "meta" }, "Start recording now in the menu bar works either way.")),
      h("h2", {}, "Live"),
      h("div", { class: "gloss-card settings-card" },
        settingSwitch("realtime", "Realtime transcription"),
        h("p", { class: "meta" }, "Text appears a few seconds after it is said, instead of about a minute later. Uses more power during calls."),
        settingSwitch("live_processing", "Process during calls"),
        h("p", { class: "meta" }, "Transcribes and tells speakers apart while the call runs, so a meeting is ready seconds after it ends. Off: after the call."),
        h("p", { class: "meta" }, "Applies from the next recording.")),
      h("h2", {}, "Live coach"),
      h("div", { class: "gloss-card settings-card" },
        h("p", { class: "meta" }, "Quiet nudges while you record a call: as a notification from Palaver (no sound; it goes away by itself), in Palaver's menu and on the meeting's page. At most one every 3 minutes."),
        settingSwitch("nudge_notify", "Show nudges as notifications"),
        settingSwitch("nudge_talk_share", "When you have talked much more than usual"),
        settingSwitch("nudge_monologue", "Long monologues (3 minutes and more)"),
        settingSwitch("nudge_quiet_invitee", "Invitees who haven't said anything yet"),
        settingSwitch("nudge_pace", "Speaking much faster than usual (experimental)"),
        settingSwitch("nudge_fillers", "More filler words than usual (experimental)"),
        h("p", { class: "meta" }, "“Usual” is your own average over your last 30 meetings. Pace and filler words are experimental and off by default: they come from the realtime text, which is not yet checked against your transcripts. Who hasn't spoken counts only invitees who accepted (or, without responses, whose voice you have named), and only when every voice in the call has a name. Calls only: never for a recording you started yourself.")),
    ] : [];
    case "calendar": return [h("h2", {}, "Calendar"), calendarCard()];
    case "notifications": return [notificationsSection()];
    case "transcription": return state.tr ? renderTranscription(state.tr) : [];
    case "language-model": return state.lm ? renderLanguageModel(state.lm) : [];
    case "search": return s ? [
      h("h2", {}, "Search"),
      h("div", { class: "gloss-card settings-card" },
        settingSwitch("search_meaning", "Search by meaning"),
        h("p", { class: "meta" }, "Also finds meetings about what you search for in other words or another language: “pricing” finds “Kosten”. Meetings are indexed in the background when no call is recorded. The first time, a 470 MB model is downloaded."))] : [];
    case "storage": return [renderStorageSection()];
    case "memory": return [renderMemorySection()];
    case "mcp": return [renderMcpSection()];
    case "update": return [renderUpdateSection()];
    default: return [
      h("h2", {}, "General"),
      setupCard(),
      h("h2", {}, "Help"),
      h("div", { class: "gloss-card settings-card" },
        h("p", { class: "meta" }, "Something went wrong, or you wish Palaver did something differently? A report puts ",
          "everything needed to look into it in one zip on your Desktop, for you to send."),
        h("button", { type: "button", class: "btn", onclick: () => APP_ACTIONS.reportProblem() }, "Report a Problem…"))];
  }
}

// --- updates and uninstalling (#60) -------------------------------------------------------

// A quiet line: the version, an update when there is one (with its notes),
// and the switch for looking automatically. The menu bar app does the work.
function renderUpdateSection() {
  const u = state.update;
  const view = updateView(u);
  const section = h("section", { id: "update-section" }, h("h2", {}, "Updates"));
  const label = { install: "Download and install", check: "Check now" }[view.action];
  section.append(h("div", { class: "gloss-card settings-card" },
    h("div", { class: "lm-row" }, h("span", { class: "meta", role: "status" }, view.text),
      label ? h("button", { type: "button", class: "btn", onclick: (e) => updateAction(view.action, e.currentTarget) }, label)
        : null),
    u?.available?.notes ? h("details", { class: "update-notes" }, h("summary", {}, "What's new"),
      h("p", { class: "meta" }, u.available.notes)) : null,
    view.action === "install" ? h("p", { class: "meta" },
      "Installs when nothing records or processes, then Palaver restarts. Your recordings and settings stay.") : null,
    state.settings && u?.state !== "unsupported" ? settingSwitch("check_updates", "Look for updates automatically") : null,
    state.settings && u?.state !== "unsupported" ? h("p", { class: "meta" },
      "At start, every hour and when you open this window Palaver asks GitHub for its latest release. Nothing is sent about you or this Mac, and nothing downloads until you click.") : null,
    h("div", { class: "lm-row" },
      h("span", { class: "meta" }, "Removes Palaver from this Mac. Your recordings stay unless you choose otherwise."),
      h("button", { type: "button", class: "btn", onclick: () => openUninstall() }, "Uninstall Palaver…"))));
  return section;
}

async function updateAction(action, button) {
  try {
    await busy(button, api(`/api/update/${action}`, {}));
  } catch (err) {
    toast(`Not done: ${err.message}`);
  }
  pollUpdate();
}

// While it checks or downloads, the line follows it.
let updatePoll = null;
function pollUpdate() {
  clearTimeout(updatePoll);
  updatePoll = setTimeout(async () => {
    try {
      state.update = await api("/api/update");
    } catch {
      return;
    }
    showUpdateIndicator();
    document.getElementById("update-section")?.replaceWith(renderUpdateSection());
    if (["checking", "downloading", "ready", "installing"].includes(state.update?.state)) pollUpdate();
  }, 1000);
}

// "Update to 0.3.7" in the top bar, on every page, and a card on Today; a click shows it in Settings.
// The menu bar app checks (at start, every hour, when the window opens); the window reads what it found.
async function refreshUpdate() {
  try {
    state.update = await api("/api/update");
  } catch {
    return;
  }
  showUpdateIndicator();
}

function showUpdateIndicator() {
  document.querySelector("#main .today .update-card")?.replaceWith(updateCardSection());
  const shown = updateIndicator(state.update);
  const button = $("#update-status");
  button.hidden = !shown;
  if (!shown) return;
  $("#update-status-text").textContent = shown.text;
  button.title = shown.title;
  button.setAttribute("aria-label", shown.title);
}

async function openUpdate() {
  await openSettings("push", "update");
}

$("#update-status").addEventListener("click", () => openUpdate());

function openUninstall() {
  const models = h("input", { type: "checkbox" });
  const recordings = h("input", { type: "checkbox" });
  dialog({
    title: "Uninstall Palaver?",
    body: [
      h("p", { class: "meta" }, "Palaver quits and removes the app, its runtime, the login item, the palaver command and a downloaded update."),
      h("fieldset", { class: "export-choices" }, h("legend", { class: "visually-hidden" }, "What else goes"),
        h("label", { class: "export-choice" }, models, h("span", { class: "export-label" }, "Also remove the models"),
          h("span", { class: "meta export-hint" }, "The speech models in Palaver's folder; they can be downloaded again.")),
        h("label", { class: "export-choice" }, recordings,
          h("span", { class: "export-label" }, "Also delete my recordings"),
          h("span", { class: "meta export-hint" }, "Every meeting folder in your recordings folder and in its trash (audio, transcripts, notes), ",
            "and Palaver's data: voices, glossary, people, projects, settings and logs. Other files in the recordings folder stay."))),
      h("p", { class: "meta" }, "Models from Hugging Face (the notes model) stay in ~/.cache/huggingface."),
    ],
    buttons: [{ label: "Cancel" }, { label: "Uninstall", value: "done", run: () => api("/api/uninstall",
      { confirm: true, models: models.checked, recordings: recordings.checked }) }],
  });
}

// --- memory (issue #49) -------------------------------------------------------------

// What Palaver and each of its workers use now, against their budgets. The
// numbers come from the menu bar app; Settings refreshes them while open.
async function refreshMemory() {
  try {
    state.memory = (await api("/api/memory")).memory;
  } catch {
    return;  // keeps what it showed
  }
  document.getElementById("memory-section")?.replaceWith(renderMemorySection());
}

function renderMemorySection() {
  const mem = state.memory;
  const section = h("section", { id: "memory-section", class: "memory-section" }, h("h2", {}, "Memory"));
  if (!mem) {
    section.append(h("div", { class: "gloss-card settings-card" },
      h("p", { class: "meta" }, "Shown while the Palaver menu bar app runs.")));
    return section;
  }
  section.append(h("div", { class: "gloss-card settings-card" },
    h("p", { class: "memory-total" }, memoryTotalText(mem)),
    h("ul", { class: "memory-rows" }, memoryRows(mem).map((r) =>
      h("li", { class: `memory-row${r.over ? " over" : ""}`, "data-kind": r.kind },
        h("span", { class: "memory-label" }, r.label),
        h("span", { class: "memory-state" }, r.state),
        h("span", { class: "memory-size meta" }, r.size),
        h("span", { class: "memory-bar", "aria-hidden": "true" },
          h("span", { class: "memory-fill", style: `width: ${Math.round(r.fill * 100)}%` }))))),
    h("p", { class: "meta" }, "Each worker has a budget, set under [memory] in config.toml. Live and realtime ",
      "transcription are restarted when they pass theirs. Notes, transcriptions and the search index finish, unless the Mac runs ",
      "low on memory: then they stop and are tried again later. The recording itself never stops.")));
  return section;
}

setInterval(() => { if (memoryPolling(state.view, document.hidden)) refreshMemory(); }, 5000);

// --- storage (#9) --------------------------------------------------------------------

async function refreshStorage() {
  try {
    state.storage = await api("/api/storage");
  } catch {
    return;
  }
  document.getElementById("storage-section")?.replaceWith(renderStorageSection());
}

// What the meetings and the models take, how long a meeting keeps its audio,
// and a notes model no longer used to delete.
function renderStorageSection() {
  const s = state.storage;
  const section = h("section", { id: "storage-section" }, h("h2", {}, "Storage"));
  if (!s) return section;
  const select = h("select", { "aria-label": "Delete the audio of transcribed meetings" },
    s.days.map((d) => h("option", { value: String(d), selected: d === s.audio_days }, audioDaysLabel(d))));
  select.addEventListener("change", () => changeAudioDays(Number(select.value), select));
  section.append(h("div", { class: "gloss-card settings-card" },
    h("p", {}, storageTotalText(s)),
    h("div", { class: "lm-row" }, h("span", {}, "Delete the audio of transcribed meetings"), select),
    h("p", { class: "meta" }, "Transcripts, notes and speakers stay. Without its audio a meeting can't be played or ",
      "transcribed again. A single meeting's audio: Delete Audio… in its ⋯ menu."),
    s.models.map((mod) => h("div", { class: "lm-row", "data-model": mod.id },
      h("span", {}, mod.label, h("span", { class: "meta" }, ` · ${mod.purpose}`)),
      h("span", { class: "storage-size" }, h("span", { class: "meta" }, sizeText(mod.bytes)),
        mod.deletable ? h("button", { type: "button", class: "btn btn-quiet small",
          onclick: (e) => deleteModel(mod, e.currentTarget) }, "Delete") : null))),
    h("p", { class: "meta" }, `Meetings are in ${s.folder}. Models from Hugging Face are in ~/.cache/huggingface.`)));
  return section;
}

async function changeAudioDays(days, select) {
  const ask = audioDaysConfirm(state.storage, days);
  if (ask) {
    const answer = await dialog({ title: "Delete old audio now?", body: [h("p", { class: "meta" }, ask)],
      buttons: [{ label: "Cancel" }, { label: "Delete Audio", value: "delete" }] }).result;
    if (answer !== "delete") {
      select.value = String(state.storage.audio_days);
      return;
    }
  }
  try {
    state.storage = await api("/api/storage", { audio_days: days, now: true });
  } catch (err) {
    errorToast(`Not saved: ${err.message}`);
    select.value = String(state.storage.audio_days);
    return;
  }
  const d = state.storage.dropped;
  toast(d?.meetings ? `Audio of ${d.meetings} meeting${d.meetings === 1 ? "" : "s"} deleted: ${sizeText(d.bytes)} free again.`
    : "Saved.", { short: true });
  document.getElementById("storage-section")?.replaceWith(renderStorageSection());
}

async function deleteModel(mod, button) {
  const answer = await dialog({ title: `Delete ${mod.label}?`,
    body: [h("p", { class: "meta" }, `Palaver doesn't use it now. It frees ${sizeText(mod.bytes)}; choosing it again in `,
      "Language model downloads it again.")],
    buttons: [{ label: "Cancel" }, { label: "Delete", value: "delete" }] }).result;
  if (answer !== "delete") return;
  try {
    state.storage = await busy(button, api("/api/storage", { delete_model: mod.id }));
  } catch (err) {
    errorToast(`Not deleted: ${err.message}`);
    return;
  }
  toast(`${mod.label} deleted: ${sizeText(mod.bytes)} free again.`, { short: true });
  document.getElementById("storage-section")?.replaceWith(renderStorageSection());
}

// --- settings: the language model (#53) ---------------------------------------------

// Rebuild the page after a change and give focus back to the control used.
function lmRender(focus) {
  renderSettings();
  if (focus) $(`#main [data-lm="${focus}"]`)?.focus();
}

async function changeLanguageModel(body, focus) {
  try {
    state.lm = await api("/api/language-model", body);
    state.lmError = null;
  } catch (err) {
    state.lmError = `Not saved: ${err.message}`;
  }
  lmRender(focus);
}

async function removeKey(pid) {
  try {
    state.lm = await api("/api/language-model/key", { provider: pid, remove: true });
    state.lmError = null;
    toast("Key removed from the Keychain.", { short: true });
  } catch (err) {
    state.lmError = `Key not removed: ${err.message}`;
  }
  lmRender(`key-input-${pid}`);
}

async function testProvider(pid, button) {
  state.lmTests[pid] = { text: "Asking…" };
  lmRender(`test-${pid}`);
  try {
    const result = await busy($(`#main [data-lm="test-${pid}"]`) || button, api("/api/language-model/test", { provider: pid }));
    state.lmTests[pid] = { text: testText(result) };
  } catch (err) {
    state.lmTests[pid] = { error: err.message };
  }
  state.lm = await api("/api/language-model").catch(() => state.lm);  // the test is in the access log
  lmRender(`test-${pid}`);
}

function lmField(label, input) {
  return h("label", { class: "lm-field" }, h("span", { class: "lm-label" }, label), input);
}

function featureRow(lm, f) {
  const select = h("select", { class: "filter inline lm-select", "data-lm": `use-${f.id}`, "aria-label": `Model for ${f.label}`,
    onchange: (e) => changeLanguageModel({ use: { [f.id]: e.target.value } }, `use-${f.id}`) },
  engineOptions(lm).map((o) => h("option", { value: o.value, disabled: o.disabled }, o.label)));
  select.value = f.choice;
  const cloud = f.choice !== "local";
  return h("div", { class: "lm-feature" },
    h("div", { class: "lm-row" }, h("span", { class: "lm-feature-label" }, f.label), select),
    h("p", { class: cloud ? "meta lm-sends cloud" : "meta lm-sends" }, sendsText(lm, f)));
}

function localCard(lm) {
  const select = h("select", { class: "filter inline lm-select", "data-lm": "local-model", "aria-label": "Local model",
    onchange: (e) => changeLanguageModel({ local_model: e.target.value }, "local-model") },
  lm.local.models.map((m) => h("option", { value: m.repo },
    `${m.label} · ${m.memory_gb} GB free memory while writing · ${tokensText(m.context_tokens)}`)));
  select.value = lm.local.model;
  const chosen = lm.local.models.find((m) => m.repo === lm.local.model);
  return h("div", { class: "gloss-card settings-card" },
    h("h3", { class: "lm-title" }, "On this Mac"),
    lmField("Model", select),
    chosen?.note ? h("p", { class: "meta" }, chosen.note) : null,
    h("p", { class: "meta" }, "Notes wait until this much memory is free, and never run during a call."));
}

// The key field of a provider card; ``keys``: where the key goes (a language
// model's or a transcription service's) and which fields are open to replace one.
// The card's one Save stores a key typed here too; Enter in the field is that Save.
const lmKeys = { replacing: () => state.lmReplacing, remove: (pid) => removeKey(pid) };

function keyRow(p, keys = lmKeys, onSave = () => {}) {
  if (p.key === "none") return h("p", { class: "meta" }, "Uses your Claude Code login; no key needed here.");
  const replacing = keys.replacing();
  if (p.key_set && !replacing.has(p.id)) {
    return h("div", { class: "lm-row lm-key" },
      h("span", { class: "lm-key-set" }, "Key set ✓"),
      h("span", { class: "lm-actions" },
        h("button", { type: "button", class: "btn btn-quiet small", "data-lm": `key-${p.id}`,
          onclick: () => { replacing.add(p.id); lmRender(`key-input-${p.id}`); } }, "Replace"),
        h("button", { type: "button", class: "btn btn-quiet small danger", onclick: () => keys.remove(p.id) }, "Remove")));
  }
  const input = h("input", { type: "password", class: "lm-input", autocomplete: "off", spellcheck: "false",
    "data-lm": `key-input-${p.id}`, "aria-label": `API key for ${p.label}`,
    placeholder: p.key === "optional" ? "API key (not needed for a gateway on this Mac)" : "API key",
    title: "Saved in the Keychain with Save",
    onkeydown: (e) => { if (e.key === "Enter") onSave(); } });
  return h("div", { class: "lm-row lm-key" }, input,
    replacing.has(p.id) ? h("span", { class: "lm-actions" }, h("button", { type: "button", class: "btn btn-quiet small",
      "data-lm": `key-${p.id}`, onclick: () => { replacing.delete(p.id); lmRender(`key-${p.id}`); } }, "Cancel")) : null);
}

// A provider card's Save: the key typed into it first (to the Keychain, never
// kept in the page), then the card's other fields. A key that fails stops there.
async function saveCard(p, { keyPath, which, render }, body, apply) {
  const input = $(`#main [data-lm="key-input-${p.id}"]`);
  const key = input?.value ?? "";
  if (input) input.value = "";
  if (key.trim()) {
    try {
      state[which] = await busy($(`#main [data-lm="save-${p.id}"]`), api(keyPath, { provider: p.id, key }));
      state[`${which}Replacing`].delete(p.id);
      toast("Key saved in the Keychain.", { short: true });
    } catch (err) {
      state[`${which}Error`] = `Key not saved: ${err.message}`;
      render(`save-${p.id}`);
      return;
    }
  }
  await apply(body, `save-${p.id}`);
}

// How the key is sent: only the OpenAI-compatible providers ask (Azure wants an api-key header).
function authSelect(p) {
  if (p.auth === undefined) return null;
  const select = h("select", { class: "filter inline lm-select", "data-lm": `auth-${p.id}`,
    "aria-label": `Key header for ${p.label}` },
  [["auto", "Automatic: api-key for Azure, Bearer otherwise"], ["bearer", "Authorization: Bearer"],
    ["api-key", "api-key header (Azure)"]].map(([value, label]) => h("option", { value }, label)));
  select.value = p.auth;
  return select;
}

function providerCard(p) {
  const inputs = {};
  const field = (name, label, attrs = {}) => {
    inputs[name] = h("input", { class: "lm-input", value: String(p[name] ?? ""), spellcheck: "false",
      "data-lm": `${name}-${p.id}`, "aria-label": `${label} for ${p.label}`, ...attrs });
    return lmField(label, inputs[name]);
  };
  const save = () => {
    const body = { provider: p.id, model: inputs.model.value, context_tokens: Number(inputs.context_tokens.value) };
    if (inputs.endpoint) body.endpoint = inputs.endpoint.value;
    if (auth) body.auth = auth.value;
    return saveCard(p, { keyPath: "/api/language-model/key", which: "lm", render: lmRender }, body, changeLanguageModel);
  };
  const auth = authSelect(p);
  const test = state.lmTests[p.id];
  return h("div", { class: "gloss-card settings-card" },
    h("h3", { class: "lm-title" }, p.label),
    h("p", { class: "meta" }, `Whatever a feature sends with this goes to ${p.sends_to}.`),
    p.has_endpoint ? field("endpoint", "Endpoint", { type: "url", placeholder: "https://…" }) : null,
    field("model", "Model", { placeholder: p.id === "openai" ? "e.g. the deployment or model name" : "" }),
    field("context_tokens", "Context window (tokens)", { type: "number", min: "1000", step: "1000" }),
    auth ? lmField("Key header", auth) : null,
    keyRow(p, lmKeys, save),
    h("div", { class: "lm-row" },
      h("span", { class: p.ready ? "meta" : "meta lm-problem" }, p.ready ? "Ready." : `${p.problem}.`),
      h("span", { class: "lm-actions" },
        h("button", { type: "button", class: "btn small", "data-lm": `save-${p.id}`, title: "Saves these settings and a key typed above",
          onclick: save }, "Save"),
        h("button", { type: "button", class: "btn small", "data-lm": `test-${p.id}`, disabled: !p.ready,
          title: "Sends a short greeting request, no meeting content",
          onclick: (e) => testProvider(p.id, e.currentTarget) }, "Test"))),
    test ? h("p", { class: test.error ? "meta error" : "meta", role: "status" }, test.error || test.text) : null);
}

function accessLogCard(lm) {
  const fmt = (iso) => `${shortDayFmt.format(new Date(iso))}, ${timeFmt.format(new Date(iso))}`;
  return h("div", { class: "gloss-card settings-card" },
    h("h3", { class: "lm-title" }, "Sent to the cloud"),
    lm.log.length
      ? h("ul", { class: "lm-log" }, lm.log.map((e) => h("li", { class: e.ok ? null : "failed" },
        h("span", { class: "meta lm-log-time" }, fmt(e.time)), accessLogText(e, lm))))
      : h("p", { class: "meta" }, "Nothing has been sent to the cloud."));
}

function renderLanguageModel(lm) {
  return [
    h("h2", {}, "Language model"),
    h("div", { class: "gloss-card settings-card" },
      h("p", { class: "meta" }, "Notes and projects are written on this Mac unless you choose a cloud model for them here. "
        + "Nothing switches to the cloud by itself. A meeting marked “Keep on This Mac” always stays here: "
        + "no cloud model gets it, and Claude can't read it through MCP."),
      // For the whole choice, so under the intro, not under the last feature.
      (() => { const hint = recommendedHint(state.recommended, "language_model"); return hint ? recommendedLine(hint) : null; })(),
      ...lm.features.map((f) => featureRow(lm, f)),
      state.lmError ? h("p", { class: "error", role: "alert" }, state.lmError) : null),
    localCard(lm),
    h("h2", {}, "Cloud models"),
    ...lm.providers.map(providerCard),
    accessLogCard(lm),
  ];
}

// --- settings: transcription (#54) ---------------------------------------------------

async function changeTranscription(body, focus) {
  try {
    state.tr = await api("/api/transcription", body);
    state.trError = null;
  } catch (err) {
    state.trError = `Not saved: ${err.message}`;
  }
  lmRender(focus);
}

async function removeTranscriptionKey(pid) {
  try {
    state.tr = await api("/api/transcription/key", { provider: pid, remove: true });
    state.trError = null;
    toast("Key removed from the Keychain.", { short: true });
  } catch (err) {
    state.trError = `Key not removed: ${err.message}`;
  }
  lmRender(`key-input-${pid}`);
}

const trKeys = { replacing: () => state.trReplacing, remove: removeTranscriptionKey };

async function testTranscription(pid, button) {
  state.trTests[pid] = { text: "Sending two seconds of a tone…" };
  lmRender(`test-${pid}`);
  try {
    const result = await busy($(`#main [data-lm="test-${pid}"]`) || button,
      api("/api/transcription/test", { provider: pid }));
    state.trTests[pid] = { text: transcriptionTestText(result) };
  } catch (err) {
    state.trTests[pid] = { error: err.message };
  }
  // The test is in the access log, shown with the language model's.
  [state.tr, state.lm] = await Promise.all([api("/api/transcription").catch(() => state.tr),
    api("/api/language-model").catch(() => state.lm)]);
  lmRender(`test-${pid}`);
}

function transcriptionCard(p) {
  const inputs = {};
  const field = (name, label, attrs = {}) => {
    inputs[name] = h("input", { class: "lm-input", value: String(p[name] ?? ""), spellcheck: "false",
      "data-lm": `${name}-${p.id}`, "aria-label": `${label} for ${p.label}`, ...attrs });
    return lmField(label, inputs[name]);
  };
  const region = p.region === undefined ? null : h("select", { class: "filter inline lm-select",
    "data-lm": `region-${p.id}`, "aria-label": `Region for ${p.label}` },
  [["eu", "EU servers"], ["us", "US servers"]].map(([value, label]) => h("option", { value }, label)));
  if (region) region.value = p.region;
  const auth = authSelect(p);
  const save = () => {
    const body = { provider: p.id, model: inputs.model.value };
    if (inputs.endpoint) body.endpoint = inputs.endpoint.value;
    if (region) body.region = region.value;
    if (auth) body.auth = auth.value;
    return saveCard(p, { keyPath: "/api/transcription/key", which: "tr", render: lmRender }, body, changeTranscription);
  };
  const test = state.trTests[p.id];
  return h("div", { class: "gloss-card settings-card" },
    h("h3", { class: "lm-title" }, p.label),
    h("p", { class: "meta" }, `Audio sent with this goes to ${p.sends_to}. ${p.privacy}`),
    h("p", { class: "meta" }, priceText(p)),
    region ? lmField("Region", region) : null,
    p.has_endpoint ? field("endpoint", "Endpoint", { type: "url", placeholder: "https://…" }) : null,
    field("model", "Model"),
    auth ? lmField("Key header", auth) : null,
    keyRow(p, trKeys, save),
    h("div", { class: "lm-row" },
      h("span", { class: p.ready ? "meta" : "meta lm-problem" }, p.ready ? "Ready." : `${p.problem}.`),
      h("span", { class: "lm-actions" },
        h("button", { type: "button", class: "btn small", "data-lm": `save-${p.id}`, title: "Saves these settings and a key typed above",
          onclick: save }, "Save"),
        h("button", { type: "button", class: "btn small", "data-lm": `test-${p.id}`, disabled: !p.ready,
          title: "Sends two seconds of a tone, no meeting",
          onclick: (e) => testTranscription(p.id, e.currentTarget) }, "Test"))),
    test ? h("p", { class: test.error ? "meta error" : "meta", role: "status" }, test.error || test.text) : null);
}

function renderTranscription(tr) {
  const select = h("select", { class: "filter inline lm-select", "data-lm": "use-transcription",
    "aria-label": "Who transcribes meetings",
    onchange: (e) => changeTranscription({ use: e.target.value }, "use-transcription") },
  transcriberOptions(tr).map((o) => h("option", { value: o.value, disabled: o.disabled }, o.label)));
  select.value = tr.feature.choice;
  const cloud = tr.feature.choice !== "local";
  return [
    h("h2", {}, "Transcription"),
    h("div", { class: "gloss-card settings-card" },
      h("p", { class: "meta" }, "Meetings are transcribed on this Mac unless you choose a service here. "
        + "Only the system track goes out, what the others said: your microphone is transcribed on this Mac, "
        + "and who spoke when is worked out here too. If the service fails, the meeting is transcribed here "
        + "and a notification says so. A meeting marked “Keep on This Mac” is always transcribed here."),
      h("div", { class: "lm-feature" },
        h("div", { class: "lm-row" }, h("span", { class: "lm-feature-label" }, "Transcription"), select),
        h("p", { class: cloud ? "meta lm-sends cloud" : "meta lm-sends" }, transcriptionSendsText(tr))),
      h("p", { class: "meta" }, `${monthText(tr.month)} Applies from the next meeting processed.`),
      state.trError ? h("p", { class: "error", role: "alert" }, state.trError) : null),
    h("h2", {}, "Transcription services"),
    ...tr.providers.map(transcriptionCard),
  ];
}

$("#settings-btn").addEventListener("click", () => openSettings());

// --- Claude access (MCP) ------------------------------------------------------------

// Each Claude session runs its own `palaver mcp`; /api/mcp tells which run,
// what they read (the access log) and whether Claude Code starts the server.

const meetingTitleById = (id) => {
  const m = state.meetings.find((x) => x.id === id);
  return m ? m.title || fallbackTitle(m) : null;
};

// "Today 14:02", "Yesterday 09:10", "Tue 28 Oct, 14:02"; ``lower``: for the
// middle of a sentence ("today 14:02", "on Tue 28 Oct, 14:02").
function whenText(iso, { lower = false } = {}) {
  const at = new Date(iso);
  if (!iso || Number.isNaN(at.getTime())) return "";
  const time = timeFmt.format(at);
  const today = new Date();
  const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  if (at.toDateString() === today.toDateString()) return `${lower ? "today" : "Today"} ${time}`;
  if (at.toDateString() === yesterday.toDateString()) return `${lower ? "yesterday" : "Yesterday"} ${time}`;
  return `${lower ? "on " : ""}${shortDayFmt.format(at)}, ${time}`;
}

let mcpShown = "";  // what the Settings section shows, to rebuild it only when that changed
async function refreshMcp() {
  try {
    state.mcp = await api("/api/mcp");
  } catch {
    return;  // the indicator keeps what it showed
  }
  showMcpIndicator();
  const open = state.view === "meetings" && state.meeting;
  if (open) {
    const newest = state.mcp.log.find((e) => (e.meetings || []).includes(open.id));
    if (newest && newest.time !== state.mcpReads.get(open.id)?.[0]?.time) loadMcpReads(open.id);
  }
  const section = document.getElementById("mcp-section");
  if (section && JSON.stringify(state.mcp) !== mcpShown && !section.contains(document.activeElement)) {
    if (state.mcpFilter.meeting) await loadMcpReads(state.mcpFilter.meeting);
    section.replaceWith(renderMcpSection());
  }
}

function showMcpIndicator() {
  const shown = mcpIndicator(state.mcp?.clients);
  const button = $("#mcp-status");
  button.hidden = !shown;
  if (!shown) return;
  $("#mcp-status-text").textContent = shown.text;
  button.title = shown.title;
  button.setAttribute("aria-label", shown.title);
}

async function openMcpLog(meeting = "") {
  state.mcpFilter = { client: "", meeting };
  if (meeting) await loadMcpReads(meeting);
  await openSettings("push", "mcp");
}

$("#mcp-status").addEventListener("click", () => openMcpLog());

async function loadMcpReads(id) {
  try {
    const { reads } = await api(`/api/mcp?meeting=${encodeURIComponent(id)}`);
    state.mcpReads.set(id, reads);
  } catch {
    return;
  }
  const slot = document.querySelector(`#main .mcp-read[data-id="${CSS.escape(id)}"]`);
  if (!slot) return;
  const line = mcpReadLine(id);
  slot.replaceWith(line);
  const about = line.closest("details.about");  // shown once it has something to say
  if (about) about.hidden = line.hidden && !about.querySelector(".about-lines li");
}

// The Settings log filtered by a meeting: that meeting's entries from the server.
async function filterMcpByMeeting(id, focus) {
  state.mcpFilter = { ...state.mcpFilter, meeting: id };
  if (id) await loadMcpReads(id);
  rerenderMcp(focus);
}

// "Read by Claude Code today 14:02 (notes, transcript 0–20 min)": what the
// assistant saw of this meeting. Empty (and hidden) until it read something.
function mcpReadLine(id) {
  const read = mcpReadOf(state.mcpReads.get(id));
  const line = h("p", { class: "mcp-read", "data-id": id, hidden: !read });
  if (!read) return line;
  line.append(`Read by ${clientName(read.client, { version: false })} ${whenText(read.time, { lower: true })}`,
    read.parts.length ? ` (${read.parts.join(", ")})` : "", " · ",
    h("button", { type: "button", class: "link small", onclick: () => openMcpLog(id) }, "Access log"));
  return line;
}

const APPS = {
  code: { name: "Claude Code", added: "Added to Claude Code. New Claude sessions can read your meetings." },
  desktop: { name: "Claude Desktop", added: "Added to Claude Desktop. Quit and reopen Claude Desktop to use it." },
};

// Whether Claude Code and Claude Desktop (when installed) start the server,
// with a button to add it where they don't.
function mcpSetup(d) {
  const row = (target, setup, where) => {
    const app = APPS[target];
    if (setup?.registered) return h("p", { class: "mcp-setup ok" }, `✓ ${app.name} starts Palaver's MCP server (“${setup.name}”${where ? `, ${where}` : ""}).`);
    const add = h("button", { type: "button", class: "btn", onclick: () => installMcp(add, target) }, `Add to ${app.name}`);
    return h("div", { class: "mcp-setup" },
      h("p", {}, setup?.registered === null ? `Could not tell whether ${app.name} starts Palaver's MCP server.`
        : `${app.name} does not know Palaver's MCP server yet.`), add);
  };
  const code = d.registered;
  return [row("code", code, code?.registered ? (code.scope === "user" ? "all projects" : "one project") : null),
    d.desktop?.installed || d.desktop?.registered ? row("desktop", d.desktop) : null];
}

async function installMcp(button, target = "code") {
  const app = APPS[target];
  try {
    state.mcp = await busy(button, api("/api/mcp/install", { target }));
    toast(app.added);
  } catch (err) {
    errorToast(`Not added to ${app.name}: ${err.message}`, { action: { label: "Try again", run: () => installMcp(button, target) } });
    return;
  }
  document.getElementById("mcp-section")?.replaceWith(renderMcpSection());
}

function mcpClientRow(c) {
  const since = c.started ? `connected since ${whenText(c.started, { lower: true })}` : "connected";
  const calls = c.calls ? `${c.calls} ${c.calls === 1 ? "call" : "calls"}, last ${whenText(c.last_call, { lower: true })}` : "no calls yet";
  return h("li", { class: "mcp-client" }, h("span", { class: "mcp-dot", "aria-hidden": "true" }),
    h("span", { class: "mcp-client-name" }, clientName(c.client)),
    h("span", { class: "meta" }, `${since} · ${calls}`));
}

function mcpEntryRow(e) {
  const size = [mcpSizeText(e.out), e.ms != null ? `${e.ms} ms` : null].filter(Boolean).join(" · ");
  return h("li", { class: `mcp-entry${e.error ? " failed" : ""}` },
    h("div", { class: "mcp-entry-head" },
      h("time", { datetime: e.time }, whenText(e.time)),
      h("span", { class: "mcp-entry-client" }, clientName(e.client, { version: false })),
      h("code", { class: "mcp-tool" }, e.tool)),
    h("div", { class: "mcp-entry-body" },
      h("span", { class: "mcp-args" }, mcpArgsText(e, meetingTitleById)),
      e.error ? h("span", { class: "error" }, `failed: ${e.error}`) : h("span", { class: "meta" }, size)));
}

function mcpFilters(log) {
  const pick = (key, label, options) => {
    const select = h("select", { class: "filter inline", "aria-label": label,
      onchange: (e) => {
        const focus = `select[aria-label="${label}"]`;
        if (key === "meeting") return filterMcpByMeeting(e.target.value, focus);
        state.mcpFilter = { ...state.mcpFilter, [key]: e.target.value };
        rerenderMcp(focus);
      } },
    options.map(([value, text]) => h("option", { value }, text)));
    select.value = state.mcpFilter[key];
    if (select.value !== state.mcpFilter[key]) select.value = "";
    return select;
  };
  const meetings = logMeetings(log).map((id) => [id, meetingTitleById(id) || id]);
  if (state.mcpFilter.meeting && !meetings.some(([id]) => id === state.mcpFilter.meeting)) {
    meetings.unshift([state.mcpFilter.meeting, meetingTitleById(state.mcpFilter.meeting) || state.mcpFilter.meeting]);
  }
  return [
    pick("client", "Client", [["", "All clients"], ...logClients(log).map((c) => [c.key, c.label])]),
    pick("meeting", "Meeting", [["", "All meetings"], ...meetings]),
  ];
}

function rerenderMcp(focus) {
  document.getElementById("mcp-section")?.replaceWith(renderMcpSection());
  if (focus) document.querySelector(`#mcp-section ${focus}`)?.focus();
}

async function clearMcpLog(button) {
  let answer;
  try {
    answer = await busy(button, api("/api/mcp/clear", {}));
  } catch (err) {
    errorToast(`The log was not cleared: ${err.message}`, { action: { label: "Try again", run: () => clearMcpLog(button) } });
    return;
  }
  state.mcp = answer;
  state.mcpReads.clear();
  rerenderMcp();
  if (!answer.undo) return toast("The access log is already empty", { short: true });
  remember(clearedText(answer.cleared), async () => {
    state.mcp = await api("/api/mcp/restore", { token: answer.undo });
    state.mcpReads.clear();
    if (state.mcpFilter.meeting) await loadMcpReads(state.mcpFilter.meeting);
    rerenderMcp();
  });
}

function renderMcpSection() {
  const d = state.mcp;
  const section = h("section", { id: "mcp-section", class: "mcp-section" }, h("h2", {}, "Claude access (MCP)"));
  mcpShown = JSON.stringify(d);
  if (!d) {
    section.append(h("div", { class: "gloss-card settings-card" }, h("p", { class: "meta" }, "Loading…")));
    return section;
  }
  section.append(h("div", { class: "gloss-card settings-card" },
    mcpSetup(d),
    h("p", { class: "meta" }, "Claude reads your meetings, notes and transcripts through Palaver's MCP server, except meetings kept on this Mac. Each Claude session starts its own; every call is listed below."),
    d.clients.length ? h("ul", { class: "mcp-clients" }, d.clients.map(mcpClientRow))
      : h("p", { class: "meta" }, "No client is connected right now.")));

  const shown = logShown(d.log, state.mcpReads, state.mcpFilter);
  const clear = h("button", { type: "button", class: "btn danger", disabled: !d.log.length,
    onclick: () => clearMcpLog(clear) }, "Clear log");
  section.append(
    h("div", { class: "mcp-log-head" }, h("h3", {}, "Access log"), ...(d.log.length ? mcpFilters(d.log) : []), clear),
    d.log.length
      ? (shown.length ? h("ol", { class: "mcp-log" }, shown.map(mcpEntryRow)) : h("p", { class: "meta" }, "Nothing matches these filters."))
      : h("p", { class: "meta" }, "Nothing read yet. Calls show here with what went out."));
  if (d.log.length >= 200) section.append(h("p", { class: "meta" }, "The newest 200 calls."));
  return section;
}

// --- the setup assistant (#55) --------------------------------------------------------

// A step at a time: the recommendation for this Mac and why, the alternatives
// (Customize), Back, and a way to skip. Nothing changes until a click; every
// choice stays changeable in Settings.

const setup = {
  page: null,             // /api/setup
  step: "mac",
  picks: {},              // recommendation id -> the value picked under Customize
  customizing: new Set(), // recommendation ids whose alternatives are open
  seed: null,             // glossary terms from the calendar that are ticked
  autostart: null,        // step 2's "Start Palaver at login" (null: on, as recommended)
  customizeAll: false,    // step 2 shows every choice with its alternatives
  error: null,
  timer: null,            // polling the downloads or the test recording
};

async function loadSetup() {
  try {
    setup.page = await api("/api/setup");
    setup.error = null;
  } catch (err) {
    setup.error = `Palaver could not look at this Mac: ${err.message}`;
  }
}

async function openSetup(step = null, how = "push") {
  step = SETUP_STEPS.some((s) => s.id === step) ? step : SETUP_STEPS[0].id;
  const here = leaveMeeting("setup", hashOf({ view: "setup", step }), how);
  if (setup.step !== step) { setup.picks = {}; setup.customizing.clear(); }
  setup.step = step;
  if (!setup.page || step === "recommended") {
    renderSetup();  // at once: the last look, or "Looking at this Mac…" (a look takes a few seconds)
    await loadSetup();
  }
  if (movedOn(here)) return;
  renderSetup();
  $("#main").scrollTop = 0;
  $("#main h1")?.focus({ preventScroll: true });
  watchSetup();
}

// Moving on: the next step replaces this one in the history (‹ Back in the top bar
// leaves the assistant; its own Back goes one step back).
const setupGo = (step) => (step ? openSetup(step, "replace") : finishSetup("done"));

async function finishSetup(how, button = null) {
  try {
    await working(button, api("/api/setup/finish", { how }));
  } catch (err) {
    errorToast(`Not saved: ${err.message}`, { action: { label: "Try again", run: () => finishSetup(how) } });
    return;
  }
  clearTimeout(setup.timer);
  const downloading = setup.page?.downloads?.status?.running;
  setup.page = null;
  setup.autostart = null;
  setup.customizeAll = false;
  toast(how !== "done" ? "Setup skipped. It is in Settings when you want it."
    : downloading ? "Setup done. The models finish downloading in the background; Settings shows how far."
      : "Setup done. Change any of it in Settings.");
  openToday();
}

const markOf = { ok: "✓", warn: "!", fail: "✕" };
// The calendar's row: its button asks macOS (or, once refused, opens System
// Settings at Calendars). Until it is connected the page keeps looking, so a
// connection made from the menu bar or System Settings shows here too.
function calendarRow(p) {
  const cal = p.permissions.calendar;
  const t = permissionText(cal);
  const fix = cal?.state === "denied" ? (cal.fix || p.summary.find((c) => c.name === "Calendar")?.fix || "") : "";
  const row = checkRow("Calendar", t.status, t.text, fix);
  if (cal?.state !== "granted") {
    row.append(h("button", { type: "button", class: "btn small setup-connect", onclick: (e) => connectCalendar(e.currentTarget) },
      cal?.state === "denied" ? "Open System Settings" : "Connect Calendar"));
  }
  return row;
}

async function connectCalendar(button) {
  let answer;
  try {
    answer = await working(button, api("/api/setup/calendar", { action: "connect" }));
  } catch (err) {
    errorToast(`Calendar not connected: ${err.message}`, { action: { label: "Try again", run: () => connectCalendar() } });
    return;
  }
  if (answer.opened_settings) toast("System Settings is open at Calendars: allow Palaver there, and this page follows.");
  watchSetup();
}

// The calendar connected while the page looked: the step again with what the
// calendar brings (organization, names for the glossary), keeping what was typed.
async function calendarConnected() {
  const before = setup.page.profile || {};
  const typed = { "setup-name": [document.getElementById("setup-name")?.value, before.name],
    "setup-org": [document.getElementById("setup-org")?.value, before.organization] };
  await loadSetup();
  setup.seed = null;  // ticked again from the calendar's names
  rerenderSetup();
  for (const [id, [value, was]] of Object.entries(typed)) {
    const field = document.getElementById(id);
    if (field && value != null && value !== (was || "")) field.value = value;
  }
}

function checkRow(name, status, detail, fix) {
  return h("li", { class: `setup-check ${status}` },
    h("span", { class: "setup-mark", "aria-hidden": "true" }, markOf[status] || "·"),
    h("span", { class: "setup-check-text" },
      h("span", { class: "setup-check-name" }, name), " ", h("span", { class: "setup-check-detail" }, detail),
      fix && status !== "ok" ? h("span", { class: "setup-fix" }, fix) : null));
}

function currentLabel(r) {
  const o = (r.options || []).find((x) => JSON.stringify(x.value) === JSON.stringify(r.current));
  return o ? o.label : String(r.current);
}

function pickOption(r, value) {
  setup.picks[r.id] = value;
  rerenderSetup(`[data-rec="${CSS.escape(r.id)}"] input:checked`);
}

function recOptions(r) {
  const picked = Object.hasOwn(setup.picks, r.id) ? setup.picks[r.id] : r.current;
  return h("fieldset", { class: "setup-options" },
    h("legend", { class: "visually-hidden" }, `Choices for ${r.title}`),
    r.options.map((o, i) => {
      const input = h("input", { type: "radio", name: `opt-${r.id}`, value: String(i), disabled: !o.available,
        onchange: () => pickOption(r, o.value) });
      input.checked = JSON.stringify(o.value) === JSON.stringify(picked);
      return h("label", { class: o.available ? "setup-option" : "setup-option unavailable" }, input,
        h("span", { class: "setup-option-text" },
          h("span", { class: "setup-option-label" }, optionLabel(r, o)),
          o.note ? h("span", { class: "setup-option-note" }, o.note) : null));
    }));
}

function recCard(r) {
  const open = setup.customizing.has(r.id);
  const status = r.matches ? h("span", { class: "pill reviewed" }, "✓ Set")
    : r.needs_setup ? h("span", { class: "pill setup-todo" }, "Needs setting up") : null;
  return h("section", { class: "setup-rec", "data-rec": r.id },
    h("div", { class: "setup-rec-head" }, h("h3", {}, r.title), status),
    h("p", { class: "setup-choice" }, h("span", { class: "setup-badge" }, "Recommended for this Mac"),
      h("strong", {}, r.label)),
    h("p", { class: "setup-why" }, r.reason),
    r.matches || r.id === "disk" ? null : h("p", { class: "meta" }, `Now: ${currentLabel(r)}`),
    r.needs_setup ? h("p", {}, h("button", { type: "button", class: "btn small", onclick: () => openSettings() },
      "Set up a cloud model in Settings")) : null,
    r.options?.length ? h("button", { type: "button", class: "btn btn-quiet small setup-customize",
      "aria-expanded": String(open), onclick: () => {
        if (open) { setup.customizing.delete(r.id); delete setup.picks[r.id]; } else setup.customizing.add(r.id);
        rerenderSetup(`[data-rec="${CSS.escape(r.id)}"] .setup-customize`);
      } }, open ? "Hide the alternatives" : "Customize") : null,
    open ? recOptions(r) : null);
}

// The primary button of a step of recommendations: "Use recommended", or
// "Use these" once something was picked, or "Continue" when nothing would change.
// "Keep current" leads when something set on purpose differs, with "Use
// recommended" beside it (stepButtons).
function recsPrimary(recs, next) {
  const { primary, secondary } = stepButtons(recs, setup.picks);
  return {
    label: primary.label, run: (button) => applySetup(primary.changes, button, next),
    secondary: secondary && { label: secondary.label, run: (button) => applySetup(secondary.changes, button, next) },
  };
}

async function applySetup(changes, button, next) {
  if (Object.keys(changes).length) {
    try {
      const out = await working(button, api("/api/setup/apply", { changes }));
      setup.page = { ...setup.page, recommendations: out.recommendations };
      toast("Saved. Change it any time in Settings.", { short: true });
    } catch (err) {
      setup.error = `Not saved: ${err.message}`;
      rerenderSetup();
      return;
    }
  }
  setup.error = null;
  setupGo(next);
}

const SETUP_VIEWS = {
  you(p, next) { return youStep(p, next); },
  recommended(p, next) { return recommendedStep(p, next); },
  test(p, next) { return testStep(p, next); },
};

// What a choice is once the step's button is clicked (``changes``: what it
// sets; anything else stays as it is), and whether that is the recommendation.
function packValue(r, changes) {
  const value = Object.hasOwn(changes, r.id) ? changes[r.id] : r.current;
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const o = (r.options || []).find((x) => same(x.value, value));
  return { label: same(value, r.value) ? r.label : o ? o.label : currentLabel(r), recommended: same(value, r.value) };
}

// Step 2: all Palaver would set on this Mac as one package, taken with one
// click (the downloads start with it); Customize opens each choice with its
// alternatives. Login start and where meetings live are part of it.
function recommendedStep(p, next) {
  const hw = p.hardware;
  const recs = p.recommendations.filter((r) => r.id !== "disk");
  const disk = p.recommendations.find((r) => r.id === "disk");
  const d = p.downloads;
  const s = p.storage;
  const cloud = s.cloud.filter((c) => c.choice !== "local");
  const fits = d.free_disk_gb >= d.total_gb;
  const { primary, secondary } = stepButtons(recs, setup.picks);
  const autostart = h("input", { type: "checkbox", role: "switch", class: "switch-input", "data-key": "autostart",
    onchange: (e) => { setup.autostart = e.target.checked; } });
  autostart.checked = setup.autostart ?? true;
  return {
    lede: `What Palaver recommends for this ${hw.short} with ${hw.memory_gb} GB. Change any of it later in Settings.`,
    body: [
      hw.apple_silicon ? null : h("p", { class: "error" }, "Local models need Apple Silicon: on this Mac, notes need a cloud model."),
      setup.customizeAll ? h("div", { class: "setup-recs" }, recs.map(recCard))
        : h("ul", { class: "setup-pack" }, recs.map((r) => {
          const v = packValue(r, primary.changes);
          return h("li", { class: "setup-pack-item", "data-rec": r.id, title: r.reason },
            h("span", { class: "setup-pack-title" }, r.title),
            h("span", { class: "setup-pack-value" }, v.label,
              v.recommended ? null : h("span", { class: "meta" }, ` · recommended: ${r.label}`),
              v.recommended && r.needs_setup ? h("span", { class: "meta" }, " · needs setting up in Settings") : null));
        })),
      h("button", { type: "button", class: "btn btn-quiet small setup-customize-all", "aria-expanded": String(!!setup.customizeAll),
        onclick: () => { setup.customizeAll = !setup.customizeAll; rerenderSetup(".setup-customize-all"); } },
        setup.customizeAll ? "Show the summary" : "Customize"),
      h("div", { class: "gloss-card settings-card" },
        h("label", { class: "switch-row" }, h("span", { class: "switch-label" }, "Start Palaver at login"),
          autostart, h("span", { class: "switch-track", "aria-hidden": "true" })),
        h("p", { class: "meta" }, "Calls are only recorded while Palaver runs.")),
      h("p", { class: "meta" }, cloud.length
        ? `${cloud.map((c) => c.label).join(" and ")} use a cloud model; everything else runs on this Mac. Meetings are kept in ${s.recordings}.`
        : `Everything runs on this Mac: nothing leaves it. Meetings are kept in ${s.recordings}${s.audio_days ? `, their audio ${s.audio_days} days` : ""}.`),
      d.needed.length ? h("p", { class: fits ? "meta setup-downloads" : "meta setup-downloads error" },
        `${downloadsText(d.needed)} ${Math.round(d.free_disk_gb)} GB free on this Mac.${fits ? " They download in the background." : " Free up space first."}`) : null,
      disk ? h("p", { class: "meta error" }, disk.reason) : null,
      d.status.models.length ? downloadStatus(d.status) : null,
    ],
    primary: { label: primary.label, run: (button) => applyRecommended(primary.changes, button, next),
      secondary: secondary && { label: secondary.label, run: (button) => applyRecommended(secondary.changes, button, next) } },
  };
}

// The package's one click: the settings, login start, then the downloads they
// need. Stays on the step when the models can't download yet (disk).
async function applyRecommended(changes, button, next) {
  const want = setup.autostart ?? true;
  try {
    await working(button, (async () => {
      if (Object.keys(changes).length) await api("/api/setup/apply", { changes });
      if (want !== setup.page.storage.autostart) await api("/api/setup/autostart", { on: want });
      await loadSetup();
      const d = setup.page.downloads;
      if (d.needed.length && !d.status.models.length && d.free_disk_gb >= d.total_gb) {
        d.status = await api("/api/setup/downloads", { models: d.needed.map((m) => m.id) });
      }
    })());
  } catch (err) {
    setup.error = `Not saved: ${err.message}`;
    rerenderSetup();
    return;
  }
  setup.error = null;
  const d = setup.page.downloads;
  if (d.needed.length && !d.status.models.length) {  // a model that can't come yet: say why here
    rerenderSetup();
    return;
  }
  setupGo(next);
}

function youStep(p, next) {
  const prof = p.profile;
  if (!setup.seed) setup.seed = seedChecked(p.glossary);
  const renamed = h("p", { class: "meta setup-renamed", hidden: true },
    "Earlier meetings show your old name in their transcripts. Palaver still knows it is you.");
  const name = h("input", { class: "lm-input", id: "setup-name", value: prof.name || "", autocomplete: "name",
    "aria-describedby": "setup-name-from",
    oninput: (e) => { renamed.hidden = !prof.name || e.target.value.trim() === prof.name; } });
  const add = h("button", { type: "button", class: "btn small setup-add-terms", disabled: true,
    onclick: (e) => addSeedTerms(e.currentTarget) }, "Add 0 terms");
  const showCount = () => {
    const n = setup.seed.size;
    add.textContent = `Add ${n} ${n === 1 ? "term" : "terms"}`;
    add.disabled = n === 0;
  };
  const org = h("input", { class: "lm-input", id: "setup-org", value: prof.organization || "", autocomplete: "organization" });
  const from = { app: "As you set it in Palaver.", config: "From config.toml.", macOS: "From your macOS account." }[prof.name_from] || "";
  const cal = p.permissions.calendar;
  return {
    lede: "Your name is how you show up in transcripts; colleagues of your organization are recognized by it.",
    body: [
      h("div", { class: "gloss-card settings-card setup-form" },
        h("label", { class: "lm-field", for: "setup-name" }, h("span", { class: "lm-label" }, "Your name"), name),
        h("p", { class: "meta", id: "setup-name-from" }, from),
        renamed,
        h("label", { class: "lm-field", for: "setup-org" }, h("span", { class: "lm-label" }, "Your organization"), org),
        h("p", { class: "meta" }, prof.organization ? "From your own address in the calendar." : "From your email domain, once the calendar is connected.")),
      h("h2", {}, "Calendar"),
      h("ul", { class: "setup-checks" }, calendarRow(p)),
      h("p", { class: "meta" }, "Palaver reads each meeting's title and invitees from the macOS calendar, on this Mac, to name meetings and the people in them. It never changes anything in your calendar."),
      h("h2", {}, "Names to spell right"),
      p.glossary.length
        ? h("fieldset", { class: "setup-seed" },
          h("legend", { class: "meta" }, "From your calendar. Tick the ones to add to the glossary, so transcripts spell them right from the first meeting."),
          p.glossary.map((g) => {
            const box = h("input", { type: "checkbox", value: g.term, onchange: (e) => {
              if (e.target.checked) setup.seed.add(g.term); else setup.seed.delete(g.term);
              showCount();
            } });
            box.checked = setup.seed.has(g.term);
            return h("label", { class: "setup-seed-term" }, box, h("span", {}, g.term),
              h("span", { class: "meta" }, { person: "person", organization: "organization", title: "in titles" }[g.kind]));
          }),
          h("div", { class: "setup-seed-actions" }, (showCount(), add)))
        : h("p", { class: "meta" }, cal?.state === "granted" ? "Your calendar has no names to add right now."
          : "Once the calendar is connected, names from it can be added to the glossary here."),
    ],
    primary: { label: "Save", run: (button) => saveProfile(name.value, org.value, button, next) },
  };
}

async function saveProfile(name, org, button, next) {
  try {
    await working(button, api("/api/setup/profile", { name, organization: org }));
  } catch (err) {
    setup.error = `Not saved: ${err.message}`;
    rerenderSetup();
    return;
  }
  setup.error = null;
  setup.page = { ...setup.page, profile: { ...setup.page.profile, name, organization: org, name_from: "app" } };
  setupGo(next);
}

// Only an explicit click adds the calendar's names to the glossary.
async function addSeedTerms(button) {
  const terms = [...setup.seed];
  if (!terms.length) return;
  let out;
  try {
    out = await working(button, api("/api/setup/glossary", { terms }));
  } catch (err) {
    errorToast(`Not added: ${err.message}`, { action: { label: "Try again", run: () => addSeedTerms(button) } });
    return;
  }
  setup.page.glossary = setup.page.glossary.filter((g) => !setup.seed.has(g.term));
  setup.seed.clear();
  rerenderSetup();
  const label = `${out.added} ${out.added === 1 ? "term" : "terms"} added to the glossary`;
  if (out.added && out.undo) remember(label, async () => { await api("/api/undo", { token: out.undo }); });
  else toast(label, { short: true });
}

async function setAutostart(on, input) {
  try {
    const out = await api("/api/setup/autostart", { on });
    setup.page.storage.autostart = out.autostart;
    toast(out.autostart ? "Palaver starts at login." : "Palaver no longer starts at login.", { short: true });
  } catch (err) {
    input.checked = !on;
    errorToast(`Not changed: ${err.message}`);
  }
}

function downloadStatus(status) {
  const total = downloadProgress(status);
  return h("div", { class: "setup-progress", id: "setup-downloads", role: "status" },
    h("div", { class: "setup-bar", "aria-hidden": "true" }, h("span", { style: `width: ${Math.round(total * 100)}%` })),
    h("ul", { class: "setup-checks" }, status.models.map((m) => {
      const row = checkRow(m.label,
        m.state === "done" ? "ok" : m.state === "failed" ? "fail" : "warn",
        m.state === "done" ? "downloaded" : m.state === "failed" ? `failed: ${m.error}`
          : m.state === "queued" ? "waiting" : `${gbText(m.done_gb)} of ${gbText(m.disk_gb)}`, "");
      if (m.state === "failed") {
        row.append(h("button", { type: "button", class: "btn small setup-retry", "data-model": m.id,
          onclick: (e) => startDownloads([m.id], e.currentTarget) }, "Try again"));
      }
      return row;
    })),
    status.running ? h("p", { class: "meta" }, "Downloading in the background: you can go on.") : null);
}

async function startDownloads(ids, button) {
  try {
    const status = await working(button, api("/api/setup/downloads", { models: ids }));
    setup.page.downloads.status = status;
  } catch (err) {
    setup.error = `The downloads did not start: ${err.message}`;
  }
  rerenderSetup();
  watchSetup();
}

function testStep(p, next) {
  const t = setup.page.test;
  const done = t.state === "done" || t.state === "failed" || t.state === "aborted";
  const primary = t.state === "recording" ? { label: "Stop", run: (b) => runTest("stop", b) }
    : t.state === "checking" ? { label: "Checking…", disabled: true }
      : done ? { label: "Done", run: () => setupGo(next) }
        : { label: "Start test recording", run: (b) => runTest("start", b) };
  const downloads = setup.page.downloads.status;
  return {
    lede: "Optional: a short recording to check both tracks. It plays no sound. Click Start, say one sentence in your normal voice, then click Stop. The recording is deleted after the check.",
    body: [
      h("div", { class: "setup-test", id: "setup-live", role: "status" },
        t.state === "recording" ? h("span", { class: "writing-dot", "aria-hidden": "true" }) : null,
        h("span", {}, testRecordingText(t) || (done ? "" : "Not started.")),
        done ? h("button", { type: "button", class: "btn small", onclick: (e) => runTest("start", e.currentTarget) }, "Test again") : null),
      t.checks ? h("ul", { class: "setup-checks" }, t.checks.map((c) => checkRow(c.name, c.status, c.detail, c.fix))) : null,
      h("p", { class: "meta" }, "Palaver records your microphone and the sound of your Mac as two tracks. As nothing plays during the test, the second track stays quiet: what counts is that it was recorded. macOS asks for both the first time."),
      downloads.models.length ? downloadStatus(downloads) : null,
    ],
    primary,
    skip: t.state === "idle" ? "Skip the test" : null,
  };
}

async function runTest(action, button) {
  try {
    setup.page.test = await working(button, api("/api/setup/test", { action }));
    setup.error = null;
  } catch (err) {
    setup.error = `The test did not ${action}: ${err.message}`;
  }
  rerenderSetup(".setup-actions .btn.primary");
  watchSetup();
}

// While downloads run or the test records, show how it goes.
function watchSetup() {
  clearTimeout(setup.timer);
  if (state.view !== "setup" || !setup.page) return;
  const downloading = ["recommended", "test"].includes(setup.step) && setup.page.downloads.status.running;
  const testing = setup.step === "test" && ["recording", "checking"].includes(setup.page.test.state);
  const calendar = setup.step === "you" && setup.page.permissions?.calendar?.state !== "granted";
  if (!downloading && !testing && !calendar) return;
  setup.timer = setTimeout(async () => {
    if (state.view !== "setup") return;
    if (!downloading && !testing) {
      try {
        const now = await api("/api/setup/calendar");
        if (now.state !== setup.page.permissions.calendar?.state) {
          await calendarConnected();
          watchSetup();
          return;
        }
      } catch { /* the next round looks again */ }
      watchSetup();
      return;
    }
    try {
      if (downloading) setup.page.downloads.status = await api("/api/setup/downloads");
      if (testing) {
        const before = setup.page.test.state;
        setup.page.test = await api("/api/setup/test");
        if (before !== setup.page.test.state) {
          rerenderSetup(".setup-actions .btn.primary");
          watchSetup();
          return;
        }
      }
    } catch { /* the next round tries again */ }
    const progress = document.getElementById("setup-downloads");
    if (downloading && progress) progress.replaceWith(downloadStatus(setup.page.downloads.status));
    const live = document.getElementById("setup-live");
    if (testing && live) live.replaceWith(testStep(setup.page, null).body[0]);
    if (downloading && !setup.page.downloads.status.running) rerenderSetup();
    watchSetup();
  }, testing ? 500 : downloading ? 1000 : 1500);
}

function stepper(at) {
  return h("ol", { class: "setup-steps", "aria-label": "Steps" }, SETUP_STEPS.map((s, i) =>
    h("li", { class: i < at ? "done" : i === at ? "current" : null },
      h("button", { type: "button", title: s.title, "aria-label": `${s.title}${i === at ? " (this step)" : ""}`,
        "aria-current": i === at ? "step" : null, disabled: i === at,
        onclick: () => openSetup(s.id, "replace") }))));
}

function renderSetup() {
  const at = Math.max(0, SETUP_STEPS.findIndex((s) => s.id === setup.step));
  const step = SETUP_STEPS[at];
  const next = setupStepAfter(step.id);
  const prev = setupStepBefore(step.id);
  const view = setup.page ? SETUP_VIEWS[step.id](setup.page, next) : null;
  const primary = view?.primary;
  const skip = view && view.skip !== null ? (view.skip || "Skip this step") : null;
  const article = h("article", { class: "meeting setup", "data-step": step.id },
    h("div", { class: "setup-top" },
      h("p", { class: "setup-count" }, `Setup · step ${at + 1} of ${SETUP_STEPS.length}`),
      h("button", { type: "button", class: "btn btn-quiet small", onclick: (e) => finishSetup("skipped", e.currentTarget) },
        "Skip setup")),
    stepper(at),
    h("h1", { tabindex: "-1" }, step.title),
    view?.lede ? h("p", { class: "lede" }, view.lede) : null,
    setup.error ? h("p", { class: "error", role: "alert" }, setup.error) : null,
    h("div", { class: "setup-body" }, ...(view ? view.body : [h("p", { class: "meta" }, "Looking at this Mac…")])),
    h("div", { class: "setup-actions" },
      prev ? h("button", { type: "button", class: "btn btn-quiet", onclick: () => setupGo(prev) }, "Back") : null,
      h("span", { class: "setup-spacer" }),
      skip ? h("button", { type: "button", class: "btn btn-quiet", onclick: () => setupGo(next) }, skip) : null,
      primary?.secondary ? h("button", { type: "button", class: "btn setup-secondary",
        onclick: (e) => primary.secondary.run(e.currentTarget) }, primary.secondary.label) : null,
      primary ? h("button", { type: "button", class: "btn primary", disabled: !!primary.disabled,
        onclick: (e) => primary.run?.(e.currentTarget) }, primary.label) : null));
  $("#main").replaceChildren(article);
}

// Rebuild the step and give focus back to what was used.
function rerenderSetup(focus) {
  if (state.view !== "setup") return;
  renderSetup();
  if (focus) $(`#main ${focus}`)?.focus();
}

// On start: the first time, the assistant opens (unless the window was opened
// on a meeting); later, a new Mac or a missing model is said once per session.
const SETUP_SAID = "palaver.setup.offerSaid";
async function checkSetupOffer() {
  const answer = await api("/api/setup/offer").catch(() => null);
  const offer = answer?.offer;
  if (!offer) return;
  const place = placeOf(location.hash);
  if (offer.why === "first") {
    if (place.view === "today" || (place.view === "meetings" && !place.id)) openSetup(null, "replace");
    return;
  }
  try {
    if (sessionStorage.getItem(SETUP_SAID) === offer.why) return;
    sessionStorage.setItem(SETUP_SAID, offer.why);
  } catch { /* said again after a reload */ }
  const text = setupOfferText(offer, offer.labels || {});
  if (!text || place.view === "setup") return;
  const step = "recommended";  // a new Mac, a missing model: what to run here
  toast(text, { action: { label: offer.why === "missing" ? "Download…" : "Review", run: () => openSetup(step) } });
}

// --- Today, the start page (UI spec, phase 2) -----------------------------------------

const TODAY_CARDS = 8;  // "Needs you" shows this many; "Review all in order" goes through all of them

// The list without a meeting chosen (no recordings yet, or the Meetings tab before any was opened).
async function openMeetingsList(how = "push") {
  const here = leaveMeeting("meetings", "#/meetings", how);
  if (movedOn(here)) return;
  $("#main").replaceChildren(h("div", { class: "empty" },
    state.meetings.length ? "Pick a meeting on the left." : "No recordings yet. Meetings appear here when a call ends."));
}

async function openToday(how = "push") {
  const here = leaveMeeting("today", "#/today", how);
  renderToday();  // at once, with what the list knows
  await refreshToday();
  if (movedOn(here)) return;
}

// What each part of Today shows now, as built last: a part is rebuilt only when this changes.
let todayShown = {};
const todaySignatures = () => {
  const live = state.todayLive;
  const now = new Date();
  const next = state.upcoming.find((x) => new Date(x.end) > now);
  const rec = recordingNow(state.meetings);
  return {
    record: JSON.stringify(rec ? [rec.id, rec.start, !!live] : null),
    live: JSON.stringify(live ? [live.id, live.live?.until, live.transcript.slice(-4), live.speakers.map((x) => x.display)] : null),
    next: JSON.stringify(next ? [next, startsInText(next.start, next.end, now)] : null),
    recent: JSON.stringify([state.meetings.slice(0, 6), state.meetings.length > 6,
      state.meetings.slice(0, 6).map((m) => needsOf(m.id)), [...state.writing.keys()]]),
  };
};
const TODAY_BUILD = { record: () => recordCard("today"), live: () => liveNowCard(), next: () => nextMeetingCard(), recent: () => recentSection() };

// The call being recorded (its live text and speakers), then the parts of Today that changed.
async function refreshToday() {
  const rec = state.meetings.find((m) => m.status === "recording");
  const live = rec ? await api(`/api/meetings/${encodeURIComponent(rec.id)}`).catch(() => state.todayLive) : null;
  state.todayLive = live?.live ? live : null;
  patchToday();
}

// The parts of Today whose content changed since built (Recent's dots follow the needs as they arrive).
function patchToday() {
  if (state.view !== "today") return;
  const now = todaySignatures();
  for (const [part, sig] of Object.entries(now)) {
    if (todayShown[part] === sig) continue;
    todayShown[part] = sig;
    swapPart(TODAY_BUILD[part]());
  }
}

// A part of Today replaced in place; the focus stays on what it was on (its card and label), unless the user types there.
function swapPart(el) {
  const old = $(`#main .today .${el.classList[0]}`);
  if (!old) return;
  const a = document.activeElement;
  if (old.contains(a) && isEditable(a)) return;
  const label = old.contains(a) ? a.getAttribute("aria-label") || a.textContent : null;
  old.replaceWith(el);
  if (label != null) [...el.querySelectorAll("button, a, input")].find((x) => (x.getAttribute("aria-label") || x.textContent) === label)
    ?.focus({ preventScroll: true });
}

function renderToday() {
  todayShown = todaySignatures();
  $("#main").replaceChildren(h("article", { class: "today" },
    h("header", { class: "today-head" }, h("p", { class: "eyebrow" }, dayFmt.format(new Date())), h("h1", {}, "Today")),
    h("div", { class: "today-cols" },
      h("div", { class: "today-main" }, updateCardSection(), recordCard("today"), liveNowCard(true), needsSection(true)),
      h("div", { class: "today-side" }, nextMeetingCard(), recentSection()))));
}

// A new release, first on Today until it is installed: not only a notification one may miss.
function updateCardSection() {
  const card = updateCard(state.update);
  if (!card) return h("section", { class: "update-card", hidden: true });
  return h("section", { class: "update-card", "aria-label": "Update" },
    h("div", { class: "update-card-text" }, h("h2", {}, card.title), h("p", {}, card.text)),
    h("button", { type: "button", class: "tbtn", onclick: () => openUpdate() }, "What's new"),
    h("button", { type: "button", class: "tbtn primary", onclick: (e) => updateAction("install", e.currentTarget) }, "Update Now"));
}

// "Live now": large, only while a call is recorded; the newest lines and who speaks.
function liveNowCard(first = false) {
  const m = state.todayLive;
  if (!m) return h("section", { class: "live-now", hidden: true });
  const appears = first || $("#main .today .live-now")?.hidden;  // fades in when it appears, not with each new line
  const color = colorOf(m);
  const start = m.start ? new Date(m.start) : null;
  const lines = m.transcript.slice(-4);
  return h("section", { class: `live-now${appears ? " new" : ""}`, "aria-label": "Live now" },
    h("div", { class: "live-now-head" },
      h("span", { class: "pill live-badge" }, "Live now"),
      h("span", { class: "meta" }, [start ? `since ${timeFmt.format(start)}` : null,
        m.live?.until ? `transcribed up to ${clock(m.live.until)}` : null].filter(Boolean).join(" · ")),
      h("div", { class: "live-now-actions" },
        h("button", { type: "button", class: "tbtn", onclick: () => openMeeting(m.id) }, "Open"),
        m.finishing ? h("span", { class: "meta" }, "Stopped, finishing…")
          : h("button", { type: "button", class: "tbtn", onclick: (e) => stopRecording(m.id, e.currentTarget) },
            h("span", { class: "stop-mark", "aria-hidden": "true" }), "Stop"))),
    h("h2", {}, titleOf(m)),
    h("div", { class: "live-speakers" }, m.speakers.map((s) => personToken(s.display || s.name || labelDisplay(s.label),
      color(s.label), { named: !!s.name }))),
    lines.length ? h("div", { class: "live-lines" }, lines.map((t) => h("p", { class: "live-line", style: `--c:${color(t.label)}` },
      h("span", { class: "speaker" }, t.speaker), " ", t.text)))
      : h("p", { class: "lede" }, "Nothing transcribed yet."));
}

// The next meeting in the calendar, and its prep.
function nextMeetingCard() {
  const now = new Date();
  const e = state.upcoming.find((x) => new Date(x.end) > now);
  if (!e) {
    return h("section", { class: "next-meeting quiet", "aria-label": "Next meeting" },
      h("p", { class: "next-when" }, "Next meeting"), h("p", { class: "lede" }, "Nothing more in your calendar."));
  }
  const start = new Date(e.start);
  const soon = startsInText(e.start, e.end, now);
  return h("section", { class: "next-meeting", "aria-label": "Next meeting" },
    h("p", { class: "next-when" }, soon ? `${soon} · ${timeFmt.format(start)}` : `${dayLabel(start)}, ${timeFmt.format(start)}`),
    h("h2", {}, e.title || "Meeting"),
    e.projects.length ? h("p", { class: "next-projects" }, e.projects.map((p) => p.name).join(" · ")) : null,
    h("button", { type: "button", class: "tbtn", onclick: () => openPrep(e.key) }, "Prepare →"));
}

function recentSection() {
  const latest = state.meetings.slice(0, 6);
  return h("section", { class: "recent", "aria-label": "Recent" },
    h("h2", { class: "today-h" }, "Recent"),
    latest.length ? latest.map((m) => meetingItem(m, null, { withDay: true })) : h("p", { class: "lede" }, "No recordings yet."),
    state.meetings.length > latest.length
      ? h("button", { type: "button", class: "link small", onclick: () => goTo("meetings") }, "All meetings →") : null);
}

// "Needs you": a card per open question, answered in place; a meeting with
// none asks once whether it came out right. "Review all in order" goes through them.
function needsSection(first = false) {
  if (!state.needs) {
    return h("section", { class: "needs", "aria-label": "Needs you" }, h("h2", { class: "today-h" }, "Needs you"),
      h("p", { class: "lede" }, "Looking for what needs you…"));
  }
  const n = state.needs.count;
  const { cards, more } = needCards(state.needs, TODAY_CARDS);
  return h("section", { class: "needs", "aria-label": "Needs you" },
    h("div", { class: "today-row" },
      h("h2", { class: "today-h" }, n ? `Needs you · ${n}` : "Needs you"),
      n ? h("button", { type: "button", class: "btn primary small", onclick: () => openReview() }, "Review all in order") : null),
    cards.length ? h("div", { class: "need-cards" }, cards.map((c) => needCard(c, first)))
      : h("p", { class: "lede" }, "Nothing waits on you. Finished meetings show up here for a quick check."),
    more ? h("p", { class: "meta" }, `${more} more in the review`) : null);
}

const NEED_MARK = { unnamed: "?", speaker: "?", project: "#", which_event: "◷", event: "◷", no_event: "◷", cut: "✂",
  review: "✓" };

function needCard({ key, meeting, item }, fresh = true) {
  const q = needQuestion(item);
  const start = meeting.start ? new Date(meeting.start) : null;
  const card = h("div", { class: `need-card need-${item.kind}${fresh ? " new" : ""}`, "data-meeting": meeting.id, "data-key": key });
  card.append(
    h("span", { class: "need-mark", "aria-hidden": "true" }, NEED_MARK[item.kind]),
    h("div", { class: "need-body" },
      h("button", { type: "button", class: "link need-meeting", onclick: () => openMeeting(meeting.id) },
        meeting.title || fallbackTitle(meeting)),
      start ? h("span", { class: "need-when" }, ` · ${dayLabel(start)}, ${timeFmt.format(start)}`) : null,
      h("p", { class: "need-q" }, needText(q.text, item)),
      q.detail ? h("p", { class: "need-detail" }, q.detail) : null),
    h("div", { class: "need-answers" }, needAnswers(card, meeting, item)));
  return card;
}

// "Is Speaker 3 Carla?": the name it asks about as the person looks everywhere.
function needText(text, item) {
  if (item.kind !== "speaker" || !item.name) return text;
  const at = text.lastIndexOf(item.name);
  if (at < 0) return text;
  return [text.slice(0, at), personToken(item.name, personColor(item.name), { small: true }), text.slice(at + item.name.length)];
}

function needAnswers(card, meeting, item) {
  const title = meeting.title || fallbackTitle(meeting);
  const answer = (label, run, cls = "btn small") => h("button", { type: "button", class: cls,
    onclick: (e) => answerNeed(card, e.currentTarget, run) }, label);
  const person = (name) => personToken(name, personColor(name), { small: true });
  const go = (label, run) => h("button", { type: "button", class: "btn btn-quiet small", onclick: run }, label);
  switch (item.kind) {
    case "unnamed": return [
      item.clip ? playVoiceButton(`Play voice of ${item.display}`, () => playClip(meeting.id, item.clip),
        clipKey(meeting.id, item.clip)) : null,
      ...(item.guesses || []).map((name) => answer(person(name), () => nameNeed(meeting, item, name), "chip need-chip person-chip")),
      h("input", { class: "name-input need-name", list: "names", placeholder: "Name", spellcheck: "false",
        "aria-label": `Name for ${item.display}`,
        onkeydown: (e) => {
          const name = e.target.value.trim();
          if (e.key === "Enter" && name) answerNeed(card, e.target, () => nameNeed(meeting, item, name));
          if (e.key === "Escape") { e.target.value = ""; e.target.blur(); }
        } }),
      answer("Don't Know", () => unknownNeed(meeting, item), "btn btn-quiet small")];
    case "speaker": return [answer("Yes", () => nameNeed(meeting, item, item.name)),
      answer("No", () => nameNeed(meeting, item, ""), "btn btn-quiet small")];
    case "project": return [answer("Yes", () => projectNeed(meeting, item, false)),
      answer("No", () => projectNeed(meeting, item, true), "btn btn-quiet small")];
    case "which_event": return [...item.choices.map((c) => answer(c.title, () => eventNeed(meeting, c.key, c.title), "chip need-chip")),
      answer("None of these", () => eventNeed(meeting, null, null, `“${title}” was an ad-hoc call`), "btn btn-quiet small")];
    case "event": return [answer("Yes", () => eventNeed(meeting, "current", item.title)), go("Change…", () => pickEvent(meeting.id))];
    case "no_event": return [go("Pick event…", () => pickEvent(meeting.id)),
      answer("Ad-hoc call", () => eventNeed(meeting, null, null, `“${title}” was an ad-hoc call`), "btn btn-quiet small")];
    case "cut": return [go(`Cut at ${clock(item.at)}…`, () => cutFromToday(meeting.id, item.at)),
      answer("Not this", () => cutNeed(meeting, title), "btn btn-quiet small")];
    default: return [answer("Mark reviewed", () => reviewNeed(meeting, title))];
  }
}

// An answer: the card leaves, the toast says what changed and can undo it; the card comes back with the undo.
async function answerNeed(card, control, run) {
  let done;
  try {
    done = await working(control, Promise.resolve().then(run));
  } catch (err) {
    errorToast(`Not saved: ${err.message}`, { action: { label: "Try again", run: () => answerNeed(card, control, run) } });
    return;
  }
  const key = card.dataset.key;
  if (card.isConnected) await leave(card);
  remember(done.text, async () => {
    await done.undo();
    refreshTouched([card.dataset.meeting]);
    await afterNeed();
    const back = $(`#main .need-card[data-key="${CSS.escape(key)}"]`);
    if (back) flash(back);
  });
  await afterNeed();
}

// After an answer or its undo: the list, the review and the needs; Today's cards change one by one (patchNeeds).
async function afterNeed() {
  await Promise.all([loadList(), loadReview(), loadNames()]);
}

// Today's "Needs you" brought up to date in place: cards gone leave, new ones
// come in (and fade in); the others stay as they are, with what is typed in
// them and the focus.
function patchNeeds() {
  const old = $("#main .today .needs");
  if (!old) return;
  const fresh = needsSection();
  const list = old.querySelector(".need-cards");
  const freshList = fresh.querySelector(".need-cards");
  if (!list || !freshList) {
    swapPart(fresh);
    return;
  }
  const a = document.activeElement;
  const typed = isEditable(a) && list.contains(a) ? { el: a, start: a.selectionStart, end: a.selectionEnd } : null;
  const kept = new Map([...list.children].map((c) => [c.dataset.key, c]));
  const wanted = new Set([...freshList.children].map((c) => c.dataset.key));
  for (const [key, c] of kept) if (!wanted.has(key)) c.remove();
  let prev = null;
  for (const c of [...freshList.children]) {
    let node = kept.get(c.dataset.key);
    if (!node) {
      node = c;
      node.classList.add("new");
    } else {
      node.classList.remove("new");
    }
    const at = prev ? prev.nextSibling : list.firstChild;
    if (node !== at) list.insertBefore(node, at);
    prev = node;
  }
  // The heading row and the "more" line: replaced only when they say something else.
  const row = old.querySelector(".today-row");
  const freshRow = fresh.querySelector(".today-row");
  if (row && freshRow && row.textContent !== freshRow.textContent) row.replaceWith(freshRow);
  old.querySelector(":scope > .meta")?.remove();
  const more = fresh.querySelector(":scope > .meta");
  if (more) old.append(more);
  if (typed && typed.el.isConnected && document.activeElement !== typed.el) {
    typed.el.focus({ preventScroll: true });
    typed.el.setSelectionRange(typed.start, typed.end);
  } else if (a && a !== document.activeElement && a.isConnected) a.focus({ preventScroll: true });
}

async function nameNeed(meeting, item, name) {
  const guess = item.kind === "speaker" ? { label: item.label, name: item.name, named_by: "inferred" }
    : { label: item.label, name: null, named_by: null };
  const text = namingText(guess, name) ?? `${item.display} is ${name}`;
  const m = await speakersApi(meeting.id, "speakers", { label: item.label, name });
  return { text, undo: m.undo ? () => api("/api/undo", { token: m.undo })
    : () => speakersApi(meeting.id, "speakers", { label: item.label, name: "" }) };
}

async function unknownNeed(meeting, item) {
  const r = await speakersApi(meeting.id, "unknown", { label: item.label, on: true });
  return { text: unknownText(item.display, true), undo: () => api("/api/undo", { token: r.undo }) };
}

async function projectNeed(meeting, item, remove) {
  const m = await api(`/api/meetings/${encodeURIComponent(meeting.id)}/projects`, { project: item.project, remove });
  return { text: remove ? `Removed from ${item.name}` : `Confirmed ${item.name}`, undo: () => api("/api/undo", { token: m.undo }) };
}

async function eventNeed(meeting, key, title, text = null) {
  const r = await api(`/api/meetings/${encodeURIComponent(meeting.id)}/event`, { key });
  return { text: text || eventChangeText(key, title), undo: () => api("/api/undo", { token: r.undo }) };
}

async function cutNeed(meeting, title) {
  const path = `/api/meetings/${encodeURIComponent(meeting.id)}/cut-suggestion`;
  await api(path, { dismiss: true });
  return { text: `No cut suggested for “${title}” any more`, undo: () => api(path, { dismiss: false }) };
}

async function reviewNeed(meeting, title) {
  const path = `/api/meetings/${encodeURIComponent(meeting.id)}/reviewed`;
  await api(path, { done: true });
  return { text: `“${title}” is marked reviewed.`, undo: () => api(path, { done: false }) };
}

async function pickEvent(id) {
  await openMeeting(id);
  await openEventPicker(id);
  document.querySelector("#main .event-picker")?.scrollIntoView({ block: "nearest" });
}

async function cutFromToday(id, at) {
  await openMeeting(id);
  if (state.meeting?.id === id) openCut(at);
}

// The review, at meeting ``id``.
async function reviewMeeting(id) {
  await loadReview();
  await openReview(Math.max(0, state.review.findIndex((x) => x.id === id)));
}

// The strip at the top of a meeting that needs something: what, and the way to the review.
function renderNeedsStrip(m) {
  const s = needsOf(m.id);
  if (!s) return h("div", { class: "needs-strip", hidden: true });
  // Each part takes you to the control that answers it, on this page.
  return h("div", { class: "needs-strip", role: "note" },
    h("span", { class: "needs-dot", "aria-hidden": "true" }),
    s.lead ? h("b", {}, s.lead) : null,
    h("span", { class: "needs-parts" }, s.parts.flatMap((text, i) => [i ? h("span", { "aria-hidden": "true" }, " · ") : null,
      h("button", { type: "button", class: "needs-part", title: "Show it", onclick: () => showNeed(m, s.targets[i]) }, text)]
      .filter(Boolean))),
    // Reviewed already: what is new since is answered here, on the page.
    m.reviewed ? null : h("button", { type: "button", class: "btn small", onclick: () => reviewMeeting(m.id) }, "Review"));
}

// The control on the meeting page that answers a need (needsSummary's targets).
function needControl(target) {
  const main = $("#main");
  const lane = target.label != null ? laneGroup(target.label) : null;
  switch (target.kind) {
    case "event": return main.querySelector(".event-link button");
    case "cut": return main.querySelector(".cut-suggest button");
    case "unnamed": return lane?.querySelector(".name-input");
    case "speaker": return lane?.querySelector(".inferred-row .chip") || lane?.querySelector(".name-input");
    case "project": return main.querySelector(`.project-chip[data-project="${CSS.escape(String(target.project ?? ""))}"] .chip-btn`);
    default: return null;
  }
}

// From the strip to the control: scrolled into view, focused, flashed once.
// A voice folded away as brief unfolds; no event chip to answer opens the picker.
async function showNeed(m, target) {
  let el = needControl(target);
  if (!el && target.kind === "unnamed" && !state.showBrief) {
    state.showBrief = true;
    renderMeeting();
    el = needControl(target);
  }
  if (!el && target.kind === "event") {
    await openEventPicker(m.id);
    el = $("#main .event-picker .event-option") || $("#main .event-picker .btn");
  }
  if (!el) return;
  const reduce = typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  el.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
  el.focus({ preventScroll: true });
  flash(el.closest(".lane-group, .project-chip, .event-link, .event-picker, .cut-suggest") || el);
}

// New needs from the server: the counter, and the strip or Today's cards where they show.
function showNeeds(before, relist = false) {
  const count = navCount(state.needs);
  const badge = $('.views [data-view="today"] .nav-count');
  badge.hidden = !count;
  badge.textContent = count || "";
  badge.title = count ? `${state.needs.count} ${state.needs.count === 1 ? "meeting needs" : "meetings need"} you` : "";
  if (JSON.stringify(before) === JSON.stringify(state.needs)) return;
  if (relist) renderList();  // the dots
  if (state.view === "today") {
    patchNeeds();
    patchToday();  // Recent's dots
  }
  const strip = $("#main .meeting > .needs-strip");
  if (strip && state.view === "meetings" && state.meeting) strip.replaceWith(renderNeedsStrip(state.meeting));
}

// --- Report a Problem (#59) --------------------------------------------------------------

// The form: a bug or a wish, what happened, the meeting it is about (the one
// open or opened last; none is fine) and its audio (off: it is large). The
// server writes one zip to the Desktop and shows it in Finder; nothing is
// uploaded. ``said``: the error's words when the tester came from one.
async function openReport(meeting = null, said = null, how = "push") {
  const open = state.meeting?.id ?? null;  // before leaving the meeting forgets it
  const here = leaveMeeting("report", hashOf({ view: "report", meeting }), how);
  if (!state.meetings.length) await loadList();
  if (movedOn(here)) return;
  state.report = { kind: "bug", text: reportDraft(said), audio: false, done: null, error: null,
    meeting: reportMeeting(meeting, { open, last: lastMeeting(), meetings: state.meetings }) };
  renderReport();
  $("#main .report-text")?.focus();
}

function renderReport() {
  const r = state.report;
  const audioBox = h("input", { type: "checkbox", class: "report-audio-input", disabled: !r.meeting,
    onchange: (e) => { r.audio = e.target.checked; } });
  audioBox.checked = r.audio && !!r.meeting;
  const kind = (value, label, note) => {
    const input = h("input", { type: "radio", name: "report-kind", value, onchange: () => { r.kind = value; } });
    input.checked = r.kind === value;
    return h("label", { class: "setup-option" }, input,
      h("span", { class: "setup-option-text" }, h("span", { class: "setup-option-label" }, label),
        h("span", { class: "setup-option-note" }, note)));
  };
  const text = h("textarea", { class: "report-text", rows: "7", "aria-label": "What happened?",
    placeholder: "What did you do, what did you expect, and what happened instead?",
    oninput: (e) => { r.text = e.target.value; } });
  text.value = r.text;
  const meetings = [...state.meetings].sort((a, b) => (a.id < b.id ? 1 : -1));
  const select = h("select", { class: "report-meeting", "aria-label": "The meeting it is about",
    onchange: (e) => {
      r.meeting = e.target.value || null;
      audioBox.disabled = !r.meeting;
      if (!r.meeting) audioBox.checked = r.audio = false;
    } },
  h("option", { value: "" }, "None"),
  meetings.map((x) => {
    const e = meetingEntry(x);
    return h("option", { value: x.id }, e.detail ? `${e.label} · ${e.detail}` : e.label);
  }));
  select.value = r.meeting || "";
  const page = h("article", { class: "meeting people settings report-page" },
    h("h1", {}, "Report a Problem"),
    h("p", { class: "meta" }, "Palaver puts everything needed to look into it in one zip on your Desktop: its logs, ",
      "the settings without passwords or keys, this Mac's setup, and the meeting you choose. Nothing is uploaded: ",
      "send the zip yourself, e.g. in Slack or Mail."),
    h("form", { class: "gloss-card settings-card report-form", onsubmit: (e) => {
      e.preventDefault();
      sendReport(e.submitter || e.target.querySelector("[type=submit]"));
    } },
      h("fieldset", { class: "setup-options report-kind" }, h("legend", { class: "report-label" }, "This is"),
        kind("bug", "A problem", "Something went wrong or does not work as it should"),
        kind("wish", "A wish", "Something Palaver should do, or do differently")),
      h("label", { class: "report-field" }, h("span", { class: "report-label" }, "What happened?"), text),
      h("label", { class: "report-field" }, h("span", { class: "report-label" }, "The meeting it is about"), select),
      h("label", { class: "report-audio" }, audioBox, h("span", {}, "Include this meeting's audio"),
        h("span", { class: "meta" }, "Large; only when it is about how something sounds or was heard")),
      h("div", { class: "report-actions" },
        h("button", { type: "submit", class: "btn primary" }, "Create Report")),
      r.error ? h("p", { class: "error", role: "alert" }, r.error) : null,
      r.done ? h("p", { class: "report-done", role: "status" }, "Saved to ", h("strong", {}, r.done.shown),
        ` (${r.done.size_text}) and shown in Finder. Send it to the maintainer.`) : null));
  $("#main").replaceChildren(page);
}

async function sendReport(button) {
  const r = state.report;
  if (!r || r.sending) return;
  r.sending = true;
  r.error = null;
  const body = { kind: r.kind, text: r.text, meeting: r.meeting, audio: !!(r.meeting && r.audio) };
  try {
    const answer = await working(button, api("/api/report", body));
    r.done = answer;
    toast(reportDoneText(answer));
  } catch (err) {
    r.error = `The report was not written: ${err.message}`;
    usage.count("error", null, { text: r.error.slice(0, 200), from: "report" });
  } finally {
    r.sending = false;
  }
  if (state.view === "report" && state.report === r) renderReport();
}

// An error in a toast: "Try again" where the caller has one, and "Report…",
// which starts a report with the error's words; counted for the usage log.
function errorToast(text, opts = {}) {
  usage.count("error", null, { text: String(text).slice(0, 200), from: state.view });
  const meeting = state.view === "meetings" ? state.meeting?.id ?? null : null;
  toast(text, { ...opts, actions: [...(opts.actions || []), { label: "Report…", run: () => openReport(meeting, text) }] });
}

// "Report a Problem…" anywhere: ⌘K, Help in the window's menu bar, Settings, the menu bar icon's menu.
const APP_ACTIONS = tracked("app", { reportProblem: () => openReport() });
commands.register("reportProblem", { enabled: () => true, run: APP_ACTIONS.reportProblem });

// --- the ⌘K palette ---------------------------------------------------------------------

const PAGES = [["today", "Today"], ["meetings", "Meetings"], ["people", "People"], ["projects", "Projects"],
  ["glossary", "Glossary"], ["settings", "Settings"]];

function goTo(view) {
  if (view === "today") openToday();
  else if (view === "people") openPeople();
  else if (view === "projects") openProjects();
  else if (view === "glossary") openGlossary();
  else if (view === "settings") openSettings();
  else if (lastMeeting()) openMeeting(lastMeeting());
  else openMeetingsList();
}

function loadRecent() {
  try {
    const x = JSON.parse(localStorage.getItem("palaver.palette.recent"));
    return Array.isArray(x) ? x : [];
  } catch {
    return [];
  }
}

function keepRecent(entry) {
  state.recent = paletteRecent(state.recent, entry);
  try {
    localStorage.setItem("palaver.palette.recent", JSON.stringify(state.recent));
  } catch { /* the palette remembers this session only */ }
}

function meetingEntry(x) {
  const start = x.start ? new Date(x.start) : null;
  return { kind: "meeting", id: x.id, label: x.title || fallbackTitle(x),
    detail: start ? `${dayLabel(start)}, ${timeFmt.format(start)}` : "", keywords: [...x.people, ...x.projects.map((p) => p.name)] };
}

// What the palette shows: before typing, the places opened lately, what can be
// done with the open meeting and the pages; then what matches.
function paletteGroups(query) {
  const m = state.view === "meetings" ? state.meeting : null;
  const cmds = paletteCommands(m);
  const pages = [...PAGES.map(([id, label]) => ({ kind: "page", id, label, detail: "Page" })),
    recordingCommand(recordingNow(state.meetings)), ...GLOBAL_COMMANDS];
  const meetings = state.meetings.map(meetingEntry);
  if (!query.trim()) {
    const projects = [...state.meetings.flatMap((x) => x.projects).map((p) => p.id),
      ...(state.projects?.projects || []).map((p) => p.id)];
    const recent = paletteRecentShown(state.recent, { meetings, people: state.names, projects });
    return [{ title: "Recent", entries: recent }, { title: m ? titleOf(m) : null, entries: cmds },
      { title: "Go to", entries: pages }, { title: "Help", entries: HELP_COMMANDS }];
  }
  const people = state.names.map((n) => ({ kind: "person", id: n, label: n, detail: "Person" }));
  const projects = [...new Map(state.meetings.flatMap((x) => x.projects).map((p) => [p.id, p])).values()]
    .map((p) => ({ kind: "project", id: p.id, label: p.name, detail: "Project" }));
  return [{ title: null, entries: paletteMatch(query,
    [...cmds, ...pages, ...settingsEntries(), ...HELP_COMMANDS, ...meetings, ...people, ...projects]) },
    { title: null, entries: [{ kind: "search", id: query.trim(), label: `Search transcripts for “${query.trim()}”` }] }];
}

// Commands of the whole app, any page: Report a Problem (#59).
const HELP_COMMANDS = [{ kind: "command", id: "reportProblem", label: "Report a Problem…", detail: "Help",
  keywords: ["bug", "feedback", "wish", "help"] }];

async function pickFromPalette(e) {
  usage.count("palette", e.kind === "command" ? `command.${e.id}` : e.kind);
  if (e.kind === "meeting") openMeeting(e.id);
  else if (e.kind === "person") openPeople(e.id);
  else if (e.kind === "project") openProjects(e.id);
  else if (e.kind === "page") goTo(e.id);
  else if (e.kind === "setting") openSettings("push", e.id);
  else if (e.kind === "command") commands.run(e.id);
  else if (e.kind === "search") {
    if (document.body.dataset.page !== "meetings") await (lastMeeting() ? openMeeting(lastMeeting()) : openMeetingsList());
    const field = $("#search");
    field.value = e.id;
    field.dispatchEvent(new Event("input"));
    field.focus();
  }
}

const paletteSpec = { groups: paletteGroups, pick: pickFromPalette };

function commandPalette() {
  if (!paletteOpen()) usage.count("palette", "open");
  togglePalette(paletteSpec);
}

// ⌘K opens and closes it, also while typing in a field (the capture phase: before anything else sees the key).
document.addEventListener("keydown", (e) => {
  if (!e.metaKey || e.ctrlKey || e.altKey || e.shiftKey || String(e.key).toLowerCase() !== "k") return;
  e.preventDefault();
  e.stopPropagation();
  if (!e.repeat) commandPalette();
}, true);
commands.register("palette", { enabled: () => true, run: commandPalette });
$("#palette-btn").addEventListener("click", commandPalette);

// --- getting back -------------------------------------------------------------------

// The window has no back button of its own: every page the user goes to is an
// entry in the page's history, so "‹ Back", ⌘[, the mouse's back button and a
// swipe return to it. Each entry keeps its depth (Back works above 0), and the
// meeting tab and scroll position it was left at. sessionStorage keeps how far
// Forward goes, across a reload.
history.scrollRestoration = "manual";
const NAV_TOP = "palaver.nav.top";
let nav = navStart(history.state, (() => {
  try { return JSON.parse(sessionStorage.getItem(NAV_TOP)); } catch { return null; }
})());
let routed = location.hash;  // the hash the page shows
let saveTimer = null;

function keepNav(next) {
  nav = next;
  try { sessionStorage.setItem(NAV_TOP, JSON.stringify(nav.top)); } catch { /* Forward still works on this page */ }
  showBack();
}

// Back is a two-finger swipe, ⌘[ and the Go menu: no button on the page.
function showBack() {
  commands.publish();
}

// Where the page is, kept in its entry: the meeting tab and how far it is scrolled.
function saveHere() {
  clearTimeout(saveTimer);
  saveTimer = null;
  const tab = state.view === "meetings" && state.meeting ? state.tab : undefined;
  const reviewAt = state.view === "review" ? state.reviewAt : undefined;
  try {
    history.replaceState({ ...history.state, depth: nav.depth, scroll: $("#main").scrollTop, tab, reviewAt }, "");
  } catch { /* WebKit limits how often; the next scroll saves it */ }
}
$("#main").addEventListener("scroll", () => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveHere, 200);
}, { passive: true });

// Every page calls this first, with its hash. ``how``: see historyStep.
// Answers the hash shown, for movedOn.
function arrive(hash, how = "push") {
  const step = historyStep(location.hash, hash, how);
  try {
    if (step === "push") {
      saveHere();
      const next = navPush(nav);
      history.pushState({ depth: next.depth }, "", hash);
      keepNav(next);
    } else if (step === "replace") {
      // The same place keeps its tab and scroll; another one starts afresh.
      const keep = location.hash === hash ? history.state : null;
      history.replaceState({ ...keep, depth: nav.depth }, "", hash);
    }
  } catch { /* WebKit limits how often: the page still opens, without its entry */ }
  routed = location.hash;
  countView(hash);
  return location.hash;
}

// A page opened, for the usage log (#59): once per place, not again when it is shown again in place.
let countedPlace = null;
function countView(hash) {
  const place = hashOf(placeOf(hash));
  if (place === countedPlace) return;
  countedPlace = place;
  usage.count("view", placeOf(hash).view);
}

// A page still loading that Back, Forward or another click has left meanwhile: not shown.
const movedOn = (here) => !samePlace(here, location.hash);

function goBack() {
  if (nav.depth <= 0) return;
  saveHere();
  history.back();
}

function goForward() {
  if (nav.depth >= nav.top) return;
  saveHere();
  history.forward();
}

// Back or Forward (or a hash set from outside): show that place again, as it was left.
async function arrived() {
  clearTimeout(saveTimer);  // a save still due belongs to the page left
  saveTimer = null;
  const entry = history.state;
  keepNav(navArrive(nav, entry));
  if (!Number.isInteger(entry?.depth)) history.replaceState({ depth: nav.depth }, "");
  routed = location.hash;
  countView(location.hash);
  await route("none", entry);
}
window.addEventListener("popstate", arrived);
// popstate comes first where both fire; a hash set without one still arrives.
window.addEventListener("hashchange", () => { if (location.hash !== routed) arrived(); });

commands.register("back", { enabled: () => nav.depth > 0, run: goBack });
commands.register("forward", { enabled: () => nav.depth < nav.top, run: goForward });
showBack();  // a reload can go back at once

// ⌘[ and ⌘] (the View menu shows them; the page takes the key first). Not while typing in a field.
document.addEventListener("keydown", (e) => {
  const where = keyNav(e);
  if (!where || isEditable(e.target)) return;
  e.preventDefault();
  commands.run(where);
});

// The mouse's side buttons. Their mousedown would go back in some browsers on its own.
for (const type of ["mousedown", "mouseup"]) {
  document.addEventListener(type, (e) => {
    const where = mouseNav(e);
    if (!where) return;
    e.preventDefault();
    if (type === "mouseup") commands.run(where);
  });
}


// Shows the page the hash points at. ``how``: see historyStep; ``entry``: the
// history entry's state, with the tab and scroll position to restore.
async function route(how = "none", entry = null) {
  const place = placeOf(location.hash);
  if (place.view === "today") await openToday(how);
  else if (place.view === "people") await openPeople(place.focus, how);
  else if (place.view === "projects") await openProjects(place.focus, how);
  else if (place.view === "glossary") await openGlossary(how);
  else if (place.view === "settings") {
    await openSettings(how, place.section);
  }
  else if (place.view === "review") await openReview(entry?.reviewAt ?? 0, how);
  else if (place.view === "coach") await openCoach(how);
  else if (place.view === "prep") await openPrep(place.key, how);
  else if (place.view === "setup") await openSetup(place.step, how);
  else if (place.view === "report") await openReport(place.meeting, null, how);
  else if (place.id) await openMeeting(place.id, undefined, { how, tab: entry?.tab });
  else await openMeetingsList(how);
  if (Number.isFinite(entry?.scroll)) $("#main").scrollTop = entry.scroll;
}

// --- start -----------------------------------------------------------------

// Recordings change state on their own (a call ends, a transcript is ready).
async function poll() {
  const before = new Map(state.meetings.map((m) => [m.id, `${m.status}|${m.title}`]));
  await loadList();
  if (state.view === "today") await refreshToday();
  if (state.view !== "meetings") return;
  const open = state.meeting && state.meetings.find((m) => m.id === state.meeting.id);
  if (!open || state.busy) return;
  if (open.status === "recording") loadQuestion();
  if (renderLater && !typingMyNotes()) keepingFocus(renderMeeting);
  if (open.status === "recording" && state.meeting.live) refreshLive();
  else if (before.get(open.id) !== `${open.status}|${open.title}`) openMeeting(open.id);
}
setInterval(poll, 10000);
window.palaver.poll = poll;  // the tests' way to the next poll, without waiting 10 s

// A meeting being recorded: show the newest text, unless the user is typing,
// and keep following the end if they were reading there.
async function refreshLive() {
  const main = $("#main");
  // Not under a field being typed in, my notes' paragraphs too: the next poll after it.
  if (main.contains(document.activeElement) && document.activeElement.matches("input, textarea, select")) return;
  const following = main.scrollHeight - main.scrollTop - main.clientHeight < 120;
  try {
    const m = await api(`/api/meetings/${encodeURIComponent(state.meeting.id)}`);
    if (state.meeting?.id !== m.id || state.view !== "meetings") return;
    state.meeting = m;
  } catch (err) {
    return;
  }
  renderMeeting();
  if (following) main.scrollTop = main.scrollHeight;
}
setInterval(() => { if (state.view !== "review") loadReview(); }, 30000);
setInterval(refreshMcp, 10000);
refreshMcp();
setInterval(refreshUpdate, 60000);
refreshUpdate();

// --- the window's server restarting (#57) ----------------------------------

// A quiet line while the server does not answer (it is being restarted); gone once it does.
const reconnecting = h("div", { id: "reconnecting", class: "reconnecting", role: "status", hidden: true }, "Reconnecting…");
document.body.append(reconnecting);
const beat = heartbeat({ fetch: (path, opts) => fetch(path, opts), show: (on) => { reconnecting.hidden = !on; },
  setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (id) => clearTimeout(id) });
setInterval(beat, 3000);

// The language model's runs this page did not start (a server before a restart started them):
// notes being written show as such, a finished sort hands its undo to this page.
async function loadModelJobs() {
  const jobs = await api("/api/model-jobs").catch(() => null);
  const { start, end } = notesFromJobs(jobs, state.writing);
  for (const { id, startedAt } of start) state.writing.set(id, { id, startedAt, controller: null, remote: true });
  for (const id of end) state.writing.delete(id);
  if (start.length || end.length) {
    renderList();
    const open = state.meeting?.id;
    if (open && end.includes(open) && state.view === "meetings") openMeeting(open, undefined, { how: "replace" });
    else if (open && start.some((x) => x.id === open)) renderMeeting();
    if (end.length) loadList();
  }
  if (!jobs) return;
  const sorting = (jobs.running || []).some((j) => j.kind === "projects");
  let projectsChanged = sorting !== state.remoteAsking;
  state.remoteAsking = sorting;
  for (const f of jobs.finished || []) {
    await api("/api/model-jobs/seen", { token: f.token }).catch(() => null);
    if (f.ok) remember(f.label, () => projectsBack(f.token));
    else errorToast(`${f.label}: the model did not finish; nothing changed`);
    projectsChanged = true;
  }
  if (projectsChanged && state.view === "projects") showProjects(await api("/api/projects").catch(() => null) ?? state.projects);
}
setInterval(loadModelJobs, 3000);
setInterval(() => {
  for (const [id, w] of state.writing) {
    if (!w.remote) continue;
    for (const el of document.querySelectorAll(`[data-writing="${id}"]`)) el.textContent = writingText(id) ?? el.textContent;
  }
}, 1000);

// The usage log's catalog (#59): every action, page and tab there is, so a report knows what was never used.
usage.catalog("action", [...actionCatalog(), "meeting.reportFromError", "app.reportProblem"]);
usage.catalog("view", ["today", "meetings", "people", "projects", "glossary", "settings", "review", "coach", "prep",
  "setup", "report"]);
usage.catalog("tab", Object.keys(TAB_LABELS));
usage.catalog("palette", ["open", "meeting", "person", "project", "page", "setting", "search", "command.reportProblem",
  ...GLOBAL_COMMANDS.map((c) => `command.${c.id}`), "command.startRecording", "command.stopRecording",
  ...Object.keys(meetingCommands({})).map((name) => `command.${name}`)]);

markTab(placeOf(location.hash).view);  // the page asked for, while its data comes
await Promise.all([loadList(), loadNames()]);
loadReview();
loadModelJobs();
route("replace", history.state).then(checkSetupOffer);  // a reload comes back to the tab and scroll position it had
