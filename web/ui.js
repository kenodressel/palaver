// Shared pieces of the Meetings window: building DOM, the ⋯ menu, the toast
// with Undo, the ⌘Z history, the busy state of a button, transitions, and the
// command registry the native menu bar calls into.
//
// Node imports this file for the unit tests (tests/js/): nothing here touches
// `document` or `window` until a function is called.

export const $ = (sel) => document.querySelector(sel);

// h("div", {class: "x", onclick: fn}, child, "text") — builds DOM without innerHTML.
export function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "style") el.style.cssText = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

// --- undo history ----------------------------------------------------------

// The changes of this page session that ⌘Z can take back, newest last.
export class UndoHistory {
  constructor(limit = 20) {
    this.limit = limit;
    this.entries = [];
  }

  push(entry) {
    this.entries.push(entry);
    if (this.entries.length > this.limit) this.entries.splice(0, this.entries.length - this.limit);
  }

  // Takes an entry out without undoing it (its toast's Undo ran it instead).
  remove(entry) {
    const at = this.entries.lastIndexOf(entry);
    if (at >= 0) this.entries.splice(at, 1);
    return at >= 0;
  }

  // Still undoable: not undone yet (by ⌘Z or its toast), nor dropped.
  has(entry) {
    return this.entries.includes(entry);
  }

  // The label of the change undone, or null when there is none. The entry is
  // gone even when its undo throws: a failed undo can't succeed later either.
  async undoLast() {
    const entry = this.entries.pop();
    if (!entry) return null;
    await entry.undo();
    return entry.label;
  }

  get size() {
    return this.entries.length;
  }
}

// The page's one history.
export const history = new UndoHistory();

// Where text is typed: ⌘Z there edits the text, not the app.
const NOT_TEXT = new Set(["checkbox", "radio", "range", "button", "submit", "reset", "color", "file", "image"]);
export function isTextField(target) {
  if (!target) return false;
  const tag = String(target.tagName || "").toUpperCase();
  if (tag === "TEXTAREA") return true;
  if (tag === "INPUT") return !NOT_TEXT.has(String(target.type || "text").toLowerCase());
  return !!target.isContentEditable;
}

// Where keys go to a field (text, or a select's type-ahead): shortcuts leave these alone.
export function isEditable(target) {
  if (!target) return false;
  return String(target.tagName || "").toUpperCase() === "SELECT" || isTextField(target);
}

// --- toast -----------------------------------------------------------------

const TOAST_MS = 8000;
const SHORT_MS = 2000;
let current = null;  // {el, timer, remaining, started}

function toastHost() {
  let host = document.getElementById("toasts");
  if (!host) {
    host = h("div", { id: "toasts", class: "toasts", role: "status", "aria-live": "polite" });
    document.body.append(host);
  }
  return host;
}

// A toast that had focus gives it back when it goes: to where focus came
// from, or to the main area, never to <body>.
function giveBackFocus(t) {
  const active = document.activeElement;
  if (!t.focused || (active && active !== document.body && !t.el.contains(active))) return;
  const to = t.returnTo?.isConnected ? t.returnTo : document.getElementById("main");
  t.focused = false;
  to?.focus({ preventScroll: true });
}

function dismiss(t) {
  clearTimeout(t.timer);
  if (current === t) current = null;
  giveBackFocus(t);
  t.el.classList.add("gone");
  setTimeout(() => t.el.remove(), 160);
}

