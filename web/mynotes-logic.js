// The user's own notes (#44), without the page: light markdown (lists and
// **bold**) read into plain data — the page builds text nodes from it, never
// HTML from what the user wrote — and what Enter and ⌘B do to a paragraph.
//
// Node imports this file for the unit tests (tests/js/).

import { clock } from "./logic.js";

const BOLD = /\*\*(?=\S)([^\n]*?\S)\*\*/g;
const BULLET = /^(\s*)([-*•])\s+(.*)$/;
const NUMBERED = /^(\s*)(\d{1,4})([.)])\s+(.*)$/;

// A line's text in pieces, bold or not; ``src`` is where a piece's text starts in the paragraph
// (for putting the caret where the user clicked).
export function inline(text, offset = 0) {
  const out = [];
  let at = 0;
  for (const m of text.matchAll(BOLD)) {
    if (m.index > at) out.push({ text: text.slice(at, m.index), bold: false, src: offset + at });
    out.push({ text: m[1], bold: true, src: offset + m.index + 2 });
    at = m.index + m[0].length;
  }
  if (at < text.length || !out.length) out.push({ text: text.slice(at), bold: false, src: offset + at });
  return out;
}

// A paragraph as blocks: {type: "p", lines: [pieces]}, {type: "ul" | "ol", start, items: [{level, segments}]}.
// An empty line ends a paragraph.
export function parseNote(text) {
  const blocks = [];
  let offset = 0;
  let current = null;
  for (const line of text.split("\n")) {
    const bullet = BULLET.exec(line);
    const numbered = !bullet && NUMBERED.exec(line);
    if (bullet || numbered) {
      const type = bullet ? "ul" : "ol";
      const [indent, content] = bullet ? [bullet[1], bullet[3]] : [numbered[1], numbered[4]];
      if (current?.type !== type) {
        current = { type, start: numbered ? Number(numbered[2]) : 1, items: [] };
        blocks.push(current);
      }
      const level = Math.min(3, Math.floor(indent.replace(/\t/g, "  ").length / 2));
      current.items.push({ level, segments: inline(content, offset + line.length - content.length) });
    } else if (!line.trim()) {
      current = null;
    } else {
      if (current?.type !== "p") {
        current = { type: "p", lines: [] };
        blocks.push(current);
      }
      current.lines.push(inline(line, offset));
    }
    offset += line.length + 1;
  }
  return blocks;
}

// The list marker a line starts with, and the next item's: "- " → "- ", "9. " → "10. ".
function listMarker(line) {
  const bullet = BULLET.exec(line) || /^(\s*)([-*•])\s*$/.exec(line);
  if (bullet) return { marker: line.slice(0, line.length - (bullet[3] ?? "").length), next: `${bullet[1]}${bullet[2]} `,
    empty: !(bullet[3] ?? "").trim() };
  const numbered = NUMBERED.exec(line) || /^(\s*)(\d{1,4})([.)])\s*$/.exec(line);
  if (numbered) return { marker: line.slice(0, line.length - (numbered[4] ?? "").length),
    next: `${numbered[1]}${Number(numbered[2]) + 1}${numbered[3]} `, empty: !(numbered[4] ?? "").trim() };
  return null;
}

// Enter with the selection start..end: the paragraph keeps what is before it, a new one starts with what
// is after (``caret`` in it). In a list the new one is the next item; Enter on an empty item ends the list
// instead (``next`` null: no new paragraph, ``caret`` in the current one).
export function splitAt(text, start, end) {
  const before = text.slice(0, start);
  const after = text.slice(end);
  const lineStart = before.lastIndexOf("\n") + 1;
  const list = listMarker(before.slice(lineStart));
  if (list?.empty && !after.trim()) {
    const current = before.slice(0, lineStart).replace(/\n$/, "");
    return { current, next: null, caret: current.length };
  }
  if (list) {
    const rest = after.replace(/^\s+/, "");
    const own = listMarker(rest.split("\n")[0]);  // the next item is already there: no second marker
    if (own && !own.empty && rest.startsWith(own.marker)) return { current: before, next: rest, caret: own.marker.length };
    return { current: before, next: list.next + rest, caret: list.next.length };
  }
  return { current: before, next: after, caret: 0 };
}

