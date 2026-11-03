// Pure helpers of the Meetings window: no DOM, so node tests them (tests/js/).

// A meeting's tabs, in order. The keys go into history entries and links: "notes" stays the generated
// notes (shown as Summary), so older entries still open them; "mine" is the user's own notes (#44).
export const TAB_LABELS = { notes: "Summary", mine: "Notes", transcript: "Transcript", coach: "Coach" };
export const meetingTabs = (m) => ["notes", "mine", "transcript", ...(m.status === "ready" ? ["coach"] : [])];

// The tab a meeting opens on: the one ``asked`` for (history, a link) when it has it; the transcript at a time
// to play and while it records; the coach when the coach was open (``current``); else the summary, or my
// notes when there is no summary but notes of mine.
export function meetingTab(m, { asked = null, at = null, current = null } = {}) {
  const tabs = meetingTabs(m);
  if (asked && tabs.includes(asked)) return asked;
  if (at != null || m.live || m.status === "recording") return "transcript";
  if (current === "coach" && tabs.includes("coach")) return "coach";
  return !m.notes && m.my_notes_revision ? "mine" : "notes";
}

// What can be done with a meeting, from its JSON alone: the toolbar, the ⋯
// menu, the list's right-click menu and the native "Meeting" menu all ask
// this. The names are the command names the native menu calls.
export function meetingCommands(m) {
  const live = !!m.live || m.status === "recording";
  const busy = live || m.status === "processing";  // its files are still being written
  const ready = m.status === "ready" && !live;
  const untranscribed = m.status === "failed" || m.status === "waiting";
  const nb = m.neighbours || {};
  return {
    play: { label: "Play", shortcut: "Space", enabled: !!m.has_audio },
    // A title is harmless metadata: any meeting, also one being recorded.
    rename: { label: "Rename…", paletteLabel: "Rename Meeting", enabled: true },
    // Not transcribed: `palaver process` failed on it, or it waits for its models.
    transcribe: { label: "Transcribe Again", enabled: untranscribed, hidden: !untranscribed },
    writeNotes: { label: m.notes ? "Rewrite notes" : "Write notes", shortcut: "⌘⇧N", enabled: ready },
    changeEvent: { label: "Change Event…", enabled: ready },
    joinPrevious: { label: "Join with Previous", shortcut: "⌘J", enabled: ready && !!nb.previous },
    joinNext: { label: "Join with Next", enabled: ready && !!nb.next },
    split: { label: "Split At…", enabled: ready && (m.transcript || []).length > 1 },
    reviewAgain: { label: "Review Again", enabled: !!m.reviewed && !busy },
    // One file to send to a colleague (#58); a finished meeting only.
    export: { label: "Export…", paletteLabel: "Export Meeting…", enabled: ready },
    // #9: the space goes, the transcript and notes stay; not to be played or transcribed again.
    deleteAudio: { label: "Delete Audio…", paletteLabel: "Delete This Meeting's Audio…", danger: true,
      enabled: ready && !!m.has_audio, hidden: !m.has_audio },
    trash: { label: "Move to Trash", shortcut: "⌘⌫", danger: true, enabled: !busy },
    // Kept on this Mac: no cloud model gets this meeting, whatever Settings say (#53).
    localOnly: { label: m.local_only ? "Allow Cloud Models" : "Keep on This Mac", enabled: true },
    // One microphone for many (#56): the voices can't be told apart, or they can after all.
    shared: { label: m.shared?.meeting ? "Speakers Can Be Separated" : "Speakers Can't Be Separated", enabled: ready },
    // Only while the event's series is remembered: a mark that came from it can be stopped at its source.
    forgetSeries: { label: "Forget for This Series", enabled: !!m.shared?.series?.remembered,
      hidden: !m.shared?.series?.remembered },
    // #59: the report form with this meeting chosen.
    report: { label: "Report a Problem with This Meeting…", paletteLabel: "Report a Problem with This Meeting",
      enabled: true },
  };
}

// Why a meeting has no transcript (its "untranscribed", failed.json): what the page says above Transcribe Again.
// A failed run's own error shows in the failure line above it (m.failure, from the log), with Report.
export function untranscribedText(m) {
  const u = m.untranscribed || {};
  if (m.status === "waiting") {
    const missing = (u.missing || []).join(" and ") || "The transcription models";
    const are = (u.missing || []).length > 1 ? "are" : "is";
    return `Recorded before the models were downloaded: ${missing} ${are} still missing. `
      + "The meeting is transcribed by itself once the download in Settings is done.";
  }
  const why = !m.failure && u.error ? ` (${u.error})` : "";
  return `This meeting was not transcribed${why}. The audio is kept: it can be transcribed again.`;
}

// --- a meeting's own title ---------------------------------------------------------

export const TITLE_MAX = 200;  // as the server caps it (titles.py)

// What saving ``typed`` as the title of ``m`` sends: the title on one line,
// "" to give the title back to the event or the notes, or null when nothing
// changes (the same words, or emptied with no title of one's own to clear).
export function titleChange(m, typed) {
  const title = String(typed ?? "").split(/\s+/).filter(Boolean).join(" ").slice(0, TITLE_MAX).trimEnd();
  if (m.title_from === "you") return title === m.title ? null : title;
  return !title || title === m.title ? null : title;
}

// The meeting as it shows once ``title`` is saved: the title of one's own,
// or, cleared, the next one (the event's, the notes'), as the server decides.
export function withTitle(m, title) {
  if (title) return { ...m, title, title_from: "you" };
  if (m.imported?.title) return { ...m, title: m.imported.title, title_from: "imported" };
  if (m.calendar?.title) return { ...m, title: m.calendar.title, title_from: "calendar" };
  if (m.notes?.title) return { ...m, title: m.notes.title, title_from: "notes" };
  return { ...m, title: null, title_from: null };
}

// The toast after a rename; ``shown``: the title the page shows now.
export function retitledText(m, shown) {
  return m.title_from === "you" ? `Renamed to “${shown}”` : `Title back to “${shown}”`;
}

// Two titles that say the same, whatever their case and the spaces around them.
export const sameTitle = (a, b) => String(a ?? "").trim().toLocaleLowerCase() === String(b ?? "").trim().toLocaleLowerCase();

// The quiet line under the title when the calendar calls the meeting otherwise
// (a title of one's own, the sender's, the notes'). None while the event chip
// asks about the event: it names it already.
export function calendarHint(m) {
  const event = m.calendar?.title;
  if (!event || sameTitle(event, m.title) || eventLinkView(m)) return null;
  return `Calendar: ${event}`;
}

// The meeting to show once ``id`` is gone from ``list``: the one below it,
// or the one above when it was the last; null when none is left.
export function nextAfter(list, id) {
  const at = list.findIndex((m) => m.id === id);
  if (at < 0) return null;
  return list[at + 1] || list[at - 1] || null;
}

// --- the running recording ------------------------------------------------------

// The question whether to stop a manual recording (/api/recording/question),
// when it is about meeting ``m`` and that one is still being recorded.
export function stopQuestionFor(question, m) {
  if (!question || !m || question.meeting !== m.id) return null;
  return m.status === "recording" || m.live ? question : null;
}

// The line under a meeting's title about its recording (issue #47): why the
// running recording records ("Recording · Teams call since 12:06 · mic AirPods
// (24 kHz)", from /api/recording/question), or how a finished one started and
// stopped.
export function recordingLine(m, recording) {
  if (!m) return null;
  if (recording && recording.meeting === m.id && (m.status === "recording" || m.live)) return recording.text;
  return m.recorded || null;
}

// What went wrong with a meeting's audio (issue #50): the running
// recording's warnings while it lasts ("System audio is running at the wrong
// speed, re-syncing"), else when a finished one's audio went wrong ("Audio
// problem at 12:14 (system audio ran at the wrong speed)").
export function audioWarnings(m, recording) {
  if (!m) return [];
  if (recording && recording.meeting === m.id && (m.status === "recording" || m.live)) return recording.warnings || [];
  return (m.audio_problems || []).map((p) => p.text);
}

// Soft hints about the running recording ("Your mic sends nothing — muted?"),
// only on its own page while it records: not warnings, gone afterwards.
export function audioHints(m, recording) {
  if (!m || !recording || recording.meeting !== m.id || !(m.status === "recording" || m.live)) return [];
  return recording.hints || [];
}

// The pauses in a recording (Palaver restarted) to show before transcript
// line ``i``: those after the line before it; ``i`` = the number of lines
// gives those after the last line.
export function gapsBefore(gaps, lines, i) {
  const after = i > 0 ? lines[i - 1].start : -Infinity;
  const before = i < lines.length ? lines[i].start : Infinity;
  return (gaps || []).filter((g) => g.start > after && g.start <= before);
}

// The toast after an answer to that question.
export function stopAnswerText(choice) {
  return choice === "stop" ? "Recording stopped. It is transcribed in the background."
    : "Still recording. Palaver asks again when the next call ends or after 30 silent minutes.";
}

// --- speaker lanes ------------------------------------------------------------

// "Speaker 3" for SPEAKER_02, as the server shows a label without a name.
export function labelDisplay(label) {
  const number = String(label).split("_").at(-1);
  return /^\d+$/.test(number) ? `Speaker ${Number(number) + 1}` : String(label);
}

// How many transcript lines are in a speaker's lane.
export function laneLines(m, label) {
  return (m.transcript || []).filter((t) => t.label === label).length;
}

export const linesText = (n) => `${n} ${n === 1 ? "line" : "lines"}`;