function showToast(text, opts = {}, ms = TOAST_MS) {
  const before = current;
  if (before) { clearTimeout(before.timer); current = null; }
  // working: its Undo is running; the toast stays until the result replaces it.
  const t = { remaining: ms, started: 0, timer: null, paused: false, working: false, focused: false, returnTo: null };
  const buttons = [];
  if (opts.undo) {
    const button = h("button", { type: "button", class: "toast-action" }, "Undo");
    button.addEventListener("click", async () => {
      pause();
      t.working = true;
      let ok = true;
      try {
        await busy(button, Promise.resolve().then(opts.undo));
      } catch {
        ok = false;
      }
      if (current === t) showToast(ok ? "Undone" : "Can't undo this any more", {}, ok ? SHORT_MS : TOAST_MS);
    });
    buttons.push(button);
  }
  for (const action of [opts.action, ...(opts.actions || [])]) {
    if (!action) continue;
    buttons.push(h("button", { type: "button", class: "toast-action", onclick: () => { dismiss(t); action.run(); } },
      action.label));
  }
  t.el = h("div", { class: "toast", style: `--toast-ms: ${ms}ms` },
    h("span", { class: "toast-text" }, text), buttons,
    h("span", { class: "toast-bar", "aria-hidden": "true" }));

  const start = () => {
    t.started = Date.now();
    t.timer = setTimeout(() => dismiss(t), t.remaining);
  };
  const pause = () => {
    if (t.paused) return;
    t.paused = true;
    clearTimeout(t.timer);
    t.remaining = Math.max(0, t.remaining - (Date.now() - t.started));
    t.el.classList.add("paused");
  };
  const resume = () => {
    if (!t.paused || t.working || current !== t) return;
    if (t.el.matches(":hover") || t.el.contains(document.activeElement)) return;
    t.paused = false;
    t.el.classList.remove("paused");
    start();
  };
  t.el.addEventListener("mouseenter", pause);
  t.el.addEventListener("focusin", (e) => {
    if (!t.focused) t.returnTo = t.el.contains(e.relatedTarget) ? null : e.relatedTarget;
    t.focused = true;
    pause();
  });
  t.el.addEventListener("mouseleave", resume);
  t.el.addEventListener("focusout", (e) => {
    if (t.el.contains(e.relatedTarget)) return;
    // Focus moved on to something else (not lost because a button was disabled or removed).
    if (e.relatedTarget) t.focused = false;
    setTimeout(resume);
  });

  current = t;
  // The new toast takes over the old one's focus duty: the old one's button is about to go.
  if (before?.focused) { t.focused = true; t.returnTo = before.returnTo; }
  toastHost().replaceChildren(t.el);
  if (t.focused) giveBackFocus(t);
  start();
}

// A short message at the bottom of the window, with Undo and/or an action
// (``action``, or several: ``actions``; ``short``: a confirmation that needs no reading, 2 s). A new toast replaces
// the old one; the old change stays undoable with ⌘Z.
export function toast(text, opts = {}) {
  showToast(text, opts, opts.short ? SHORT_MS : TOAST_MS);
}

// A change the user can take back: into the ⌘Z history, and a toast with Undo.
// ``text``: the toast says more than the history's ``label``; ``action``: a
// button besides Undo (as for ``toast``).
// Returns the history entry: ``history.has(entry)`` is false once it was undone,
// e.g. by ⌘Z while the change was still animating.
export function remember(label, undo, { text, action } = {}) {
  const entry = { label, undo };
  history.push(entry);
  // Already taken by ⌘Z (done or running): nothing left for the toast to undo.
  toast(text || label, { action, undo: async () => { if (history.remove(entry)) await undo(); } });
  return entry;
}

// ⌘Z / Edit → Undo: text in a text field, otherwise the last change of the page.
let undoing = Promise.resolve();
export function undo() {
  if (typeof document !== "undefined" && isTextField(document.activeElement)) {
    document.execCommand("undo");
    return Promise.resolve();
  }
  // One at a time: a second ⌘Z waits for the first to finish.
  undoing = undoing.then(async () => {
    try {
      const label = await history.undoLast();
      showToast(label === null ? "Nothing to undo" : "Undone", {}, SHORT_MS);
    } catch {
      showToast("Can't undo this any more", {}, TOAST_MS);
    }
  });
  return undoing;
}

// --- playback ----------------------------------------------------------------