// ⌘B: the selection in ** **, or out of them when it already is.
export function toggleBold(text, start, end) {
  if (text.slice(start - 2, start) === "**" && text.slice(end, end + 2) === "**" && end > start) {
    return { text: text.slice(0, start - 2) + text.slice(start, end) + text.slice(end + 2), start: start - 2, end: end - 2 };
  }
  return { text: `${text.slice(0, start)}**${text.slice(start, end)}**${text.slice(end)}`, start: start + 2, end: end + 2 };
}

// Seconds into the meeting at ``now`` (ms), for a recording that started at ``startIso``; null without one.
export function meetingTime(startIso, now) {
  const start = startIso ? Date.parse(startIso) : NaN;
  if (!Number.isFinite(start)) return null;
  return Math.max(0, Math.round((now - start) / 100) / 10);
}

// The document as the server keeps it.
export const forSave = (paragraphs) => paragraphs.map((p) => (p.image
  ? { text: p.text, at: p.at, image: p.image } : { text: p.text, at: p.at }));

export const chipText = (at) => (at == null ? "" : clock(at));

// --- saving next to other writers (the notes changed elsewhere: another window, the event's prepared notes,
// a cut) ----------------------------------------------------------------------------------------------

export const keyOf = (p) => JSON.stringify([p.text, p.at ?? null, p.image ?? null]);

// The notes as they are on the server, with what was typed here re-applied. ``local``: the editor's
// paragraphs, each with ``orig``: its key when last read or saved (null: new here). A paragraph edited here is
// put where its original is now, or — gone elsewhere — kept after the paragraph before it; new ones likewise.
// What changed only elsewhere is taken as it is. Nothing typed here is dropped.
export function mergeNotes(server, local) {
  const out = server.map((p) => ({ ...p, orig: keyOf(p) }));
  const taken = new Set();
  const placed = new Map();  // local id -> the entry it became
  const pending = [];
  for (const l of local) {
    const i = l.orig == null ? -1 : out.findIndex((r, k) => !taken.has(k) && r.orig === l.orig && r.id == null);
    if (i >= 0) {
      taken.add(i);
      out[i] = { ...l, orig: out[i].orig };
      placed.set(l.id, out[i]);
    } else if (l.orig == null || keyOf(l) !== l.orig) {
      pending.push(l);  // typed here, not there
    }
  }
  for (const l of pending) {
    const before = local.slice(0, local.indexOf(l)).reverse().find((x) => placed.has(x.id));
    const at = before ? out.indexOf(placed.get(before.id)) + 1 : out.length;
    const entry = { ...l, orig: null };
    out.splice(at, 0, entry);
    placed.set(l.id, entry);
  }
  const changed = JSON.stringify(out.map(keyOf)) !== JSON.stringify(server.map(keyOf));
  return { paragraphs: out, changed };
}

// Paragraphs at most ``max`` long: a longer one (a long paste) is cut at its last line break before the limit,
// else at a space, else hard; the parts keep its time.
export function splitLong(paragraphs, max) {
  const out = [];
  for (const p of paragraphs) {
    if (p.image || p.text.length <= max) {
      out.push(p);
      continue;
    }
    let rest = p.text;
    let first = true;
    while (rest.length > max) {
      let cut = rest.lastIndexOf("\n", max);
      if (cut <= 0) cut = rest.lastIndexOf(" ", max);
      if (cut <= 0) cut = max;
      out.push(first ? { ...p, text: rest.slice(0, cut) } : { ...p, id: undefined, orig: null, text: rest.slice(0, cut) });
      first = false;
      rest = rest.slice(cut).replace(/^\n/, "");
    }
    out.push({ ...p, id: undefined, orig: null, text: rest });
  }
  return out;
}

// The notes as plain text (to copy when they can't be saved).
export const notesText = (paragraphs) => paragraphs.map((p) => (p.image ? [p.text, "[image]"].filter(Boolean).join(" ") : p.text))
  .filter((t) => t.trim()).join("\n\n");
