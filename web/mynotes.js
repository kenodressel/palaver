// The user's own notes on a meeting (#44): a notepad on the meeting page —
// live, before the meeting (prep) and after it. One paragraph is one block
// with the meeting time it was started at (a chip that plays from there);
// a block shows its light markdown until it is clicked, then its text.
// Pasted or dropped images are stored with the meeting, never uploaded;
// the text in them is read on this Mac.
//
// Saving: 500 ms after typing stops, on leaving a paragraph, and when the
// page hides. Deleting an image or clearing the notes can be undone (toast).

import { h, toast, remember, busy } from "./ui.js";
import { parseNote, splitAt, toggleBold, forSave, chipText, mergeNotes, splitLong, keyOf, notesText }
  from "./mynotes-logic.js";

const SAVE_MS = 500;
const RETRY_MS = [3000, 6000, 15000, 30000];  // a save that failed on the way (not refused): tried again
const READ_POLL_MS = 1000;
const READ_POLL_TRIES = 60;
const MAX_IMAGE_BYTES = 25 * 1024 * 1024;
const MAX_TEXT = 20000;  // characters in a paragraph (the server's limit)
const KEEPALIVE_BYTES = 60000;  // a save that outlives the page is at most 64 KB
const DRAFT = "palaver.myNotes.";  // + key: what was not saved yet, for a page closed meanwhile

const pads = new Map();  // key -> pad: the meeting open now, and any still saving
let nextId = 1;

class Refused extends Error {
  constructor(message, status, data) {
    super(message);
    this.status = status;
    this.data = data;
  }
}

async function call(path, body, { keepalive = false } = {}) {
  const opts = body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body), keepalive };
  const resp = await fetch(path, opts);
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Refused(data.error || `${resp.status}`, resp.status, data);
  return data;
}

// The editor's paragraphs: an id each, and ``orig``, its key as last read or saved (null: typed here, new).
const fromServer = (paragraphs) => paragraphs.map((p) => ({ ...p, id: nextId++, orig: keyOf(p) }));
const withIds = (paragraphs) => paragraphs.map((p) => (p.id == null ? { ...p, id: nextId++ } : p));

// The notepad of ``key`` ("m:<meeting>" or "p:<event key>") with its element. ``opts`` (taken again on each
// call: a recording ends, its audio arrives): timeNow() → the meeting time now or null; seek(at) or null
// when there is nothing to play; flat: no chips (before the meeting); revision: the notes' revision as the
// page last heard it (a cut, a join, an event picked, an undo change them: read again).
export function notepad(key, base, opts) {
  let pad = pads.get(key);
  if (!pad) {
    pad = { key, base, paragraphs: [], images: {}, loaded: false, error: null, dirty: false, timer: null,
      saving: null, again: false, editing: null, status: "", statusTitle: "", reading: null, el: null, look: null,
      revision: null, problem: null, retries: 0 };
    pads.set(key, pad);
    pad.el = h("section", { class: "my-notes", "aria-label": "My notes" });
    wire(pad);
    load(pad);
  }
  const look = `${!!opts.seek}|${!!opts.flat}`;  // what the chips are: buttons, plain or none
  pad.opts = opts;
  for (const [k, other] of pads) if (other !== pad && !other.dirty && !other.saving) pads.delete(k);
  // Built again only when the chips change, never under the caret of a paragraph being written.
  if (pad.look !== look && pad.editing == null) {
    pad.look = look;
    pad.el.classList.toggle("flat", !!opts.flat);
    render(pad);
  }
  if (pad.loaded && opts.revision != null && opts.revision !== pad.revision) refresh(pad);
  return pad.el;
}

// Saves every notepad with changes not saved yet (leaving a meeting, the page hiding).
export function flushNotepads({ keepalive = false } = {}) {
  return Promise.all([...pads.values()].map((pad) => save(pad, { keepalive })));
}

// The page the notepads are on is left (another tab of the meeting): the paragraph being written reads as
// notes again, and everything is saved now, before the editor leaves the page.
export function leaveNotepads() {
  for (const pad of pads.values()) if (pad.editing != null) stopEditing(pad);
  return flushNotepads();
}