// A lane's ⋯ menu, in order (null is the separator): what applies to this
// speaker, and whether it can be done now. Merging and removing wait while
// the meeting's files are still being written.
export function laneCommands(m, s) {
  const busy = !!m.live || m.status === "recording" || m.status === "processing";
  // The user's own lane: several people may sit at the microphone too (in person), once it is transcribed.
  if (s.is_user) {
    if (s.shared === "meeting" || busy || m.status !== "ready") return [];
    return [
      s.shared ? { name: "rename", label: "Name the Room", enabled: true } : undefined,
      { name: "room", label: s.shared ? "Only Me at My Mic" : "Several People at My Mic", enabled: true },
    ].filter((x) => x !== undefined);
  }
  const others = (m.speakers || []).filter((o) => !o.is_user && o.label !== s.label);
  // A room of several people (#56) has a room name instead of a person's; the
  // whole meeting marked leaves its lanes nothing to name or mark one by one.
  return [
    s.shared === "meeting" ? undefined : { name: "rename", label: s.shared ? "Name the Room" : "Rename", enabled: true },
    s.clips?.length ? { name: "playVoice", label: "Play Voice", enabled: true } : undefined,
    others.length ? { name: "mergeInto", label: "Merge Into…", enabled: !busy } : undefined,
    s.name && (s.named_by === "voice" || s.named_by === "inferred")
      ? { name: "notName", label: `Not ${s.name}`, enabled: true } : undefined,
    // A voice the user can't name: no to-do while it has none (it can still be named any time).
    s.name || s.shared ? undefined
      : { name: "unknown", label: s.unknown ? "Ask Me Again" : "Don't Know Who This Is", enabled: !busy },
    s.shared === "meeting" ? undefined
      : { name: "room", label: s.shared ? "One Person After All" : "A Room, Several People", enabled: !busy },
    null,
    { name: "notSpeaker", label: "Not a Speaker", danger: true, enabled: !busy },
  ].filter((x) => x !== undefined);
}

// A lane shows its round play button when hearing the voice is how to tell who
// it is: no name yet, or a guessed one (by voice, inferred) not confirmed.
export function inlinePlay(s) {
  if (s.is_user || s.shared || !s.clips?.length) return false;
  return !s.name || s.named_by === "voice" || s.named_by === "inferred";
}

// The toast after marking lane ``s`` a room of several people, or one person again (#56).
export function roomText(s, on, lines) {
  if (s.is_user) return on ? `Several people at your microphone · ${linesText(lines)}` : "Only you at your microphone";
  const who = labelDisplay(s.label);
  return on ? `${who} is a room, several people · ${linesText(lines)}` : `${who} is one person again`;
}

// The toast after Don't Know Who This Is (``on``) or Ask Me Again, for the voice shown as ``who``.
export const unknownText = (who, on) => (on ? `${who} stays without a name · not asked again` : `${who} is asked about again`);

// The toast after naming a room ("" takes its name back); null when nothing changes.
export function roomNameText(s, name) {
  name = name.trim();
  if (name === (s.room || "")) return null;
  return name ? `The room is now “${name}”` : "The room has no name now";
}

// The toast after naming speaker ``s`` ``name`` ("" takes its name back);
// null when nothing changes.
export function namingText(s, name) {
  name = name.trim();
  const who = labelDisplay(s.label);
  if (name && name !== s.name) return `${who} is now ${name}`;
  if (!name && s.name) return `${who} is not ${s.name}`;
  if (name && s.named_by === "inferred") return `${who} is ${name}`;  // a guess confirmed
  return null;
}

// The meeting as it will be once the speaker is named: shown at once, while
// the server saves it. A copy: the meeting passed in is what a failure restores.
export function withName(m, label, name) {
  name = name.trim();
  const display = name || labelDisplay(label);
  return {
    ...m,
    speakers: m.speakers.map((s) => (s.label !== label || s.is_user ? s : {
      ...s, name: name || null, display, named_by: name ? "you" : null, recognized: null, inferred: null,
      link: name ? yourLink("speaker", name) : null,
    })),
    transcript: m.transcript.map((t) => (t.label === label ? { ...t, speaker: display } : t)),
  };
}

// --- transcript lines -----------------------------------------------------------

// 12:04, or 1:02:05 past the hour.
export function clock(seconds) {
  seconds = Math.max(0, Math.floor(seconds || 0));
  const hrs = Math.floor(seconds / 3600);
  const min = Math.floor((seconds % 3600) / 60);
  const sec = String(seconds % 60).padStart(2, "0");
  return hrs ? `${hrs}:${String(min).padStart(2, "0")}:${sec}` : `${min}:${sec}`;
}