// Starts ``media`` playing. Its play() promise is rejected with an AbortError
// when pause() comes first (Space twice while the audio loads): that is no
// error. Anything else (audio WebKit can't play) is a warning, never an
// unhandled rejection.
export function play(media, warn = (...args) => console.warn(...args)) {
  let started;
  try {
    started = media.play();
  } catch (err) {
    started = Promise.reject(err);
  }
  return Promise.resolve(started).catch((err) => {
    if (err?.name !== "AbortError") warn("Playback failed:", err);
  });
}

// --- busy ------------------------------------------------------------------

// The button is disabled at once and shows a spinner when the work takes
// longer than 300 ms; it comes back when the work is done either way.
export async function busy(button, work) {
  const wasDisabled = button.disabled;
  button.setAttribute("aria-busy", "true");
  button.disabled = true;
  const spin = setTimeout(() => button.classList.add("spinning"), 300);
  try {
    return await work;
  } finally {
    clearTimeout(spin);
    button.classList.remove("spinning");
    button.removeAttribute("aria-busy");
    button.disabled = wasDisabled;
  }
}

// --- transitions -----------------------------------------------------------

// An element goes away: it slides and fades (200 ms), then the gap closes
// (200 ms), then it is removed. With reduced motion: a 150 ms fade.
export async function leave(el) {
  el.classList.add("leaving");
  if (reducedMotion()) {
    await wait(150);
  } else {
    await wait(200);
    el.style.height = `${el.getBoundingClientRect().height}px`;
    el.getBoundingClientRect();  // so the height change below transitions
    el.classList.add("collapsing");
    el.style.height = "0px";
    await wait(200);
  }
  el.remove();
}

// One highlight of an element (e.g. restored by undo), 600 ms.
export function flash(el) {
  el.classList.remove("flash");
  el.getBoundingClientRect();  // restarts the animation when it is running
  el.classList.add("flash");
  clearTimeout(el._flashTimer);
  el._flashTimer = setTimeout(() => el.classList.remove("flash"), 600);
}

// --- menu ------------------------------------------------------------------

let openMenu = null;  // {el, anchor, close}

function closeMenu() {
  openMenu?.close();
}