// After the notes changed elsewhere: read them again (what was typed here stays).
export async function reloadNotepad(key) {
  const pad = pads.get(key);
  if (pad) await refresh(pad);
}

function readDraft(pad) {
  try {
    return JSON.parse(localStorage.getItem(DRAFT + pad.key) || "null");
  } catch {
    return null;
  }
}

function writeDraft(pad) {
  try {
    if (pad.dirty) localStorage.setItem(DRAFT + pad.key, JSON.stringify({ revision: pad.revision, paragraphs: forSave(pad.paragraphs) }));
    else localStorage.removeItem(DRAFT + pad.key);
  } catch {
    // no storage here: the server copy is all there is
  }
}

async function load(pad) {
  let doc;
  try {
    doc = await call(pad.base);
  } catch (err) {
    pad.error = `Your notes could not be read: ${err.message}`;
    render(pad);
    return;
  }
  pad.error = null;
  pad.loaded = true;
  pad.paragraphs = fromServer(doc.paragraphs);
  take(pad, doc);
  // Typed before the page went (a reload during a save): back, on top of the notes as they are now.
  const draft = readDraft(pad);
  if (draft && Array.isArray(draft.paragraphs)) {
    const there = new Set(doc.paragraphs.map(keyOf));
    const local = draft.paragraphs.map((p) => ({ ...p, id: nextId++, orig: there.has(keyOf(p)) ? keyOf(p) : null }));
    // Saved on the notes as they are: the draft is simply newer. Otherwise both, merged.
    const merged = draft.revision === doc.revision ? { paragraphs: local } : mergeNotes(doc.paragraphs, local);
    if (JSON.stringify(forSave(merged.paragraphs)) !== JSON.stringify(doc.paragraphs)) {
      pad.paragraphs = withIds(merged.paragraphs);
      setStatus(pad, "Unsaved notes restored");
      changed(pad);
    } else {
      writeDraft(pad);
    }
  }
  pad.editing = null;
  render(pad);
  watchReading(pad);
}

// The server's notes and revision taken in (the images' text too).
function take(pad, doc) {
  pad.revision = doc.revision;
  pad.images = { ...pad.images, ...doc.images };
}

// The notes as they are on the server, with anything typed here and not saved yet kept on top.
function adopt(pad, doc) {
  const kept = keepCaret(pad);
  const merged = mergeNotes(doc.paragraphs, pad.paragraphs);
  pad.paragraphs = withIds(merged.paragraphs);
  take(pad, doc);
  pad.editing = kept && pad.paragraphs.some((p) => p.id === kept.id) ? kept.id : null;
  render(pad);
  restoreCaret(pad, kept);
  watchReading(pad);
  return merged.changed;
}

async function refresh(pad) {
  if (pad.refreshing) return;
  pad.refreshing = true;
  try {
    await (pad.saving || Promise.resolve());
    const doc = await call(pad.base);
    if (doc.revision === pad.revision) return;  // an answer older than the last save: nothing new
    if (adopt(pad, doc)) changed(pad);
  } catch {
    // the next look (the page refreshing, the window coming to the front) tries again
  } finally {
    pad.refreshing = false;
  }
}

function keepCaret(pad) {
  const ta = pad.el.querySelector(".mn-input");
  if (!ta || document.activeElement !== ta) return null;
  return { id: pad.editing, start: ta.selectionStart, end: ta.selectionEnd };
}

function restoreCaret(pad, kept) {
  const ta = kept && pad.editing === kept.id ? pad.el.querySelector(".mn-input") : null;
  if (!ta) return;
  ta.focus({ preventScroll: true });
  ta.setSelectionRange(Math.min(kept.start, ta.value.length), Math.min(kept.end, ta.value.length));
}

// --- saving -------------------------------------------------------------------------

function setStatus(pad, text, title = "") {
  pad.status = text;
  pad.statusTitle = title;
  const el = pad.el.querySelector(".mn-status");
  if (el) {
    el.textContent = text;
    el.title = title;
  }
}

function changed(pad) {
  pad.dirty = true;
  if (pad.status !== "Saving…") setStatus(pad, "Editing");
  writeDraft(pad);
  clearTimeout(pad.timer);
  pad.timer = setTimeout(() => save(pad), SAVE_MS);
}