// A line's toolbar and right-click menu, in order. Editing and cutting wait
// until the meeting is transcribed; a cut needs a line before it. ``fixable``:
// there are words to start "Fix spelling" from.
export function lineCommands(m, i, fixable) {
  const ready = m.status === "ready" && !m.live;
  return [
    m.has_audio ? { name: "play", label: "Play from here", enabled: true } : null,
    ready ? { name: "edit", label: "Edit", enabled: true } : null,
    { name: "fixSpelling", label: "Fix spelling", enabled: !!fixable },
    { name: "copy", label: "Copy", enabled: true },
    ready && i > 0 ? { name: "split", label: "Split here", enabled: true } : null,
  ].filter(Boolean);
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Where a line is marked: words the glossary respelled ({heard}: the variant
// heard), words the transcriber was unsure of, and, given ``people`` (name →
// colour, see meetingPeople), the names of the meeting's people ({color});
// in order, never overlapping, a name never in place of the other two.
export function lineMarks(t, people = null) {
  const marks = (t.glossed || []).map(([a, b, heard]) => ({ a, b, kind: "glossed", heard }));
  if (t.unsure?.length) {
    const re = new RegExp(`(?<![\\p{L}\\p{N}])(?:${t.unsure.map(escapeRe).join("|")})(?![\\p{L}\\p{N}])`, "giu");
    for (const x of t.text.matchAll(re)) {
      const a = x.index, b = a + x[0].length;
      if (!marks.some((y) => a < y.b && b > y.a)) marks.push({ a, b, kind: "unsure" });
    }
  }
  const known = [...marks];
  for (const x of people ? nameMarks(t.text, people) : []) {
    if (!known.some((y) => x.a < y.b && x.b > y.a)) marks.push({ ...x, kind: "name" });
  }
  marks.sort((x, y) => x.a - y.a);
  let end = 0;  // where the last mark kept ends
  return marks.filter((x) => {
    if (x.a < end) return false;
    end = x.b;
    return true;
  });
}

// The word "Fix spelling" starts from when nothing is selected: the line's
// first marked word, as the line shows it; null when there is none.
export function fixableWord(t) {
  const x = lineMarks(t)[0];
  return x ? { text: t.text.slice(x.a, x.b), a: x.a, b: x.b } : null;
}

// What undoing an edit of line ``t`` saves: the text it had, or null (what was heard).
export const lineBefore = (t) => (t.edited ? t.text : null);

export const lineEditedText = (t) => `Line at ${clock(t.start)} edited`;

// Which cut the server made: "own", "next", "after" or "before".
export const cutKind = (r) => r.discarded || (r.joined ? "next" : "own");

// --- projects and people ----------------------------------------------------------

const fold = (s) => String(s || "").trim().toLocaleLowerCase();
const byName = (x, y) => fold(x.name).localeCompare(fold(y.name));

// The project a chip change is about: by id, or by name (null: a new project).
function projectOf(m, change, after) {
  const known = [...(m.projects || []), ...(m.project_suggestions || []), ...(m.all_projects || []),
    ...(after?.projects || []), ...(after?.all_projects || [])];
  if (change.project) return known.find((p) => p.id === change.project) || { id: change.project, name: change.project };
  return known.find((p) => fold(p.name) === fold(change.name)) || null;
}

// The meeting as it will be once its projects change (``change`` as POSTed to
// /projects): shown at once while the server saves it. A copy: the meeting
// passed in is what a failure restores.
export function withProject(m, change) {
  const p = projectOf(m, change);
  if (change.remove) return { ...m, projects: m.projects.filter((x) => x.id !== p?.id) };
  const id = p?.id ?? null;
  const name = p?.name ?? String(change.name).trim();
  const sure = { id, name, by: "you", why: "", link: yourLink("project", name) };
  const has = id != null && m.projects.some((x) => x.id === id);
  return {
    ...m,
    projects: has ? m.projects.map((x) => (x.id === id ? { ...x, ...sure } : x)) : [...m.projects, sure].sort(byName),
    project_suggestions: (m.project_suggestions || []).filter((s) => s.id !== id),
  };
}

// The toast after a chip change and the project it is about (``id``: null
// for a project made by name the server did not answer yet); null when
// nothing changed. ``before`` is the meeting before the change, ``after``
// the server's answer (it knows the id of a project made by name).
export function projectChange(before, change, after = null) {
  const p = projectOf(before, change, after);
  const had = p && before.projects.find((x) => x.id === p.id);
  if (change.remove) return had ? { text: `Removed from ${had.name}`, id: had.id } : null;
  if (had) return had.by === "you" ? null : { text: `Confirmed ${had.name}`, id: had.id };
  return { text: `Added to ${p?.name ?? String(change.name).trim()}`, id: p?.id ?? null };
}

// A project's ⋯ on the Projects page, in order (null is the separator).
export function projectCommands(d, p) {
  const others = d.projects.filter((o) => o.id !== p.id);
  return [
    { name: "rename", label: "Rename", enabled: true },
    others.length ? { name: "mergeInto", label: "Merge Into…", enabled: true } : undefined,
    null,
    { name: "delete", label: "Delete", danger: true, enabled: true },
  ].filter((x) => x !== undefined);
}

// A named person's ⋯ on the People page: Rename and Change Organization (their
// fields), Play Voice when a meeting has a clip of them.
export function personCommands(p) {
  return [
    { name: "rename", label: "Rename", enabled: true },
    { name: "organization", label: "Change Organization", enabled: true },
    p.meetings?.some((x) => x.clip) ? { name: "playVoice", label: "Play Voice", enabled: true } : undefined,
  ].filter((x) => x !== undefined);
}

// A voice heard in several meetings, no name yet: Name This Voice (its field), Play Voice.
export function voiceCommands(g) {
  return [
    { name: "name", label: "Name This Voice", enabled: true },
    g.voices?.some((v) => v.clip) ? { name: "playVoice", label: "Play Voice", enabled: true } : undefined,
  ].filter((x) => x !== undefined);
}

// A glossary term's ⋯: Rename and Edit Note (its fields), Delete in red, last.
export function termCommands() {
  return [
    { name: "rename", label: "Rename", enabled: true },
    { name: "editNote", label: "Edit Note", enabled: true },
    null,
    { name: "delete", label: "Delete", danger: true, enabled: true },
  ];
}

// The toast after a glossary term changed: renamed, its note, a spelling added or removed.
export function termChangeText(t, body) {
  if (body.term !== undefined) return `“${t.term}” is now “${body.term.trim()}”`;
  if (body.note !== undefined) return body.note.trim() ? `Note on “${t.term}” saved` : `Note on “${t.term}” removed`;
  if (body.remove_variant !== undefined) return `“${body.remove_variant}” is no longer respelled as “${t.term}”`;
  if (body.add_variants?.length) return `“${body.add_variants.join("”, “")}” is now respelled as “${t.term}”`;
  return `“${t.term}” changed`;
}

// The toast after a project's name or description changed.
export function projectEditText(p, body) {
  if (body.name !== undefined) return `“${p.name}” is now “${body.name.trim()}”`;
  return body.description?.trim() ? `Description of “${p.name}” saved` : `Description of “${p.name}” removed`;
}

// The toast after renaming a person: a name someone has already merges the two.
export function renameText(d, oldName, name) {
  name = name.trim();
  if (!name || name === oldName) return null;
  const other = d.people.find((p) => p.name !== oldName && fold(p.name) === fold(name));
  return other ? `${oldName} merged into ${other.name}` : `${oldName} is now ${name}`;
}

// The toast after naming a voice heard in ``n`` meetings.
export const voicesText = (n, name) => `This voice is now ${name.trim()} · ${n} ${n === 1 ? "meeting" : "meetings"}`;

// How long writing notes usually takes, in seconds: the median of the last 5
// runs, or null until there are two to go by.
export function notesEstimate(history) {
  const last = (history || []).filter((x) => Number.isFinite(x)).slice(-5);
  if (last.length < 2) return null;
  const s = [...last].sort((a, b) => a - b);
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

// --- getting back -------------------------------------------------------------

// The page a hash points at: Today (#/today, and the bare address: the
// window opens on it), #/meetings (the list, no meeting chosen), #/<meeting
// id>, #/people[/<name>], #/projects[/<id>], #/upcoming/<key>, or one of the
// plain pages.
const PLAIN = new Set(["glossary", "settings", "review", "coach", "today"]);
export function placeOf(hash) {
  const path = String(hash || "").replace(/^#\/?/, "");
  const [head, ...rest] = path.split("/");
  const tail = rest.length ? decodeURIComponent(rest.join("/")) : null;
  if (!path) return { view: "today" };
  if (path === "meetings") return { view: "meetings", id: null };
  if (head === "people" || head === "projects") return { view: head, focus: tail };
  if (head === "upcoming" && tail) return { view: "prep", key: tail };
  if (head === "setup") return { view: "setup", step: tail };
  if (head === "report") return { view: "report", meeting: tail };  // #59: the meeting it is about, if said
  if (head === "settings" && tail) return { view: "settings", section: tail };  // a notification's: settings/update
  if (PLAIN.has(head)) return { view: head };
  return { view: "meetings", id: path ? decodeURIComponent(path) : null };
}

export function hashOf(place) {
  const part = (x) => encodeURIComponent(x);
  if (place.view === "people" || place.view === "projects") return `#/${place.view}${place.focus ? `/${part(place.focus)}` : ""}`;
  if (place.view === "prep") return `#/upcoming/${part(place.key)}`;
  if (place.view === "setup") return `#/setup${place.step ? `/${part(place.step)}` : ""}`;
  if (place.view === "report") return `#/report${place.meeting ? `/${part(place.meeting)}` : ""}`;
  if (PLAIN.has(place.view)) return `#/${place.view}`;
  return place.id ? `#/${part(place.id)}` : "#/meetings";
}

const sameHash = (a, b) => String(a || "").replace(/^#\/?/, "") === String(b || "").replace(/^#\/?/, "");

// Do two hashes show the same page? A page still loading is wanted only while
// the hash points at it: a quick Back or Forward may have moved on meanwhile.
export const samePlace = (a, b) => hashOf(placeOf(a)) === hashOf(placeOf(b));

// An undo that brings meetings back (a trash, a join): it takes the place of
// the page it undid (the meeting itself, or the one opened in its place, in
// ``ids``); anywhere else it opens as a new page.
export function undoStep(hash, ids) {
  const here = placeOf(hash);
  return here.view === "meetings" && here.id && ids.includes(here.id) ? "replace" : "push";
}

// What going to ``to`` does to the window's history: somewhere else is a new
// entry ("push"), the same place again (a refresh) replaces it. ``how``:
// "replace" for a page that takes the place of one gone (the next meeting
// after a trash), "none" when Back or Forward has moved there already.
export function historyStep(from, to, how = "push") {
  if (how === "none") return "none";
  if (how === "replace" || sameHash(from, to)) return "replace";
  return "push";
}

// How deep the window's own history is: ``depth`` of the entry shown (0 is the
// first page; Back works above it), ``top`` the deepest one Forward can reach.
// ``entry`` is history.state, ``stored`` the top kept in sessionStorage. A page
// without a depth is a fresh start: an old stored top is not this page's.
export function navStart(entry, stored) {
  if (!Number.isInteger(entry?.depth)) return { depth: 0, top: 0 };
  const depth = entry.depth;
  return { depth, top: Number.isInteger(stored) ? Math.max(stored, depth) : depth };
}

export const navPush = (nav) => ({ depth: nav.depth + 1, top: nav.depth + 1 });

// Back or Forward landed on ``entry``. One without a depth is new: a link or
// the app set the hash, which adds an entry like a push.
export function navArrive(nav, entry) {
  if (!Number.isInteger(entry?.depth)) return navPush(nav);
  return { depth: entry.depth, top: Math.max(nav.top, entry.depth) };
}

// ⌘[ and ⌘]: by the key, or by where the key is (on a German keyboard ü and +).
export function keyNav(e) {
  if (!e.metaKey || e.ctrlKey || e.altKey || e.shiftKey || e.repeat) return null;
  if (e.key === "[" || e.code === "BracketLeft") return "back";
  if (e.key === "]" || e.code === "BracketRight") return "forward";
  return null;
}

// The mouse's side buttons.
export const mouseNav = (e) => (e.button === 3 ? "back" : e.button === 4 ? "forward" : null);


// --- search (#46) -----------------------------------------------------------------

const JOINING = new Set(["and", "or", "with", "und", "oder", "mit"]);

// ``text`` without the part ``[from, to]`` a filter came from, and the little
// word that joined it to the rest ("Anna and Tom" without Tom: "Anna").
export function withoutSpan(text, [from, to]) {
  let before = text.slice(0, from).trimEnd();
  let after = text.slice(to).trimStart();
  const last = before.split(/\s+/).at(-1)?.toLowerCase();
  const first = after.split(/\s+/)[0]?.toLowerCase();
  if (JOINING.has(last)) before = before.slice(0, before.length - last.length).trimEnd();
  else if (!before && JOINING.has(first)) after = after.slice(first.length).trimStart();
  return [before, after].filter(Boolean).join(" ");
}

const NAMES = new Set(["person", "project", "org"]);

// The search text without a chip's filter, found in the text as it is now
// (typing may have moved it): a name becomes a quoted word, so its text
// search stays; anything else goes, with the word that joined it.
export function chipRemoved(text, chip) {
  const escaped = chip.text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = new RegExp(`(?<![\\p{L}\\p{N}_"])${escaped}(?![\\p{L}\\p{N}_"])`, "iu").exec(text);
  if (!m) return text;
  const span = [m.index, m.index + m[0].length];
  if (NAMES.has(chip.kind) && !chip.written) return `${text.slice(0, span[0])}"${m[0]}"${text.slice(span[1])}`;
  return withoutSpan(text, span);
}

// What a hit in the notes is: "Decision", "Next step · Anna", its section.
export function noteKind(hit) {
  if (hit.kind === "decision") return "Decision";
  if (hit.kind === "step") return hit.owner ? `Next step · ${hit.owner}` : "Next step";
  if (hit.kind === "point") return hit.heading || "Notes";
  return "Summary";
}

// Meetings found by meaning that the words did not find already.
export function relatedOnly(results, related) {
  const found = new Set((results || []).map((r) => r.id));
  return (related || []).filter((r) => !found.has(r.id));
}

// Where to open a result: its first line found, by words or by meaning.
export function firstMoment(r) {
  return r.hits?.[0]?.start ?? (r.meaning || []).find((p) => p.kind === "line")?.start;
}

// --- Settings → Language model (#53) ----------------------------------------------

const FEATURE_LABELS = { notes: "Notes", projects: "Projects", transcription: "Transcription", test: "Test" };
const lowerFirst = (s) => s.charAt(0).toLowerCase() + s.slice(1);  // "Add the API key" -> "add the API key"

// The choices for a feature's model: this Mac first, then each provider. One
// that isn't set up can't be picked; its label says what is missing.
export function engineOptions(lm) {
  const local = lm.local.models.find((m) => m.repo === lm.local.model);
  return [
    { value: "local", label: `On this Mac · ${local?.label || lm.local.model}`, disabled: false },
    ...lm.providers.map((p) => ({
      value: p.id,
      label: `${p.label}${p.model ? ` · ${p.model}` : ""}${p.ready ? "" : ` (${lowerFirst(p.problem)} first)`}`,
      disabled: !p.ready,
    })),
    // Notes waiting for a cloud model (#55: a Mac too small for the local one).
    ...((lm.features || []).some((f) => f.choice === "pending")
      ? [{ value: "pending", label: "None yet: set up a cloud model", disabled: false }] : []),
  ];
}

// Who gets what for ``feature``, said plainly.
export function sendsText(lm, feature) {
  if (feature.choice === "pending") {
    return `Off: no model writes ${feature.label.toLowerCase()} until you set up a cloud model below. Nothing is sent.`;
  }
  const p = lm.providers.find((x) => x.id === feature.choice);
  if (!p) return "Stays on this Mac.";
  if (!p.ready) {
    return `${p.label} is not set up (${lowerFirst(p.problem)}): nothing is sent, and `
      + `${feature.label.toLowerCase()} wait until it is or you choose another model.`;
  }
  return `Sends ${feature.sends} to ${p.sends_to}.`;
}

// Seconds of audio, as people say them: 2 s, 21 min, 1.5 h.
function audioText(seconds) {
  if (seconds < 60) return `${Math.round(seconds)} s`;
  if (seconds < 5400) return `${Math.round(seconds / 60)} min`;
  return `${+(seconds / 3600).toFixed(1)} h`;
}

// One line of the access log: what, how much, where to, how it went. A
// transcription upload counts audio; the host is shown wherever it can
// differ (an endpoint the user set, a service's region).
export function accessLogText(e, lm) {
  const p = (lm.providers || []).find((x) => x.id === e.provider);
  const label = p ? p.label : (lm.labels || {})[e.provider] || e.provider;
  const n = (e.meetings || []).length;
  const audio = e.audio_seconds !== undefined && e.audio_seconds !== null;
  const where = (p && p.id === "openai") || audio ? `${e.model}, ${e.host}` : e.model;
  const amount = audio
    ? `${audioText(e.audio_seconds)} of ${e.track ? `the ${e.track} track` : "audio"}`
    : `${e.chars.toLocaleString("en-US")} characters`;
  return [
    FEATURE_LABELS[e.feature] || e.feature,
    n ? `${n} meeting${n === 1 ? "" : "s"}` : null,
    `${amount} → ${label} (${where})`,
    e.ok ? `${e.seconds} s` : `failed: ${e.error || "unknown error"}`,
  ].filter(Boolean).join(" · ");
}

// The Test button's answer.
export function testText(result) {
  return `“${result.answer}” in ${result.seconds} s`;
}

// A context window, like a size: 1M tokens, 128k tokens.
export function tokensText(n) {
  if (n >= 1000000) return `${+(n / 1000000).toFixed(1)}M tokens`;
  if (n >= 1000) return `${Math.round(n / 1000)}k tokens`;
  return `${n} tokens`;
}

// --- Settings → Transcription (#54) ----------------------------------------------

// The choices for transcription: this Mac first, then each service; one not
// set up can't be picked, and its label says what is missing.
export function transcriberOptions(tr) {
  return [
    { value: "local", label: "On this Mac · Parakeet", disabled: false },
    ...tr.providers.map((p) => ({
      value: p.id,
      label: `${p.label}${p.model ? ` · ${p.model}` : ""}${p.ready ? "" : ` (${lowerFirst(p.problem)} first)`}`,
      disabled: !p.ready,
    })),
  ];
}

// Who gets what, said plainly. A service no longer set up sends nothing:
// meetings are transcribed here meanwhile.
export function transcriptionSendsText(tr) {
  const p = tr.providers.find((x) => x.id === tr.feature.choice);
  if (!p) return "Both tracks are transcribed on this Mac.";
  if (!p.ready) {
    return `${p.label} is not set up (${lowerFirst(p.problem)}): meetings are transcribed on this Mac until it is.`;
  }
  return `Sends ${tr.feature.sends} to ${p.sends_to}.`;
}

const dollars = (usd) => `$${usd.toFixed(2)}`;

// A service's list price, or that the endpoint decides.
export function priceText(p) {
  if (p.usd_per_hour === null || p.usd_per_hour === undefined) return "The price is what your endpoint charges.";
  return `About ${dollars(p.usd_per_hour)} per hour of audio sent (list price).`;
}

// The Test button's answer: how long it took, what an hour costs.
export function transcriptionTestText(result) {
  const price = result.usd_per_hour === null || result.usd_per_hour === undefined
    ? "" : ` · about ${dollars(result.usd_per_hour)} per hour of audio`;
  return `Answered in ${result.seconds} s${price}`;
}

// What was sent this month and what it cost, estimated at list prices.
export function monthText(month) {
  if (!month.seconds) return "Nothing was sent for transcription this month.";
  const n = month.meetings;
  return `This month: ${n} meeting${n === 1 ? "" : "s"}, ${audioText(month.seconds)} of audio sent, `
    + `about ${dollars(month.usd)}.`;
}

// A meeting's line about who transcribed it: only when a service did, or
// when this Mac stepped in for one that failed.
export function transcribedText(t) {
  if (!t) return null;
  if (t.fallback_from) {
    return `Transcribed on this Mac: ${t.fallback_label || t.fallback_from} failed${t.error ? ` (${t.error})` : ""}`;
  }
  if (t.engine === "local" || t.engine === "live") return null;
  const sent = t.sent_seconds ? [`${audioText(t.sent_seconds)} sent`] : [];
  if (t.usd !== null && t.usd !== undefined) sent.push(`about ${dollars(t.usd)}`);
  return `System track transcribed by ${t.label || t.engine}${sent.length ? ` (${sent.join(", ")})` : ""}`;
}

// --- Claude access (MCP) ------------------------------------------------------------

// The MCP clients by the name they give in their handshake.
const CLIENT_NAMES = { "claude-code": "Claude Code", "claude-ai": "Claude Desktop" };

export function clientName(client, { version = true } = {}) {
  if (!client?.name) return "Unknown client";
  const name = CLIENT_NAMES[client.name] || client.name;
  return version && client.version ? `${name} ${client.version}` : name;
}

// The top bar's "MCP · 2": only while a client is connected.
export function mcpIndicator(clients) {
  if (!clients?.length) return null;
  const n = clients.length;
  return {
    text: `MCP · ${n}`,
    title: `Claude can read your meetings: ${n} ${n === 1 ? "client" : "clients"} connected (${clients.map((c) => clientName(c.client)).join(", ")})`,
  };
}

// Which part of a transcript get_meeting sent, or null for none.
export function transcriptPart(args = {}) {
  const from = args.from_minute, to = args.to_minute;
  if (to != null) return `transcript ${from ?? 0}–${to} min`;
  if (from != null) return `transcript from ${from} min`;
  return args.include_transcript ? "full transcript" : null;
}

// What a call without arguments asked for.
const ALL_OF = { list_meetings: "all meetings", list_projects: "all projects", list_people: "everyone",
  open_next_steps: "all next steps" };
const ARG_WORDS = { project: "project", person: "person", since: "since", until: "until", limit: "limit", owner: "owner" };

// A log entry's arguments in short. ``titleOf(id)``: a meeting's title, or null.
export function mcpArgsText(entry, titleOf) {
  const args = entry.args || {};
  const words = [];
  if (entry.tool === "get_meeting") {
    words.push(titleOf(args.meeting_id) || args.meeting_id, transcriptPart(args));
  } else if (entry.tool === "get_project") {
    words.push(args.project);
  } else {
    if (args.query != null) words.push(`“${args.query}”`);
    for (const [key, word] of Object.entries(ARG_WORDS)) if (args[key] != null) words.push(`${word} ${args[key]}`);
  }
  return words.filter(Boolean).join(" · ") || ALL_OF[entry.tool] || "";
}

const SIZE_WORDS = [["projects", "project", "projects"], ["meetings", "meeting", "meetings"],
  ["next_steps", "next step", "next steps"], ["people", "person", "people"], ["lines", "line", "lines"]];

// How much a call sent out: "3 meetings · 12 lines · 18k chars".
export function mcpSizeText(out) {
  if (!out) return "";
  const words = SIZE_WORDS.filter(([key]) => out[key] != null)
    .map(([key, one, many]) => `${out[key]} ${out[key] === 1 ? one : many}`);
  if (out.chars != null) words.push(out.chars < 1000 ? `${out.chars} chars` : `${Math.round(out.chars / 1000)}k chars`);
  return words.join(" · ");
}

// What one call sent of a meeting it named.
function readParts(entry) {
  if (entry.tool === "get_meeting") return ["notes", transcriptPart(entry.args)];
  if (entry.tool === "search_meetings") return [`search “${entry.args?.query ?? ""}”`];
  if (entry.tool === "open_next_steps") return ["next steps"];
  return ["summary"];
}

// The meeting page's "Read by Claude Code today 14:02 (notes, transcript
// 0–20 min)": the last client that read it, when, and everything that client
// read of it that day. ``reads``: newest first; failed calls sent nothing.
export function mcpReadOf(reads) {
  const sent = (reads || []).filter((e) => !e.error);
  if (!sent.length) return null;
  const last = sent[0];
  const day = String(last.time).slice(0, 10);
  const parts = [];
  for (const e of sent) {
    if (e.client?.name !== last.client?.name || String(e.time).slice(0, 10) !== day) continue;
    for (const p of readParts(e)) if (p && !parts.includes(p)) parts.push(p);
  }
  const order = (p) => (p === "notes" ? 0 : /^(full )?transcript/.test(p) ? 1 : 2);
  return { client: last.client, time: last.time, parts: parts.sort((a, b) => order(a) - order(b)) };
}

// The access log, by client (its name) and by meeting (its id); "" or none: all.
export function filterLog(log, { client = "", meeting = "" } = {}) {
  return (log || []).filter((e) => (!client || e.client?.name === client)
    && (!meeting || (e.meetings || []).includes(meeting)));
}

// The access log as Settings shows it. Filtered by a meeting, its entries
// come from the server (``reads``: meeting id -> /api/mcp?meeting= answer),
// since they may be older than the newest 200; until they are loaded, what
// the log has of it.
export function logShown(log, reads, filter = {}) {
  if (filter.meeting && reads?.has(filter.meeting)) return filterLog(reads.get(filter.meeting), { client: filter.client });
  return filterLog(log, filter);
}

// The clients and meetings in the log, for its filters, in the log's order.
export function logClients(log) {
  const seen = new Map();
  for (const e of log || []) {
    if (e.client?.name && !seen.has(e.client.name)) seen.set(e.client.name, clientName(e.client, { version: false }));
  }
  return [...seen].map(([key, label]) => ({ key, label }));
}

export function logMeetings(log) {
  return [...new Set((log || []).flatMap((e) => e.meetings || []))];
}

export const clearedText = (n) => `Access log cleared · ${n} ${n === 1 ? "entry" : "entries"}`;

// --- attribution (#48) ------------------------------------------------------------

// How a link came about, as the server sends it: {kind, target, source,
// confidence, reason, unsure, label}. Links stored before reasons were kept
// have the source "unknown".
const SOURCE_TEXT = { you: "you", calendar: "time match", voice: "voice", inferred: "inferred", rules: "rules",
  model: "the model", email: "email address", imported: "imported" };
const KIND_TEXT = { event: "Event", project: "Project", speaker: "Speaker", org: "Organization" };

// "time match, 2 events overlapped": the reason, else what the source is called.
export function linkWhy(link) {
  if (!link) return "";
  return link.reason || SOURCE_TEXT[link.source] || "";
}

// The tooltip of a linked thing: what it is linked to and why, how sure, and
// what to do when Palaver is not sure.
export function linkTitle(link) {
  if (!link) return null;
  if (link.source === "unknown" && !link.reason) return `${link.label} · linked before Palaver kept reasons`;
  if (!link.unsure) return link.label;
  const sure = link.confidence == null ? "" : ` · ${Math.round(link.confidence * 100)}% sure`;
  return `${link.label}${sure}. Not sure: confirm or change it.`;
}

// A link the user just set: final, so never unsure.
export function yourLink(kind, target) {
  return { kind, target, source: "you", confidence: null, reason: "", unsure: false,
    label: `${KIND_TEXT[kind] || kind}: ${target} (you)` };
}

// What the event chip of a meeting shows: an event Palaver is unsure of and
// why, with ✓ and Change…, or the question which event it was, when several
// overlapped; null when neither. A sure event is no chip: the title or the
// quiet "Calendar:" line names it, and About this recording says how it was linked.
export function eventLinkView(m) {
  if (m.event_question?.choices?.length) {
    return { kind: "question", why: m.event_question.reason, choices: m.event_question.choices };
  }
  const link = m.calendar?.link;
  if (!link?.unsure) return null;
  return { kind: "link", title: m.calendar.title, why: linkWhy(link), unsure: true, canConfirm: true };
}

// The toast after the event was chosen: ``key`` null is "none of these",
// "current" a confirmation of the event it had.
export function eventChangeText(key, title) {
  if (key == null) return "Event changed to “none”";
  if (key === "current") return `Event confirmed: “${title}”`;
  return `Event changed to “${title}”`;
}

// --- memory (issue #49) -----------------------------------------------------------

const GB = 1024 ** 3;

// "5.4 GB", "12 GB", "317 MB": as the menu bar says it (memory.size_text).
export function sizeText(bytes) {
  if (bytes == null) return "—";
  if (bytes < GB) return `${Math.round(bytes / 2 ** 20)} MB`;
  const gb = bytes / GB;
  return gb >= 10 || Math.abs(gb - Math.round(gb)) < 0.05 ? `${Math.round(gb)} GB` : `${gb.toFixed(1)} GB`;
}

const MEMORY_KINDS = [
  ["live", "Live transcription"], ["stream", "Realtime transcription"], ["process", "Transcription"], ["notes", "Notes"],
  ["index", "Search index"],
];
const MEMORY_STATES = {
  running: "Running", "over budget": "Over budget", restarting: "Restarting", stopping: "Stopping",
  "waiting for memory": "Waiting for memory",
};

// One row per kind of worker for Settings: its state, what it uses of its
// budget and how full that is (0–1). Of two workers of a kind (one on its
// way out), the one using more shows.
export function memoryRows(mem) {
  if (!mem) return [];
  const budgets = mem.budgets || {};
  return MEMORY_KINDS.map(([kind, label]) => {
    const workers = (mem.workers || []).filter((w) => w.kind === kind);
    const w = workers.sort((a, b) => (b.used || 0) - (a.used || 0))[0];
    const budget = w?.budget ?? budgets[kind];
    if (!w) return { kind, label, state: "Not running", size: `Budget ${sizeText(budget * GB)}`, fill: 0, over: false };
    const state = MEMORY_STATES[w.state] || w.state;
    if (w.state === "waiting for memory") {
      return { kind, label, state, size: `Needs ${sizeText(w.need * GB)} free, ${sizeText(w.free * GB)} free now`,
        fill: 0, over: false };
    }
    const fill = budget ? Math.min(1, Math.round((w.used / (budget * GB)) * 100) / 100) : 0;
    return { kind, label, state, size: `${sizeText(w.used)} of ${sizeText(budget * GB)}`, fill,
      over: w.used > budget * GB };
  });
}

// "Palaver uses 5.4 GB now."; empty outside the menu bar app.
export function memoryTotalText(mem) {
  return mem && mem.total != null ? `Palaver uses ${sizeText(mem.total)} now.` : "";
}

// --- storage (#9) -------------------------------------------------------------------

// "Audio deleted on 2 Nov to free 180 MB"; the transcript and notes stayed.
export function audioDeletedText(d, fmt = (at) => at.toLocaleDateString("en-GB", { day: "numeric", month: "short" })) {
  const at = d.at ? new Date(d.at) : null;
  const on = at && !Number.isNaN(at.getTime()) ? ` on ${fmt(at)}` : "";
  return `Audio deleted${on}${d.bytes ? ` to free ${sizeText(d.bytes)}` : ""}`;
}

// "38 meetings take 5.2 GB, 5.0 GB of it audio."
export function storageTotalText(s) {
  if (!s) return "";
  const n = `${s.meetings} meeting${s.meetings === 1 ? "" : "s"}`;
  if (!s.meetings) return "No meetings yet.";
  return `${n} take${s.meetings === 1 ? "s" : ""} ${sizeText(s.bytes)}${s.audio_bytes ? `, ${sizeText(s.audio_bytes)} of it audio` : ", none of it audio"}.`;
}

// The choices for how long a transcribed meeting keeps its audio.
export function audioDaysLabel(days) {
  return days ? `After ${days} days` : "Never";
}

// What choosing ``days`` deletes right away; null when nothing is that old.
export function audioDaysConfirm(s, days) {
  const old = days ? s?.older?.[String(days)] : null;
  if (!old?.meetings) return null;
  return `The audio of ${old.meetings} meeting${old.meetings === 1 ? "" : "s"} older than ${days} days goes now (${sizeText(old.bytes)}). Their transcripts and notes stay, but they can't be played or transcribed again.`;
}

// Settings asks for the numbers again only while it is shown and the window
// is visible.
export function memoryPolling(view, hidden) {
  return view === "settings" && !hidden;
}

// --- the live coach (#41, #42) ---------------------------------------------------------

// The running recording's coach (who talks, the nudge), only on its own page while it records.
export function liveCoachFor(coach, m) {
  if (!coach || !m || coach.meeting !== m.id || !(m.status === "recording" || m.live)) return null;
  return coach;
}

export function speakingText(talk) {
  if (!talk) return null;
  return { me: "You're talking", others: "Others are talking", both: "Both talking" }[talk.speaking] || "Quiet";
}

// The button: which model answers and where ("Best next question (Gemma, on this Mac)"), off with the reason
// when none can (no model chosen, notes off), "Thinking…" while it answers. ``info``: GET …/next-question.
export function questionButton(info, q) {
  if (q?.loading) return { label: "Thinking…", disabled: true, reason: null };
  if (!info) return { label: "Best next question", disabled: true, reason: null };
  return { label: info.label, disabled: !info.ready, reason: info.ready ? null : info.reason };
}

// Under the suggested questions: which model, and that it keeps to what was said.
export function questionsNote(answer) {
  if (!answer.questions?.length) return `${answer.engine} found nothing in the transcript to ask about yet.`;
  return `${answer.engine} · from what was said and your prep only`;
}

// --- the setup assistant (#55) ---------------------------------------------------------

// The steps, in order: who you are (and the calendar), what Palaver recommends
// for this Mac as one package (Customize shows each choice), an optional test.
export const SETUP_STEPS = [
  { id: "you", title: "You and your calendar" },
  { id: "recommended", title: "Recommended for this Mac" },
  { id: "test", title: "Test recording" },
];
const stepIndex = (id) => SETUP_STEPS.findIndex((s) => s.id === id);

// The step after ``id`` (the first one for an unknown id), null after the last.
export function setupStepAfter(id) {
  const i = stepIndex(id);
  if (i < 0) return SETUP_STEPS[0].id;
  return SETUP_STEPS[i + 1]?.id ?? null;
}

export function setupStepBefore(id) {
  const i = stepIndex(id);
  return i > 0 ? SETUP_STEPS[i - 1].id : null;
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const canChoose = (r, value) => {
  const o = (r.options || []).find((x) => same(x.value, value));
  return !o || o.available !== false;
};

// "Use recommended": {id: value} for what differs from now. Not a choice that
// needs setting up first (a cloud model without a key), nor a warning (disk).
export function recommendedChanges(recs) {
  const out = {};
  for (const r of recs) {
    if (r.matches || r.id === "disk" || !canChoose(r, r.value)) continue;
    if (r.id.startsWith("claude_") && r.value !== true) continue;  // adding is a choice; leaving out changes nothing
    out[r.id] = r.value;
  }
  return out;
}

// A step's buttons: what the user picked under Customize ("Use these");
// else, when something set on purpose differs from the recommendation,
// "Keep current" first and "Use recommended" beside it (re-opening the
// assistant never undoes a deliberate choice); else "Use recommended", or
// "Continue" when nothing would change.
export function stepButtons(recs, picks) {
  const chosen = chosenChanges(recs, picks);
  if (Object.keys(chosen).length) return { primary: { label: "Use these", changes: chosen }, secondary: null };
  const recommended = recommendedChanges(recs);
  if (!Object.keys(recommended).length) return { primary: { label: "Continue", changes: {} }, secondary: null };
  if (recs.some((r) => r.chosen && !r.matches && Object.hasOwn(recommended, r.id))) {
    return { primary: { label: "Keep current", changes: {} }, secondary: { label: "Use recommended", changes: recommended } };
  }
  return { primary: { label: "Use recommended", changes: recommended }, secondary: null };
}

// "Customize": the user's picks ({id: value}) that differ from now.
export function chosenChanges(recs, picks) {
  const out = {};
  for (const r of recs) {
    if (Object.hasOwn(picks || {}, r.id) && !same(picks[r.id], r.current)) out[r.id] = picks[r.id];
  }
  return out;
}

export function gbText(gb) {
  if (gb < 1) return `${Math.round(gb * 100) * 10} MB`;
  const tenths = Math.round(gb * 10) / 10;
  return Number.isInteger(tenths) ? `${tenths} GB` : `${tenths.toFixed(1)} GB`;
}

const andList = (items) => (items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`);

export function downloadsText(needed) {
  if (!needed?.length) return "Nothing to download: every model is on this Mac.";
  const total = needed.reduce((sum, m) => sum + m.disk_gb, 0);
  return `${andList(needed.map((m) => `${m.label} (${gbText(m.disk_gb)})`))}: ${gbText(Math.round(total * 100) / 100)} in all`;
}

// 0..1 across every download started.
export function downloadProgress(status) {
  const models = status?.models || [];
  const total = models.reduce((sum, m) => sum + m.disk_gb, 0);
  if (!total) return 0;
  return Math.round((models.reduce((sum, m) => sum + Math.min(m.done_gb, m.disk_gb), 0) / total) * 100) / 100;
}

const PERMISSION_STATUS = { granted: "ok", denied: "fail", fallback: "warn" };
export function permissionText(p) {
  if (!p) return { status: "warn", text: "not checked" };
  return { status: PERMISSION_STATUS[p.state] || "warn", text: p.detail || p.state.replace(/_/g, " ") };
}

// Settings: "Recommended for this Mac" beside a switch (the same
// recommendations the assistant shows).
export function recommendedHint(recs, id) {
  const r = (recs || []).find((x) => x.id === id);
  if (!r) return null;
  if (r.matches) return null;  // followed already: a green "Recommended" under every switch was noise
  return { matches: false, text: `Recommended for this Mac: ${r.label}. ${r.reason}` };
}

// The toast when the window offers the assistant again; null for the first
// start (the assistant just opens) or nothing to say.
export function setupOfferText(offer, labels = {}) {
  if (!offer) return null;
  if (offer.why === "changed") return `This is another Mac (${offer.now}). Review the recommended settings?`;
  if (offer.why === "missing") {
    const names = offer.models.map((m) => labels[m] || m);
    return `${andList(names)} ${names.length === 1 ? "is" : "are"} not downloaded yet.`;
  }
  return null;
}

export function testRecordingText(status) {
  switch (status?.state) {
    case "recording": return `Recording · ${Math.floor(status.seconds || 0)} s. Say a sentence, then click Stop.`;
    case "checking": return "Checking both tracks…";
    case "failed": return status.error || "The test failed.";
    case "aborted": return status.error || "A call started, so the test stopped.";
    default: return "";
  }
}

// Glossary terms from the calendar that start ticked: none. Only the
// user's explicit "Add N terms" adds them.
export function seedChecked(terms) {
  return new Set();
}

export function optionLabel(r, o) {
  const marks = [same(o.value, r.value) ? "recommended" : null, same(o.value, r.current) ? "now" : null].filter(Boolean);
  return marks.length ? `${o.label} · ${marks.join(", ")}` : o.label;
}

// --- Today and "Needs you" (UI spec, phase 2) -----------------------------------------

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const QUESTIONS = new Set(["which_event", "event", "no_event", "cut", "unnamed", "speaker", "project"]);
const isQuestion = (item) => QUESTIONS.has(item.kind);

// The strip at the top of a meeting: "3 things to check" and what they are;
// null when nothing but its review is open. ``lead``: the count, left out when
// there is one part only ("1 voice without a name" says it). ``targets``: for
// each part, the control on the page that answers it (the first of its kind).
export function needsSummary(items) {
  const open = (items || []).filter(isQuestion);
  if (!open.length) return null;
  const of = (kind) => open.filter((i) => i.kind === kind);
  const n = (kind) => of(kind).length;
  const parts = [];
  const add = (text, target) => parts.push({ text, target });
  if (n("which_event") || n("no_event")) add(n("which_event") ? "which event?" : "no calendar event", { kind: "event" });
  if (n("event")) add("event to confirm", { kind: "event" });
  for (const cut of of("cut")) add(`may run into “${cut.event}”`, { kind: "cut", at: cut.at });
  if (n("unnamed")) add(plural(n("unnamed"), "voice without a name", "voices without a name"), { kind: "unnamed", label: of("unnamed")[0].label });
  if (n("speaker")) add(n("speaker") === 1 ? "a name to confirm" : `${n("speaker")} names to confirm`, { kind: "speaker", label: of("speaker")[0].label });
  if (n("project")) add(n("project") === 1 ? "project to confirm" : `${n("project")} projects to confirm`, { kind: "project", project: of("project")[0].project });
  const text = plural(open.length, "thing to check", "things to check");
  return { count: open.length, text, lead: parts.length > 1 ? text : null,
    parts: parts.map((p) => p.text), targets: parts.map((p) => p.target) };
}

const itemId = (item) => item.label ?? item.project ?? item.at ?? "";

// The cards Today shows (at most ``cap``): every question, newest meeting
// first; a meeting with none asks once whether it came out right. ``more``:
// the cards left out.
export function needCards(needs, cap = 8) {
  const all = [];
  for (const meeting of needs?.meetings || []) {
    const open = meeting.items.filter(isQuestion);
    const items = open.length ? open : meeting.items.filter((i) => i.kind === "review");
    for (const item of items) all.push({ key: `${meeting.id}|${item.kind}|${itemId(item)}`, meeting, item });
  }
  return { cards: all.slice(0, cap), more: Math.max(0, all.length - cap) };
}

function talkText(seconds) {
  return seconds < 60 ? `${Math.round(seconds)} s of talk` : `${Math.round(seconds / 60)} min of talk`;
}

// What a card asks, plainly; the meeting it is about is named above it.
export function needQuestion(item) {
  switch (item.kind) {
    case "unnamed": return { text: `Who is ${item.display}?`, detail: talkText(item.talk_seconds || 0) };
    case "speaker": return { text: `Is ${item.display} ${item.name}?`, detail: item.why || "" };
    case "project": return { text: `Part of ${item.name}?`, detail: item.why || "" };
    case "which_event": return { text: "Which calendar event was it?", detail: item.reason || "" };
    case "event": return { text: `Was it “${item.title}”?`, detail: item.why || "" };
    case "no_event": return { text: "Which calendar event was it?", detail: "None is linked yet" };
    case "cut": return { text: `Runs into “${item.event}” at ${clock(item.at)}?`, detail: item.why || "" };
    default: return { text: "Did it come out right?", detail: "Nothing open, not reviewed yet" };
  }
}

// "In 25 min", "Now" while it runs; null when it is over or not within 12 hours.
export function startsInText(start, end, now = new Date()) {
  const toStart = (new Date(start) - now) / 60000;
  if ((new Date(end) - now) <= 0) return null;
  if (toStart <= 0) return "Now";
  if (toStart > 12 * 60) return null;
  const min = Math.max(1, Math.round(toStart));
  if (min < 60) return `In ${min} min`;
  return min % 60 ? `In ${Math.floor(min / 60)} h ${min % 60} min` : `In ${min / 60} h`;
}

// The counter on Today in the top bar: the meetings waiting for the user.
export function navCount(needs) {
  const n = needs?.count || 0;
  if (!n) return null;
  return n > 99 ? "99+" : String(n);
}

// Split by hovering the ribbon: the line start nearest the pointer
// (``fraction`` of the way through), never the first line (nothing before it).
export function cutAtPointer(fraction, duration, lines) {
  if (!lines || lines.length < 2) return null;
  const t = Math.max(0, Math.min(1, fraction)) * duration;
  let best = 1;
  for (let i = 2; i < lines.length; i++) {
    if (Math.abs(lines[i].start - t) < Math.abs(lines[best].start - t)) best = i;
  }
  return { at: lines[best].start, i: best };
}

// --- the ⌘K palette ------------------------------------------------------------------

const folded = (s) => String(s || "").normalize("NFKD").replace(/[̀-ͯ]/g, "")
  .replace(/ß/g, "ss").toLocaleLowerCase();
const wordsOf = (s) => folded(s).split(/[^\p{L}\p{N}]+/u).filter(Boolean);
const KIND_RANK = { command: 0, page: 1, setting: 2, meeting: 3, person: 4, project: 5 };

// What the palette finds for ``query``: every word typed starts a word of
// the label or of its keywords (people, projects). A label that starts with
// it comes first, then a label match, then a keyword match; in each, the
// commands first, then the order given (meetings newest first).
export function paletteMatch(query, entries, limit = 30) {
  const q = wordsOf(query);
  if (!q.length) return [];
  const found = [];
  entries.forEach((e, at) => {
    const label = wordsOf(e.label);
    const keys = (e.keywords || []).flatMap(wordsOf);
    const inLabel = q.every((w) => label.some((x) => x.startsWith(w)));
    if (!inLabel && !q.every((w) => label.some((x) => x.startsWith(w)) || keys.some((x) => x.startsWith(w)))) return;
    const score = folded(e.label).startsWith(q.join(" ")) ? 0 : inLabel ? 1 : 2;
    found.push({ e, score, rank: KIND_RANK[e.kind] ?? 9, at });
  });
  found.sort((a, b) => a.score - b.score || a.rank - b.rank || a.at - b.at);
  return found.slice(0, limit).map((x) => x.e);
}

const PALETTE_COMMANDS = ["play", "transcribe", "writeNotes", "rename", "changeEvent", "joinPrevious", "joinNext", "split", "reviewAgain",
  "export", "localOnly", "shared", "forgetSeries", "report", "deleteAudio", "trash"];

// The open meeting's commands that apply now, with their shortcuts.
export function paletteCommands(m) {
  if (!m) return [];
  const c = meetingCommands(m);
  return PALETTE_COMMANDS.filter((name) => c[name].enabled).map((name) => ({
    kind: "command", id: name, label: c[name].paletteLabel || c[name].label, shortcut: c[name].shortcut,
    danger: !!c[name].danger,
  }));
}

// The places opened lately, newest first, each once; commands are no places.
export function paletteRecent(recent, entry, max = 8) {
  if (entry.kind === "command") return recent || [];
  const same = (x) => x.kind === entry.kind && x.id === entry.id;
  return [entry, ...(recent || []).filter((x) => !same(x))].slice(0, max);
}

// The arrows move through the results and wrap around; -1 when there are none.
export function paletteMove(at, delta, count) {
  if (!count) return -1;
  if (at < 0) return delta > 0 ? 0 : count - 1;
  return (at + delta + count) % count;
}

// The recent places the palette shows before typing: meetings as the list
// has them now, people and projects only while they exist (``people``:
// names, ``projects``: ids); at most ``max``.
export function paletteRecentShown(recent, { meetings = [], people = [], projects = [] }, max = 6) {
  const names = new Set(people);
  const ids = new Set(projects);
  return (recent || []).map((r) => {
    if (r.kind === "meeting") return meetings.find((x) => x.id === r.id) || null;
    if (r.kind === "person") return names.has(r.id) ? r : null;
    if (r.kind === "project") return ids.has(r.id) ? r : null;
    return r;
  }).filter(Boolean).slice(0, max);
}

// The page's heartbeat while the window's server may be restarting (#57):
// ``show(true)`` once a ping got no answer for 2 s (or failed), ``show(false)``
// when one answers. One ping at a time: a hanging one decides.
export const RECONNECT_AFTER_MS = 2000;
export function heartbeat({ fetch, show, setTimeout, clearTimeout, path = "/api/ping" }) {
  let pending = false;
  return function beat() {
    if (pending) return undefined;
    pending = true;
    const late = setTimeout(() => show(true), RECONNECT_AFTER_MS);
    return (async () => {
      try {
        const resp = await fetch(path, { cache: "no-store" });
        clearTimeout(late);
        show(!resp.ok);
      } catch {
        clearTimeout(late);
        show(true);
      } finally {
        pending = false;
      }
    })();
  };
}

// Notes being written that this page did not start, from /api/model-jobs
// (#57: after the server restarted and the page reloaded): which meetings to
// show as being written now (``start``), and which of those ended (``end``).
// ``writing``: meeting id -> {remote}; ``jobs`` null: no answer, as it was.
export function notesFromJobs(jobs, writing) {
  if (!jobs) return { start: [], end: [] };
  const running = new Map((jobs.running || []).filter((j) => j.kind === "notes").map((j) => [j.key, j]));
  const start = [...running.values()].filter((j) => !writing.has(j.key))
    .map((j) => ({ id: j.key, startedAt: (j.started || 0) * 1000 }));
  const end = [...writing].filter(([id, w]) => w.remote && !running.has(id)).map(([id]) => id);
  return { start, end };
}

// --- export and import (#58) ---------------------------------------------------------

// What the export dialog offers for ``m``, and what is ticked at first: the
// transcript and names always go; the voices (biometric) and the audio only
// when asked; the notes unless they were written with the user's own notes
// in view (what those say may show through).
export function exportChoices(m) {
  const mine = !!m?.notes_from_my_notes;
  return [
    { key: "transcript", label: "Transcript and names", always: true },
    { key: "notes", label: "Notes", on: !mine, hint: mine
      ? "The summary was written with your own notes in view: what they say may show through. Your own notes never go."
      : "Summary, topics, next steps and decisions. Your own notes never go." },
    { key: "voices", label: "Voices of the named people", on: false,
      hint: "Biometric data: with it, their Mac recognizes these people in its own meetings." },
    { key: "audio", label: "Audio", on: false, hint: "Large, and the most sensitive part." },
  ];
}

// The body of the export request from the ticked boxes.
export function exportRequest(ticked, confirmLocal = false) {
  return { notes: !!ticked.notes, voices: !!ticked.voices, audio: !!ticked.audio,
    ...(confirmLocal ? { confirm_local: true } : {}) };
}

// The toast once the file is saved.
export function exportedText(answer) {
  return `Saved to ${answer.folder || "Downloads"}: “${answer.name}”`;
}

// Whether a dropped or picked file is one to import.
export const isMeetingZip = (name) => /\.zip$/i.test(String(name || ""));

// The question when the meeting in the file is here already (phase 1: keep
// mine, or import it beside it).
export function collisionText(q) {
  const whose = q.own ? "You recorded this meeting yourself" : "This meeting was imported before";
  return `${whose}: “${q.meeting.title}”. Keep yours, or add ${q.from}’s recording as a separate meeting beside it?`;
}

// The toast after an import, with Undo.
export function importedText(title, answer) {
  const left = (answer.warnings || []).join(" ");
  return `“${title}” imported from ${answer.from}${left ? ` · ${left}` : ""}`;
}

// The quiet line on an imported meeting: from whom and when, and the
// exporter's projects (a hint: projects are sorted here).
export function importedLine(imported, fmt = (d) => d.toLocaleDateString("en-GB", { day: "numeric", month: "short" })) {
  if (!imported) return null;
  const at = imported.at ? new Date(imported.at) : null;
  const when = at && !Number.isNaN(at.getTime()) ? `, ${fmt(at)}` : "";
  const filed = imported.projects?.length ? ` · ${imported.from} filed it under ${andList(imported.projects)}` : "";
  return `Imported from ${imported.from}${when}${filed}`;
}

// The question about the voices that came with an import.
export function voicesQuestion(voices, from) {
  if (!voices?.length) return null;
  const names = andList(voices.map((v) => v.name));
  return `${from} sent the voices of ${names}. Add them to your voice bank? Palaver then recognizes `
    + `${voices.length === 1 ? "this person" : "them"} in your own meetings, and the names here count as confirmed.`;
}

// How an inferred name came about, as the lane says it; one from an import
// says who named the speaker.
const INFERRED_RULES = { calendar: "from the calendar", elimination: "by elimination", intersection: "across meetings",
  voice: "same voice" };
const IMPORTED_HOW = { hand: (by) => `named by ${by}`, voice: (by) => `${by}’s voice match`,
  inferred: (by) => `${by}’s guess`, exporter: (by) => `${by}’s microphone` };
export function inferredText(inferred) {
  if (!inferred) return "";
  if (inferred.rule === "imported") {
    if (!inferred.by) return "imported";
    return (IMPORTED_HOW[inferred.how] || IMPORTED_HOW.hand)(inferred.by);
  }
  return INFERRED_RULES[inferred.rule] || "inferred";
}

// Commands that need no open meeting, for ⌘K.
// Settings' panes, in the list's order (#/settings/<id>); Help is in General.
export const SETTINGS_PANES = [
  ["general", "General"], ["recording", "Recording"], ["calendar", "Calendar"], ["notifications", "Notifications"],
  ["transcription", "Transcription"], ["language-model", "Language Model"], ["search", "Search"],
  ["storage", "Storage"], ["memory", "Memory"], ["mcp", "Claude Access"], ["update", "Updates"],
];
// What each pane is found by in the palette, besides its name: the settings in it.
const PANE_WORDS = {
  general: ["setup", "assistant", "help", "report", "problem", "feedback"],
  recording: ["teams", "slack", "huddle", "automatic", "realtime", "live", "coach", "nudge", "monologue", "process"],
  calendar: ["events", "invitees", "microsoft", "365", "outlook", "google", "exchange"],
  notifications: ["notification", "alerts", "banner", "system"],
  transcription: ["parakeet", "soniox", "cloud", "speech", "service", "key"],
  "language-model": ["notes", "llm", "gemma", "anthropic", "claude", "openai", "provider", "api", "key", "cloud", "model"],
  search: ["meaning", "semantic", "index"],
  storage: ["disk", "space", "audio", "delete", "models", "size", "gb", "free"],
  memory: ["ram", "budget", "workers"],
  mcp: ["mcp", "claude", "desktop", "code", "access", "log"],
  update: ["updates", "version", "uninstall", "release", "check"],
};

// The palette's entries for the panes: "Storage" opens Settings at Storage.
export function settingsEntries() {
  return SETTINGS_PANES.map(([id, label]) => ({ kind: "setting", id, label, detail: "Settings",
    keywords: ["settings", "preferences", ...(PANE_WORDS[id] || [])] }));
}

// Links from before the panes name a section of the one long page.
const PANE_OF = { live: "recording", coach: "recording", help: "general", updates: "update", setup: "general" };

// The pane to show for ``asked`` (a pane, an older section name, or nothing).
export function settingsPane(asked) {
  if (SETTINGS_PANES.some(([id]) => id === asked)) return asked;
  return PANE_OF[asked] || "general";
}

export const GLOBAL_COMMANDS = [{ kind: "command", id: "importMeeting", label: "Import Meeting…", detail: "Command",
  keywords: ["palaver", "file", "colleague"] }];

// --- Report a Problem (#59) ---------------------------------------------------------

// The meeting the report form starts with: the one asked for ("none": none), else the open one, else
// the one opened last, else the newest; null when there is none.
export function reportMeeting(asked, { open = null, last = null, meetings = [] } = {}) {
  if (asked === "none") return null;
  const ids = new Set(meetings.map((m) => m.id));
  for (const id of [asked, open, last]) if (id && ids.has(id)) return id;
  return meetings.map((m) => m.id).sort().at(-1) ?? null;
}

// "What happened?", begun for the tester who came from an error: Palaver's own words.
export const reportDraft = (said) => (said ? `Palaver said: “${said}”\n\n` : "");

// The toast once the zip is written (it is shown in Finder too).
export const reportDoneText = (r) => `Report saved to ${r.shown} · ${r.size_text}`;

// Every window action there is, "<scope>.<name>", from the command lists above:
// the usage summary's "never used". The made-up meeting asks each list for all it can offer.
export function actionCatalog() {
  const m = { status: "ready", has_audio: true, notes: {}, reviewed: "x", neighbours: { previous: "a", next: "b" },
    transcript: [{}, {}], shared: { series: { remembered: true } }, speakers: [{ label: "A" }, { label: "B" }] };
  const lane = { label: "A", name: "Tom", named_by: "voice", clips: [1] };
  const named = (scope, cmds) => cmds.filter(Boolean).map((c) => `${scope}.${c.name}`);
  return [...new Set([
    ...Object.keys(meetingCommands(m)).map((n) => `meeting.${n}`),
    ...named("lane", [...laneCommands(m, lane), ...laneCommands(m, { label: "B" }),
      ...laneCommands(m, { is_user: true, shared: "lane" })]),
    ...named("line", lineCommands(m, 1, true)),
    ...named("project", projectCommands({ projects: [{ id: "a" }, { id: "b" }] }, { id: "a" })),
    ...named("person", personCommands({ meetings: [{ clip: 1 }] })),
    ...named("voice", voiceCommands({ voices: [{ clip: 1 }] })),
    ...named("term", termCommands()),
  ])].sort();
}

// --- updates (#60) ----------------------------------------------------------------------

// What Settings says about updates, from update.json: { text, action } where
// action is the button ("install", "check") or null. Quiet: one line.
const hhmm = (at) => at.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

export function updateView(u, fmt = hhmm) {
  const state = u?.state || "unsupported";
  const version = u?.available?.version;
  const size = u?.available?.download_bytes ? ` (${sizeText(u.available.download_bytes)})` : "";
  switch (state) {
    case "available":
      return { text: `Palaver ${version} is available${size}. You have ${u.current}.`, action: "install" };
    case "downloading": {
      const total = u.available?.download_bytes || 0;
      const share = total ? ` ${Math.min(99, Math.floor((100 * (u.done_bytes || 0)) / total))} %` : "";
      return { text: `Downloading Palaver ${version}…${share}`, action: null };
    }
    case "ready":
      return { text: u.waiting_for
        ? `Palaver ${version} installs when Palaver is idle (now: ${u.waiting_for}).`
        : `Installing Palaver ${version}…`, action: null };
    case "installing":
      return { text: `Installing Palaver ${version}: Palaver restarts.`, action: null };
    case "failed":
      return { text: u.error || "The update failed; this version stays.", action: version ? "install" : "check" };
    case "up_to_date":
      // When it looked: a release out since then shows at the next look (hourly, or Check now).
      return { text: `Palaver ${u.current} is the latest version${u.checked_at ? ` (checked at ${fmt(new Date(u.checked_at * 1000))})` : ""}.`,
        action: "check" };
    case "idle":
    case "checking":
      return { text: u.check_error ? `Palaver ${u.current}. Could not look for updates: ${u.check_error}`
        : `Palaver ${u.current || ""}`.trim() + ".", action: "check" };
    default:
      return { text: "Updates come with an installed Palaver (install.sh); this one runs from a checkout.", action: null };
  }
}

// The top bar's "Update to 0.2.0": while there is one to install or one installing;
// nothing while up to date (Settings says that).
export function updateIndicator(u) {
  const version = u?.available?.version;
  if (!version) return null;
  const { text: title } = updateView(u);
  const total = u.available.download_bytes || 0;
  const text = {
    available: `Update to ${version}`,
    downloading: total ? `Updating · ${Math.min(99, Math.floor((100 * (u.done_bytes || 0)) / total))} %` : "Updating…",
    ready: u.waiting_for ? "Update waits" : "Updating…",
    installing: "Updating…",
    failed: "Update failed",
  }[u.state];
  return text ? { text, title } : null;
}

// Today's card about a new release: while it waits for a click (available, or failed and to be tried again).
export function updateCard(u) {
  const version = u?.available?.version;
  if (!version || !["available", "failed"].includes(u.state)) return null;
  return {
    title: `Palaver ${version} is available`,
    text: u.state === "failed" ? (u.error || "The update failed; this version stays.")
      : `You have ${u.current}. It installs once Palaver is idle; nothing is lost.`,
  };
}

// --- one person, one look (UI cleanup 2026-10-30) ---------------------------------------

// A named person's colour, one of the eight speaker colours (--v0…--v7),
// from the name alone: the same in every meeting, on every page. FNV-1a over
// the name in lower case with single spaces, mixed as MurmurHash3 finishes
// (FNV's low bits alone spread names badly); pinned by the tests, as a change
// would repaint everyone.
export function personHue(name) {
  let h = 0x811c9dc5;
  for (const ch of String(name ?? "").trim().replace(/\s+/g, " ").toLowerCase()) {
    h ^= ch.codePointAt(0);
    h = Math.imul(h, 0x01000193);
  }
  h ^= h >>> 16;
  h = Math.imul(h, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h, 0xc2b2ae35);
  h ^= h >>> 16;
  return (h >>> 0) % 8;
}

// The colour a name shows in, the violet of "you" for the user's own
// (``you``: the user's name, when known); null without a name.
export function personColor(name, you = null) {
  if (!String(name ?? "").trim()) return null;
  if (you && sameTitle(name, you)) return "var(--you)";
  return `var(--v${personHue(name)})`;
}

const PALETTE = [0, 1, 2, 3, 4, 5, 6, 7].map((i) => `var(--v${i})`);
const laneKey = (s) => s.label ?? "__you";

// Each lane's colour (key: the label, "__you" for the user's): the person's
// for a named voice, violet for the user. An unnamed voice, or several
// people on one microphone, takes a colour of the meeting no named person
// of it has; ``cache`` (one per open meeting) keeps that colour while the
// meeting stays open, so a merge, a removal or a name given elsewhere
// repaints no other lane.
export function laneColors(speakers, cache) {
  const out = new Map();
  for (const s of speakers) {
    if (s.is_user) out.set(laneKey(s), "var(--you)");
    else if (s.name && !s.shared) out.set(laneKey(s), personColor(s.name));
  }
  const named = new Set(out.values());
  for (const s of speakers) {
    const key = laneKey(s);
    if (out.has(key)) continue;
    if (!cache.has(key)) {
      const used = new Set([...named, ...cache.values()]);
      cache.set(key, PALETTE.find((c) => !used.has(c)) || PALETTE.find((c) => !named.has(c)) || PALETTE[cache.size % 8]);
    }
    out.set(key, cache.get(key));
  }
  return out;
}

const firstName = (name) => String(name ?? "").trim().split(/\s+/)[0];

// The named voice of the meeting an invitee is: the same name, or their first
// name alone when no other invitee has it ("Anna" for Anna Berger).
function speakerOf(a, m) {
  const voices = (m.speakers || []).filter((s) => s.name && !s.is_user && !s.shared);
  const same = voices.find((s) => sameTitle(s.name, a.name));
  if (same) return same;
  const first = firstName(a.name);
  if (!first || sameTitle(first, a.name)) return null;
  const sharing = (m.calendar?.attendees || []).filter((x) => sameTitle(firstName(x.name), first));
  return sharing.length === 1 ? voices.find((s) => sameTitle(s.name, first)) || null : null;
}

// The header's people: the invitees, as tokens. Who spoke (a named voice of the
// meeting) comes first, in their lane's colour; who did not has no colour (a
// grey outline). The user's own organization is left out, another goes into
// the tooltip; who declined and did not speak is not listed.
export function attendeeTokens(m) {
  const own = (m.speakers || []).find((s) => s.is_user)?.org;
  const tokens = [];
  for (const a of m.calendar?.attendees || []) {
    const voice = speakerOf(a, m);
    if (!voice && a.response === "declined") continue;
    const about = [a.name];
    if (a.org && !(own && sameTitle(a.org, own))) about.push(a.org);
    if (a.organizer) about.push("organized it");
    if (a.response === "declined") about.push("declined");
    if (!voice) about.push("invited, no named voice");
    tokens.push({ name: a.name, spoke: !!voice, color: voice ? personColor(voice.name) : null, title: about.join(" · ") });
  }
  return [...tokens.filter((t) => t.spoke), ...tokens.filter((t) => !t.spoke)];
}

// The named people of a meeting and their colours (name → colour): the user,
// the named voices, and the invitees they are by full name. What the notes
// and the transcript mark, and whom a next step's owner can be.
export function meetingPeople(m) {
  const out = new Map();
  const you = (m.speakers || []).find((s) => s.is_user)?.name;
  for (const s of m.speakers || []) {
    if (s.name && !s.shared && !out.has(s.name)) out.set(s.name, personColor(s.name, you));
  }
  for (const a of m.calendar?.attendees || []) {
    const voice = speakerOf(a, m);
    if (voice && !out.has(a.name)) out.set(a.name, out.get(voice.name));
  }
  return out;
}

// Who a next step is for, as tokens: a person of the meeting, several ("Anna
// and Carla"), or, when that is not it, the words as written with no colour.
export function ownerTokens(owner, people) {
  const text = String(owner ?? "").trim();
  if (!text) return [];
  const find = (name) => [...people].find(([known]) => sameTitle(known, name));
  const whole = find(text);
  if (whole) return [{ name: whole[0], color: whole[1] }];
  const parts = text.split(/\s*(?:,|&|\+|\/|\band\b|\bund\b)\s*/u).filter(Boolean);
  const found = parts.map(find);
  if (parts.length > 1 && found.every(Boolean)) return found.map(([name, color]) => ({ name, color }));
  return [{ name: text, color: null }];
}

// Where the names of ``people`` (name → colour) stand in ``text``: exact,
// as whole words, the longest name first; [{a, b, name, color}].
export function nameMarks(text, people) {
  const names = [...(people?.keys() || [])].filter(Boolean).sort((x, y) => y.length - x.length);
  if (!text || !names.length) return [];
  const re = new RegExp(`(?<![\\p{L}\\p{N}])(?:${names.map(escapeRe).join("|")})(?![\\p{L}\\p{N}])`, "gu");
  return [...text.matchAll(re)].map((x) => ({ a: x.index, b: x.index + x[0].length, name: x[0], color: people.get(x[0]) }));
}

// The projects beside the people. With a project the user confirmed, the
// suggestions leave the row for the top of the "+ Project" picker; without,
// the best one stays as a dashed chip. ``picker``: the suggestions left, then
// every other project not on the meeting.
export function projectView(m) {
  const on = new Set((m.projects || []).map((p) => p.id));
  const suggestions = (m.project_suggestions || []).filter((s) => !on.has(s.id));
  const confirmed = (m.projects || []).some((p) => p.by === "you");
  const shown = confirmed ? [] : suggestions.slice(0, 1);
  const offered = new Set(suggestions.map((s) => s.id));
  return {
    suggestions: shown,
    picker: [
      ...suggestions.slice(shown.length).map((s) => ({ id: s.id, name: s.name, why: s.why, suggested: true })),
      ...(m.all_projects || []).filter((p) => !on.has(p.id) && !offered.has(p.id))
        .map((p) => ({ id: p.id, name: p.name, suggested: false })),
    ],
  };
}

// "About this recording", folded away at the bottom of the meeting: how it
// started and stopped (#47), how the event was linked, who transcribed it
// (#54), what went wrong with its audio (#50), where it was imported from
// (#58). While it records, its own line and warnings stay in the header.
// What Claude read of it (#45) is added by the page.
export function aboutLines(m, recording, fmt = null) {
  const live = m.status === "recording" || !!m.live;
  const lines = [];
  if (!live && m.recorded) lines.push({ kind: "recorded", text: m.recorded });
  const link = m.calendar?.link;
  if (link && !link.unsure && !m.event_question?.choices?.length) lines.push({ kind: "event", text: linkTitle(link) });
  const transcribed = transcribedText(m.transcribed_by);
  if (transcribed) lines.push({ kind: "transcribed", text: transcribed });
  if (!live) for (const text of audioWarnings(m, recording)) lines.push({ kind: "audio", text });
  const imported = fmt ? importedLine(m.imported, fmt) : importedLine(m.imported);
  if (imported) lines.push({ kind: "imported", text: imported });
  if (m.audio_deleted) lines.push({ kind: "deleted", text: fmt ? audioDeletedText(m.audio_deleted, fmt) : audioDeletedText(m.audio_deleted) });
  return lines;
}