// A popover menu below the anchor's right edge, or at a point (right-click).
// items: {label, icon?, shortcut?, danger?, disabled?, run} or null for a
// separator; the caller puts dangerous items last, after a null.
// ``title``: a heading over the items (the menu's name); ``onClose``: called
// when the menu goes, however it goes.
export function menu(items, anchor, { title = null, onClose = null } = {}) {
  closeMenu();
  const isPoint = !(anchor instanceof Element);
  const returnTo = isPoint ? document.activeElement : anchor;
  const name = title || (isPoint ? "Actions" : anchor.getAttribute("aria-label") || anchor.textContent.trim() || "Actions");
  const el = h("div", { class: "menu", role: "menu", "aria-label": name, tabindex: "-1" });
  if (title) el.append(h("div", { class: "menu-title", "aria-hidden": "true" }, title));
  const icons = items.some((item) => item?.icon);  // then every label lines up after an icon column
  for (const item of items) {
    if (!item) {
      el.append(h("hr", { role: "separator" }));
      continue;
    }
    el.append(h("button", {
      type: "button", role: "menuitem", class: item.danger ? "danger" : null, disabled: !!item.disabled,
      onclick: () => { close(); item.run(); },
      onpointerenter: (e) => e.currentTarget.focus(),
    },
    icons ? h("span", { class: "menu-icon", "aria-hidden": "true" }, item.icon) : null,
    h("span", { class: "menu-label" }, item.label),
    item.shortcut ? h("kbd", {}, item.shortcut) : null));
  }

  const enabled = () => [...el.querySelectorAll("button:not([disabled])")];
  const onKey = (e) => {
    const list = enabled();
    const at = list.indexOf(document.activeElement);
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      const step = e.key === "ArrowDown" ? 1 : -1;
      list[(at + step + list.length) % list.length]?.focus();
    } else if (e.key === "Home" || e.key === "End") {
      e.preventDefault();
      (e.key === "Home" ? list[0] : list[list.length - 1])?.focus();
    } else if (e.key === "Escape" || e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      close();
    }
  };
  const onOutside = (e) => {
    if (el.contains(e.target)) return;
    // A click on the ⋯ button that opened the menu closes it (the button toggles).
    if (!isPoint && anchor.contains(e.target)) return;
    close(false);
  };
  const onAway = (e) => { if (!el.contains(e.target)) close(false); };
  const onBlur = () => close(false);

  function close(refocus = true) {
    if (openMenu?.el !== el) return;
    openMenu = null;
    el.remove();
    document.removeEventListener("pointerdown", onOutside, true);
    window.removeEventListener("scroll", onAway, true);
    window.removeEventListener("resize", onBlur);
    window.removeEventListener("blur", onBlur);
    if (!isPoint) anchor.setAttribute("aria-expanded", "false");
    if (refocus && returnTo?.isConnected) returnTo.focus();
    onClose?.();
  }

  el.addEventListener("keydown", onKey);
  document.body.append(el);
  const box = el.getBoundingClientRect();
  let x;
  let y;
  if (isPoint) {
    ({ x, y } = anchor);
  } else {
    const r = anchor.getBoundingClientRect();
    x = r.right - box.width;
    y = r.bottom + 6;
    // No room below: open above the anchor.
    if (y + box.height > innerHeight - 8 && r.top - 6 - box.height >= 8) y = r.top - 6 - box.height;
    anchor.setAttribute("aria-expanded", "true");
  }
  el.style.left = `${Math.max(8, Math.min(x, innerWidth - box.width - 8))}px`;
  el.style.top = `${Math.max(8, Math.min(y, innerHeight - box.height - 8))}px`;
  if (isPoint) el.style.transformOrigin = "top left";

  openMenu = { el, anchor, close };
  document.addEventListener("pointerdown", onOutside, true);
  window.addEventListener("scroll", onAway, true);
  window.addEventListener("resize", onBlur);
  window.addEventListener("blur", onBlur);
  // Nothing to pick: the menu itself takes focus, so Esc still closes it.
  (enabled()[0] || el).focus();
}

const SVG = "http://www.w3.org/2000/svg";
function dots() {
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  for (const cx of [5, 12, 19]) {
    const c = document.createElementNS(SVG, "circle");
    c.setAttribute("cx", cx);
    c.setAttribute("cy", 12);
    c.setAttribute("r", 2);
    svg.append(c);
  }
  return svg;
}

// The round ⋯ button; items() is called on each open, so the menu is current.
export function moreButton(items, label = "More") {
  const button = h("button", {
    type: "button", class: "more", "aria-label": label, title: label,
    "aria-haspopup": "menu", "aria-expanded": "false",
  }, dots());
  button.addEventListener("click", () => {
    if (openMenu?.anchor === button) closeMenu();
    else menu(items(), button);
  });
  return button;
}

// --- commands --------------------------------------------------------------

const KEY_NAMES = { "⌫": "backspace", "⌦": "delete", "↩": "enter", "⎋": "escape", "space": " ",
  "↑": "arrowup", "↓": "arrowdown", "←": "arrowleft", "→": "arrowright" };

// Does a keydown match a shortcut like "⌘J", "⌘⌫" or "⌘⇧N"?
export function matchesShortcut(shortcut, e) {
  const mods = { "⌘": "metaKey", "⇧": "shiftKey", "⌥": "altKey", "⌃": "ctrlKey" };
  let key = "";
  const want = new Set();
  for (const ch of shortcut) {
    if (mods[ch] && !key) want.add(mods[ch]);
    else key += ch;
  }
  for (const flag of Object.values(mods)) if (!!e[flag] !== want.has(flag)) return false;
  key = key.toLowerCase();
  return String(e.key || "").toLowerCase() === (KEY_NAMES[key] ?? key);
}

const registry = new Map();
let keysBound = false;