// A save the server refused (not a conflict): it stays refused until something changes, so no retries;
// the notes stay on the page, with the reason and a way to copy them.
function refused(pad, reason) {
  pad.problem = reason;
  setStatus(pad, "");
  showProblem(pad);
}

function showProblem(pad) {
  const shown = pad.el.querySelector(".mn-problem");
  if (shown && shown.dataset.problem === pad.problem && shown.isConnected && shown.previousElementSibling) return;
  shown?.remove();
  if (!pad.problem) return;
  const line = h("div", { class: "mn-problem", role: "alert", "data-problem": pad.problem },
    h("span", {}, `Couldn't save: ${pad.problem}`),
    h("button", { type: "button", class: "btn btn-quiet small", onclick: () => copyNotes(pad) }, "Copy my notes"));
  pad.el.querySelector(".mn-head")?.after(line);
}

async function copyNotes(pad) {
  const text = notesText(pad.paragraphs);
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const area = h("textarea", { style: "position:fixed;opacity:0" });
    area.value = text;
    document.body.append(area);
    area.select();
    document.execCommand("copy");
    area.remove();
  }
  toast("Your notes are copied", { short: true });
}

function save(pad, { keepalive = false } = {}) {
  clearTimeout(pad.timer);
  if (pad.saving) {
    if (pad.dirty) pad.again = true;
    return pad.saving;
  }
  if (!pad.dirty || !pad.loaded) return Promise.resolve();
  pad.dirty = false;
  pad.paragraphs = withIds(splitLong(pad.paragraphs, MAX_TEXT));  // never a paragraph the server refuses
  const sent = new Map(pad.paragraphs.map((p) => [p.id, keyOf(p)]));
  const body = { paragraphs: forSave(pad.paragraphs), revision: pad.revision ?? "" };
  keepalive = keepalive && JSON.stringify(body).length < KEEPALIVE_BYTES;
  setStatus(pad, "Saving…");
  pad.saving = call(pad.base, body, { keepalive })
    .then((answer) => {
      for (const p of pad.paragraphs) if (sent.has(p.id)) p.orig = sent.get(p.id);
      pad.revision = answer.revision;
      pad.problem = null;
      pad.retries = 0;
      showProblem(pad);
      if (!pad.dirty) setStatus(pad, "Saved");
      writeDraft(pad);
    }, (err) => {
      pad.dirty = true;
      writeDraft(pad);
      if (err.status === 409 && err.data?.document) {
        // Changed elsewhere since it was read: both kept, then saved again on top.
        adopt(pad, err.data.document);
        setStatus(pad, "Merged with changes made elsewhere");
        pad.again = true;
      } else if (err.status >= 400 && err.status < 500) {
        refused(pad, err.status === 404 ? "this meeting is not here any more (moved to the trash or joined)" : err.message);
      } else {
        const wait = RETRY_MS[Math.min(pad.retries++, RETRY_MS.length - 1)];
        setStatus(pad, "Not saved · trying again", err.message);
        clearTimeout(pad.timer);
        pad.timer = setTimeout(() => save(pad), wait);
      }
    })
    .finally(() => {
      pad.saving = null;
      if (pad.again) {
        pad.again = false;
        save(pad);
      }
    });
  return pad.saving;
}

if (typeof window !== "undefined") {
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flushNotepads({ keepalive: true });
    else for (const pad of pads.values()) if (pad.loaded) refresh(pad);
  });
  window.addEventListener("pagehide", () => flushNotepads({ keepalive: true }));
  // Back to this window: the notes may have been written in another one meanwhile.
  window.addEventListener("focus", () => { for (const pad of pads.values()) if (pad.loaded) refresh(pad); });
}

// --- the page ---------------------------------------------------------------------------

const find = (pad, id) => pad.paragraphs.findIndex((p) => p.id === id);
const blockEl = (pad, id) => pad.el.querySelector(`.mn-block[data-id="${id}"]`);

