// The ⌘K palette (UI spec, phase 2): finds meetings, people and projects,
// runs the open meeting's commands (with their shortcuts), and shows the
// places opened lately before anything is typed. Keyboard first: ↑ ↓ move,
// Enter runs, Esc or ⌘K closes; focus goes back where it came from.
//
// The page gives it what to show: ``groups(query)`` answers
// [{title, entries: [{kind, id, label, detail?, shortcut?, danger?}]}], and
// ``pick(entry)`` runs one.

import { h } from "./ui.js";
import { paletteMove } from "./logic.js";

let open = null;  // {el, close}

const KIND_MARK = { meeting: "M", person: "P", project: "#", page: "→", command: "⌘", search: "⌕" };

export const paletteOpen = () => !!open;

export function closePalette(refocus = true) {
  open?.close(refocus);
}

export function togglePalette(spec) {
  if (open) closePalette();
  else showPalette(spec);
}

function showPalette({ groups, pick }) {
  const returnTo = document.activeElement;
  let shown = [];  // the entries, in the order shown
  let at = -1;

  const input = h("input", {
    type: "text", class: "palette-input", role: "combobox", "aria-label": "Search or run a command",
    "aria-expanded": "true", "aria-controls": "palette-list", "aria-autocomplete": "list",
    placeholder: "Find a meeting, person or project, or run a command", spellcheck: "false", autocomplete: "off",
  });
  const list = h("div", { class: "palette-list", id: "palette-list", role: "listbox", "aria-label": "Results" });
  const backdrop = h("div", { class: "palette-backdrop", onclick: () => close() });
  const el = h("div", { class: "palette", role: "dialog", "aria-modal": "true", "aria-label": "Search or run a command" },
    h("div", { class: "palette-field" },
      h("span", { class: "palette-glass", "aria-hidden": "true" }), input, h("kbd", {}, "esc")),
    list,
    h("p", { class: "palette-foot", "aria-hidden": "true" }, "↑ ↓ to move · ↩ to open · ⌘K to close"));

  function select(i) {
    at = i;
    const options = [...list.querySelectorAll("[role=option]")];
    options.forEach((o, j) => o.setAttribute("aria-selected", String(j === at)));
    const current = options[at];
    if (current) {
      input.setAttribute("aria-activedescendant", current.id);
      current.scrollIntoView({ block: "nearest" });
    } else {
      input.removeAttribute("aria-activedescendant");
    }
  }

  function render() {
    const found = groups(input.value);
    shown = [];
    const rows = [];
    for (const g of found) {
      if (!g.entries.length) continue;
      if (g.title) rows.push(h("div", { class: "palette-group", role: "presentation" }, g.title));
      for (const e of g.entries) {
        const i = shown.length;
        shown.push(e);
        rows.push(h("div", {
          class: `palette-option${e.danger ? " danger" : ""}`, role: "option", id: `palette-option-${i}`,
          "aria-selected": "false", "data-kind": e.kind,
          onpointermove: () => { if (at !== i) select(i); },
          onclick: () => run(i),
        },
        h("span", { class: "palette-mark", "aria-hidden": "true" }, KIND_MARK[e.kind] || "·"),
        h("span", { class: "palette-label" }, e.label),
        e.detail ? h("span", { class: "palette-detail" }, e.detail) : null,
        e.shortcut ? h("kbd", {}, e.shortcut) : null));
      }
    }
    if (!shown.length) rows.push(h("p", { class: "palette-empty" }, `Nothing found for “${input.value.trim()}”.`));
    list.replaceChildren(...rows);
    select(shown.length ? 0 : -1);
  }

  function run(i) {
    const e = shown[i];
    if (!e) return;
    close(false);
    document.getElementById("main")?.focus({ preventScroll: true });  // the page it opens takes it from here
    pick(e);
  }

  input.addEventListener("input", render);
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      select(paletteMove(at, e.key === "ArrowDown" ? 1 : -1, shown.length));
    } else if (e.key === "Enter") {
      e.preventDefault();
      run(at);
    } else if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      close();
    } else if (e.key === "Tab") {
      e.preventDefault();  // the palette keeps the keyboard until it closes
    }
  });

  function close(refocus = true) {
    if (open?.el !== el) return;
    open = null;
    el.remove();
    backdrop.remove();
    if (refocus && returnTo?.isConnected && returnTo !== document.body) returnTo.focus({ preventScroll: true });
    else if (refocus) document.getElementById("main")?.focus({ preventScroll: true });
  }

  document.body.append(backdrop, el);
  open = { el, close };
  render();
  input.focus();
}