// The command a keydown runs, or null: none while typing in a field, and
// none for a held key's repeats (holding ⌘⌫ must not trash meeting after meeting).
export function commandFor(e, entries) {
  if (e.repeat || isEditable(e.target)) return null;
  for (const [name, c] of entries) {
    if (c.shortcut && matchesShortcut(c.shortcut, e)) return name;
  }
  return null;
}

const safely = (c) => {
  try { return !!c.enabled(); } catch { return false; }
};

export const commands = {
  register(name, spec) {
    registry.set(name, spec);
  },

  run(name) {
    const c = registry.get(name);
    if (!c || !safely(c)) return false;
    c.run();
    return true;
  },

  enabled() {
    return [...registry].filter(([, c]) => safely(c)).map(([name]) => name);
  },

  // Tells the native menu bar which of its items work right now.
  publish() {
    const handler = typeof window !== "undefined" ? window.webkit?.messageHandlers?.palaver : null;
    handler?.postMessage({ type: "commands", enabled: commands.enabled() });
  },

  bindKeys() {
    if (keysBound) return;
    keysBound = true;
    document.addEventListener("keydown", (e) => {
      if (matchesShortcut("⌘Z", e)) {
        e.preventDefault();
        undo();
        return;
      }
      const name = commandFor(e, registry);
      if (name) {
        e.preventDefault();
        commands.run(name);
      }
    });
  },
};

// --- usage (#59) -----------------------------------------------------------

// What the page counts for the local usage log: window actions, views, tabs,
// ⌘K picks and errors shown, batched and posted every few seconds (and when
// the page goes away). Never the text of a meeting; an error's text is cut short.
export class UsageCounter {
  constructor({ send, limit = 200 } = {}) {
    this.send = send;  // (body) => Promise, or null: nothing is posted (node tests)
    this.limit = limit;
    this.events = [];
    this.known = new Map();  // kind -> Set of ids: the catalog, for "never used"
    this.catalogSent = false;
  }

  count(kind, id, extra = {}) {
    if (this.events.length < this.limit) this.events.push({ kind, ...(id == null ? {} : { id: String(id) }), ...extra });
  }

  // Ids that exist, used or not (the action registry, the pages, the tabs).
  catalog(kind, ids) {
    const set = this.known.get(kind) || new Set();
    const before = set.size;
    for (const id of ids) set.add(String(id));
    this.known.set(kind, set);
    if (set.size !== before) this.catalogSent = false;  // sent again only when it grew
  }

  // The body to post now, or null when there is nothing new; taking it empties the queue.
  take() {
    if (!this.events.length && this.catalogSent) return null;
    const body = { events: this.events };
    if (!this.catalogSent) {
      body.catalog = Object.fromEntries([...this.known].map(([k, s]) => [k, [...s].sort()]));
      this.catalogSent = true;
    }
    this.events = [];
    return body;
  }

  flush() {
    const body = this.take();
    if (!body || !this.send) return;
    Promise.resolve().then(() => this.send(body)).catch(() => { /* counting never bothers the user */ });
  }
}

export const usage = new UsageCounter({
  send: typeof fetch === "function" && typeof window !== "undefined"
    ? (body) => fetch("/api/usage", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body), keepalive: true })
    : null,
});

// ``actions`` (name -> function) whose every call is counted as
// "<scope>.<name>": one hook for a whole action registry, not one per action.
export function tracked(scope, actions, counter = usage) {
  counter.catalog("action", Object.keys(actions).map((name) => `${scope}.${name}`));
  return Object.fromEntries(Object.entries(actions).map(([name, fn]) => [name, function (...args) {
    counter.count("action", `${scope}.${name}`);
    return fn.apply(this, args);
  }]));
}

if (typeof window !== "undefined" && typeof setInterval === "function") {
  setInterval(() => usage.flush(), 5000);
  window.addEventListener?.("pagehide", () => usage.flush());
}

// The native menu bar (Task 9) calls these.
if (typeof window !== "undefined") {
  window.palaver = { command: (n) => commands.run(n), undo };
}