function render(pad) {
  const empty = !pad.paragraphs.some((p) => p.text.trim() || p.image);
  // One action, so a button rather than a ⋯ menu; undo brings the notes back.
  const clear = empty ? null : h("button", { type: "button", class: "btn btn-quiet small mn-clear",
    title: "Clear my notes (undo with ⌘Z)", onclick: () => clearNotes(pad, clear) }, "Clear");
  const body = h("div", { class: "mn-body", onclick: (e) => { if (e.target === body) editEnd(pad); } },
    pad.paragraphs.map((p) => block(pad, p)));
  if (!pad.paragraphs.length && pad.loaded) {
    body.append(h("button", { type: "button", class: "mn-placeholder", onclick: () => editEnd(pad) },
      "Write what you notice, ask, decide. ⌃⇧⌘4 then ⌘V pastes a screenshot; images can be dropped here too."));
  }
  const picker = h("input", { type: "file", accept: "image/*", multiple: true, hidden: true,
    onchange: () => { addImages(pad, [...picker.files], pad.editing); picker.value = ""; } });
  const addImage = pad.loaded ? h("button", { type: "button", class: "btn btn-quiet small mn-add-image",
    title: "Add an image (or paste one with ⌘V)", onclick: () => picker.click() }, "Add image") : null;
  pad.el.replaceChildren(...[
    h("header", { class: "mn-head" },
      h("h2", {}, "My notes"),
      h("span", { class: "mn-status", role: "status", title: pad.statusTitle }, pad.status),
      addImage, picker, clear),
    pad.error ? h("p", { class: "mn-error error" }, pad.error) : null,
    body,
    !empty ? h("p", { class: "mn-foot" }, "Images stay on this Mac; their text goes to the language model you chose.")
      : null,
  ].filter(Boolean));
  showProblem(pad);
  if (pad.editing != null) {
    const ta = pad.el.querySelector(".mn-input");
    if (ta) autosize(ta);
  }
}

// A paragraph's time chip; none (and no room kept for one) for a paragraph without a time, unless it was just
// started while the meeting records: it gets its time with its first letter.
function chip(pad, p) {
  const text = chipText(p.at);
  if (pad.opts.flat) return null;
  if (!text) return p.fresh && !p.text.trim() && pad.opts.timeNow() != null
    ? h("span", { class: "mn-time none", "aria-hidden": "true" }) : null;
  if (!pad.opts.seek) {
    return h("span", { class: "mn-time", title: `Written ${text} into the meeting` }, text);
  }
  return h("button", { type: "button", class: "mn-time", title: `Play from ${text}`,
    "aria-label": `Play from ${text}`, onclick: () => pad.opts.seek(p.at) }, text);
}

function block(pad, p) {
  if (p.image) return imageBlock(pad, p);
  const time = chip(pad, p);
  const el = h("div", { class: time ? "mn-block" : "mn-block untimed", "data-id": p.id }, time);
  el.append(pad.editing === p.id ? input(pad, p) : shown(pad, p));
  return el;
}

// A paragraph as it reads: text nodes only, bold and lists from the markdown.
function shown(pad, p) {
  const segments = (list) => list.map((s) => {
    const node = document.createTextNode(s.text);
    node.mnSrc = s.src;
    return s.bold ? h("strong", {}, node) : node;
  });
  const blocks = parseNote(p.text).map((b) => {
    if (b.type === "p") return h("p", {}, b.lines.flatMap((line, i) => (i ? [h("br"), ...segments(line)] : segments(line))));
    const list = h(b.type, b.type === "ol" && b.start !== 1 ? { start: b.start } : {},
      b.items.map((item) => h("li", { style: item.level ? `margin-left:${item.level * 1.2}em` : null }, segments(item.segments))));
    return list;
  });
  return h("div", { class: "mn-text", tabindex: "0", role: "button", "aria-label": `Edit: ${p.text.slice(0, 60)}`,
    onclick: (e) => edit(pad, p.id, caretFromClick(e, p.text)),
    onkeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); edit(pad, p.id, p.text.length); } },
  }, blocks.length ? blocks : h("p", { class: "mn-blank" }, " "));
}

// Where in the paragraph's text a click on its rendered form was.
function caretFromClick(e, text) {
  const range = document.caretRangeFromPoint?.(e.clientX, e.clientY);
  const node = range?.startContainer;
  if (node && Number.isInteger(node.mnSrc)) return Math.min(text.length, node.mnSrc + range.startOffset);
  return text.length;
}

function autosize(ta) {
  ta.style.height = "auto";
  ta.style.height = `${ta.scrollHeight}px`;
}

function input(pad, p) {
  const ta = h("textarea", { class: "mn-input", rows: "1", spellcheck: "true", "aria-label": "My notes paragraph",
    placeholder: pad.paragraphs.length === 1 ? "Write what you notice, ask, decide…" : "" });
  ta.value = p.text;
  ta.addEventListener("input", () => {
    if (!p.text.trim() && ta.value.trim() && p.fresh) p.at = pad.opts.timeNow();  // started now
    if (ta.value.trim()) p.fresh = false;
    p.text = ta.value;
    if (p.text.length > MAX_TEXT) return splitTooLong(pad, p);
    autosize(ta);
    const el = blockEl(pad, p.id);
    const time = el?.querySelector(":scope > .mn-time");
    if (el && chipText(p.at) && (!time || time.classList.contains("none"))) {
      if (time) time.replaceWith(chip(pad, p));
      else el.prepend(chip(pad, p));
      el.classList.remove("untimed");
    }
    changed(pad);
  });
  ta.addEventListener("keydown", (e) => keys(pad, p, ta, e));
  ta.addEventListener("paste", (e) => {
    const files = [...(e.clipboardData?.files || [])].filter((f) => f.type.startsWith("image/"));
    if (!files.length) return;
    e.preventDefault();
    addImages(pad, files, p.id);
  });
  // Leaving the paragraph: it reads as notes again (an empty one goes), and is saved. Not when the page
  // was only built again around it (it is still there, and gets the focus back).
  ta.addEventListener("blur", () => setTimeout(() => {
    if (!ta.isConnected || document.activeElement === ta || pad.editing !== p.id) return;
    stopEditing(pad);
  }));
  return ta;
}

// The paragraph being written reads as notes again (an empty one goes), and is saved.
function stopEditing(pad) {
  const p = pad.paragraphs.find((x) => x.id === pad.editing);
  pad.editing = null;
  if (p && !p.text.trim() && pad.paragraphs.length > 1) {
    pad.paragraphs.splice(find(pad, p.id), 1);
    changed(pad);
  }
  render(pad);
  return save(pad);
}

// A paragraph past the limit (a long paste): several paragraphs, with the caret at the end of the last.
function splitTooLong(pad, p) {
  const parts = withIds(splitLong([p], MAX_TEXT));
  pad.paragraphs.splice(find(pad, p.id), 1, ...parts);
  toast(`Long text split into ${parts.length} paragraphs (at most ${MAX_TEXT.toLocaleString("en")} characters each)`);
  edit(pad, parts.at(-1).id, parts.at(-1).text.length);
  changed(pad);
}

function keys(pad, p, ta, e) {
  if (e.isComposing) return;
  const { selectionStart: start, selectionEnd: end } = ta;
  const i = find(pad, p.id);
  if (e.key === "Enter" && !e.shiftKey && !e.metaKey && !e.altKey) {
    e.preventDefault();
    const r = splitAt(ta.value, start, end);
    p.text = r.current;
    if (r.next === null) {
      ta.value = r.current;
      ta.setSelectionRange(r.caret, r.caret);
      autosize(ta);
    } else {
      const added = { id: nextId++, text: r.next, at: pad.opts.timeNow(), fresh: !r.next.trim() };
      pad.paragraphs.splice(i + 1, 0, added);
      edit(pad, added.id, r.caret);
    }
    changed(pad);
  } else if (e.key === "Backspace" && start === 0 && end === 0 && i > 0 && !pad.paragraphs[i - 1].image) {
    e.preventDefault();
    const prev = pad.paragraphs[i - 1];
    const at = prev.text.length;
    prev.text += p.text;
    pad.paragraphs.splice(i, 1);
    edit(pad, prev.id, at);
    changed(pad);
  } else if (e.key === "ArrowUp" && start === 0 && end === 0) {
    const prev = pad.paragraphs.slice(0, i).reverse().find((x) => !x.image);
    if (prev) {
      e.preventDefault();
      edit(pad, prev.id, prev.text.length);
    }
  } else if (e.key === "ArrowDown" && start === ta.value.length && end === start) {
    const next = pad.paragraphs.slice(i + 1).find((x) => !x.image);
    if (next) {
      e.preventDefault();
      edit(pad, next.id, 0);
    }
  } else if (e.key.toLowerCase() === "b" && (e.metaKey || e.ctrlKey) && !e.shiftKey && !e.altKey) {
    e.preventDefault();
    const before = ta.value;
    const r = toggleBold(before, start, end);
    // Typed over the part that changes, so ⌘Z takes it back like typing.
    const { head, tail, text } = difference(before, r.text);
    ta.setSelectionRange(head, before.length - tail);
    if (!document.execCommand?.("insertText", false, text) || ta.value !== r.text) ta.value = r.text;
    ta.setSelectionRange(r.start, r.end);
    p.text = ta.value;
    changed(pad);
  } else if (e.key === "Escape") {
    ta.blur();
  }
}

// Where ``after`` differs from ``before``: the length of the common start and end, and what is between.
function difference(before, after) {
  let head = 0;
  while (head < before.length && head < after.length && before[head] === after[head]) head++;
  let tail = 0;
  while (tail < before.length - head && tail < after.length - head
    && before[before.length - 1 - tail] === after[after.length - 1 - tail]) tail++;
  return { head, tail, text: after.slice(head, after.length - tail) };
}

// Edit paragraph ``id`` with the caret at ``caret``.
function edit(pad, id, caret) {
  pad.editing = id;
  render(pad);
  const ta = pad.el.querySelector(".mn-input");
  if (!ta) return;
  ta.focus({ preventScroll: false });
  const at = Math.min(caret ?? ta.value.length, ta.value.length);
  ta.setSelectionRange(at, at);
  autosize(ta);
}

// A click below the last paragraph: on at its end, or a new paragraph after an image.
function editEnd(pad) {
  if (!pad.loaded) return;
  const last = pad.paragraphs.at(-1);
  if (last && !last.image) return edit(pad, last.id, last.text.length);
  const added = { id: nextId++, text: "", at: null, fresh: true };
  pad.paragraphs.push(added);
  edit(pad, added.id, 0);
}

// --- images -------------------------------------------------------------------------------

function imageBlock(pad, p) {
  const read = pad.images[p.image]?.text;
  const src = `${pad.base}/images/${encodeURIComponent(p.image)}`;
  const remove = h("button", { type: "button", class: "mn-remove", "aria-label": "Delete image", title: "Delete image",
    onclick: () => deleteImage(pad, p, remove) }, "×");
  const time = chip(pad, p);
  return h("div", { class: time ? "mn-block mn-image" : "mn-block mn-image untimed", "data-id": p.id }, time,
    h("figure", {},
      h("img", { src, alt: read ? `Image: ${read.split("\n")[0]}` : "Pasted image", loading: "lazy",
        title: "Show larger", onclick: () => zoom(src) }),
      remove,
      h("figcaption", {}, read == null ? h("span", { class: "mn-reading" }, "Reading the text in it…")
        : read ? h("details", {}, h("summary", {}, "Text in the image"), h("p", { class: "mn-read" }, read))
          : h("span", {}, "No text found in it"))));
}

// A screenshot at full size; a click or Escape closes it.
function zoom(src) {
  const dialog = h("dialog", { class: "mn-zoom", "aria-label": "Image" }, h("img", { src, alt: "" }));
  dialog.addEventListener("click", () => dialog.close());
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}

const asBase64 = (file) => new Promise((resolve, reject) => {
  const reader = new FileReader();
  reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
  reader.onerror = () => reject(reader.error || new Error("could not read the file"));
  reader.readAsDataURL(file);
});

async function addImages(pad, files, afterId = null) {
  if (!pad.loaded) return;
  let after = afterId;
  for (const file of files) {
    if (file.size > MAX_IMAGE_BYTES) {
      toast(`The image was not added: it is larger than ${MAX_IMAGE_BYTES / 1024 / 1024} MB`);
      continue;
    }
    setStatus(pad, "Adding the image…");
    try {
      const { name } = await call(`${pad.base}/images`, { data: await asBase64(file) });
      const added = { id: nextId++, text: "", at: pad.opts.timeNow(), image: name };
      const i = after == null ? pad.paragraphs.length : find(pad, after) + 1;
      // An empty paragraph the image was pasted into gives way to it.
      const into = after != null ? pad.paragraphs[i - 1] : null;
      if (into && !into.image && !into.text.trim()) pad.paragraphs.splice(i - 1, 1, added);
      else pad.paragraphs.splice(i, 0, added);
      pad.images[name] = { text: null };
      after = added.id;
      pad.editing = null;
      render(pad);
      changed(pad);
      save(pad);
    } catch (err) {
      setStatus(pad, "");
      toast(`The image was not added: ${err.message}`);
    }
  }
  watchReading(pad);
}

// While the text of an image is being read: ask again each second.
function watchReading(pad, tries = 0) {
  clearTimeout(pad.reading);
  const waiting = () => pad.paragraphs.some((p) => p.image && pad.images[p.image]?.text == null);
  if (!waiting() || tries > READ_POLL_TRIES) return;
  pad.reading = setTimeout(async () => {
    try {
      const doc = await call(pad.base);
      let any = false;
      for (const [name, image] of Object.entries(doc.images)) {
        if (pad.images[name]?.text == null && image.text != null) {
          pad.images[name] = image;
          any = true;
        }
      }
      if (any) {
        for (const p of pad.paragraphs.filter((x) => x.image && doc.images[x.image]?.text != null)) {
          blockEl(pad, p.id)?.replaceWith(imageBlock(pad, p));
        }
      }
    } catch {
      // the next try
    }
    watchReading(pad, tries + 1);
  }, READ_POLL_MS);
}

// Drops on the notepad: images go in after the paragraph they are dropped on.
function wire(pad) {
  // A button of the notepad pressed while a paragraph is being written: the paragraph keeps the focus
  // (else leaving it would build the notepad again under the pointer, and the click would be lost).
  pad.el.addEventListener("mousedown", (e) => {
    if (e.target.closest?.("button") && pad.el.querySelector(".mn-input") === document.activeElement) e.preventDefault();
  });
  const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes("Files");
  pad.el.addEventListener("dragover", (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    pad.el.classList.add("dropping");
  });
  pad.el.addEventListener("dragleave", (e) => {
    if (!pad.el.contains(e.relatedTarget)) pad.el.classList.remove("dropping");
  });
  pad.el.addEventListener("drop", (e) => {
    pad.el.classList.remove("dropping");
    const files = [...(e.dataTransfer?.files || [])].filter((f) => f.type.startsWith("image/"));
    if (!hasFiles(e)) return;
    e.preventDefault();
    if (!files.length) {
      toast("Only images can be dropped into your notes");
      return;
    }
    const on = e.target.closest?.(".mn-block");
    addImages(pad, files, on ? Number(on.dataset.id) : null);
  });
}

async function deleteImage(pad, p, button) {
  await save(pad);
  let answer;
  try {
    answer = await busy(button, call(`${pad.base}/images/${encodeURIComponent(p.image)}/delete`, {}));
  } catch (err) {
    toast(`The image was not deleted: ${err.message}`);
    return;
  }
  pad.editing = null;
  adopt(pad, answer);  // the notes without it (its paragraph was saved: it goes on both sides)
  delete pad.images[p.image];
  render(pad);
  remember("Image deleted from your notes", () => undoNotes(pad, answer.undo));
}

async function clearNotes(pad, from) {
  await save(pad);
  let answer;
  try {
    answer = await busy(from, call(`${pad.base}/clear`, {}));
  } catch (err) {
    toast(`Your notes were not cleared: ${err.message}`);
    return;
  }
  pad.editing = null;
  adopt(pad, answer);
  pad.images = {};
  render(pad);
  remember("Your notes cleared", () => undoNotes(pad, answer.undo));
}

// The server puts the paragraphs back into the notes as they are now; what was typed since stays.
async function undoNotes(pad, token) {
  await save(pad);
  await call("/api/undo", { token });
  await refresh(pad);
}

// Focus in a notepad's paragraph, to put back after the page around it was built again.
export function notepadFocus() {
  const a = document.activeElement;
  if (!a?.classList?.contains("mn-input")) return null;
  return { el: a, start: a.selectionStart, end: a.selectionEnd };
}

export function restoreNotepadFocus(kept) {
  if (!kept?.el.isConnected) return;
  kept.el.focus({ preventScroll: true });
  kept.el.setSelectionRange(kept.start, kept.end);
}
