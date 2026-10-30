// Export and import of a meeting as one .palaver file (#58): the export
// dialog, the import of a picked or dropped file with its questions (the
// same meeting here already; the voices that came with it). What happens
// to the page after an import (the list, the meeting, Undo) is app.js's.

import { h, toast, busy } from "./ui.js";
import { exportChoices, exportRequest, exportedText, isPalaverFile, collisionText, voicesQuestion }
  from "./logic.js";

class Failed extends Error {}

async function post(path, body, contentType = "application/json") {
  const resp = await fetch(path, { method: "POST", headers: { "Content-Type": contentType },
    body: contentType === "application/json" ? JSON.stringify(body) : body });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Failed(data.error || `${resp.status}`);
  return data;
}

// A small modal: a title, a body, buttons (the last is the default: it has
// the focus, Return presses it). Esc, a click beside it or ``close()`` end it;
// resolves with the button's ``value`` (undefined when closed). ``run(button)``:
// work before it closes (the dialog stays while it runs, its buttons off, and
// Esc or a click beside it don't end it); an error keeps it open.
export function dialog({ title, body = [], buttons, label = title }) {
  const before = document.activeElement;
  let running = false;
  let done;
  const result = new Promise((resolve) => { done = resolve; });
  const close = (value) => {
    backdrop.remove();
    document.removeEventListener("keydown", onKey, true);
    if (before?.isConnected) before.focus?.({ preventScroll: true });
    done(value);
  };
  const error = h("p", { class: "dialog-error error", role: "alert", hidden: true });
  const row = h("div", { class: "dialog-buttons" }, buttons.map((b, i) => {
    const el = h("button", { type: "button", class: i === buttons.length - 1 ? "btn primary" : "btn",
      onclick: async () => {
        if (running) return undefined;
        if (!b.run) return close(b.value);
        running = true;
        const others = [...row.children].filter((x) => x !== el && !x.disabled);
        for (const x of others) x.disabled = true;
        try {
          await busy(el, b.run(el));
        } catch (err) {
          error.textContent = err.message;
          error.hidden = false;
          return undefined;
        } finally {
          running = false;
          for (const x of others) x.disabled = false;
        }
        return close(b.value);
      } }, b.label);
    return el;
  }));
  const box = h("div", { class: "dialog", role: "dialog", "aria-modal": "true", "aria-label": label },
    h("h2", {}, title), ...body, error, row);
  const backdrop = h("div", { class: "dialog-backdrop",
    onmousedown: (e) => { if (e.target === backdrop && !running) close(); } }, box);
  function onKey(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      if (!running) close();
    } else if (e.key === "Tab") {  // the focus stays in the dialog
      const focusable = [...box.querySelectorAll("input:not([disabled]), button:not([disabled])")];
      const at = focusable.indexOf(document.activeElement);
      const next = e.shiftKey ? (at <= 0 ? focusable.length - 1 : at - 1) : (at + 1) % focusable.length;
      e.preventDefault();
      focusable[next]?.focus();
    }
  }
  document.addEventListener("keydown", onKey, true);
  document.body.append(backdrop);
  row.lastChild.focus();
  return { result, close, el: box };
}

// Export…: what goes in, then the file saved to Downloads.
export function openExport(m, title) {
  const choices = exportChoices(m);
  const ticked = Object.fromEntries(choices.map((c) => [c.key, !!(c.always || c.on)]));
  const boxes = choices.map((c) => h("label", { class: `export-choice${c.always ? " always" : ""}` },
    h("input", { type: "checkbox", name: c.key, checked: ticked[c.key], disabled: !!c.always,
      onchange: (e) => { ticked[c.key] = e.target.checked; } }),
    h("span", { class: "export-label" }, c.label, c.always ? h("span", { class: "meta" }, " · always") : null),
    c.hint ? h("span", { class: "meta export-hint" }, c.hint) : null));
  const send = async (confirmLocal) => {
    const answer = await post(`/api/meetings/${encodeURIComponent(m.id)}/export`, exportRequest(ticked, confirmLocal));
    if (answer.question === "local_only") return answer;
    toast(exportedText(answer));
    return answer;
  };
  let first;
  const d = dialog({
    title: `Export “${title}”`,
    body: [h("p", { class: "meta" }, "One .palaver file to send to a colleague who uses Palaver: by AirDrop, Slack or mail."),
      h("fieldset", { class: "export-choices" }, h("legend", { class: "visually-hidden" }, "What goes in"), ...boxes)],
    buttons: [{ label: "Cancel" }, { label: "Export", value: "export", run: async () => { first = await send(false); } }],
  });
  return d.result.then(async (value) => {
    if (value !== "export" || first?.question !== "local_only") return;
    const again = dialog({
      title: "This meeting is kept on this Mac",
      body: [h("p", {}, "It is marked “Keep on This Mac”: no cloud model and no MCP client gets it. "
        + "The file can go anywhere once it leaves. Export it anyway?")],
      buttons: [{ label: "Cancel" }, { label: "Export Anyway", value: "export", run: () => send(true) }],
    });
    await again.result;
  });
}

// Import…: a file picker for .palaver files.
export function pickImport(onFile) {
  const picker = h("input", { type: "file", accept: ".palaver", hidden: true,
    onchange: () => {
      const [file] = picker.files;
      picker.remove();
      if (file) onFile(file);
    } });
  document.body.append(picker);
  picker.click();
}

// A .palaver file dropped anywhere on the window imports it; a place that
// takes files itself (my notes) handles its own drops first.
export function wireDrop(onFile) {
  const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes("Files");
  document.addEventListener("dragover", (e) => {
    if (!hasFiles(e) || e.defaultPrevented) return;
    e.preventDefault();  // else the web view opens the file in place of the page
    document.body.classList.add("dropping-file");
  });
  document.addEventListener("dragleave", (e) => {
    if (!e.relatedTarget) document.body.classList.remove("dropping-file");
  });
  document.addEventListener("drop", (e) => {
    document.body.classList.remove("dropping-file");
    if (!hasFiles(e) || e.defaultPrevented) return;
    e.preventDefault();
    const files = [...e.dataTransfer.files].filter((f) => isPalaverFile(f.name));
    if (!files.length) {
      toast("Only a .palaver file can be dropped here: a meeting a colleague exported");
      return;
    }
    onFile(files[0]);
  });
}

// Sends ``file``; asks when the meeting is here already. Resolves with the
// server's answer to the import, or null when nothing was imported.
export async function importFile(file) {
  if (!isPalaverFile(file.name)) {
    toast(`“${file.name}” is not a .palaver file`);
    return null;
  }
  toast(`Importing “${file.name}”…`, { short: true });
  let answer;
  try {
    answer = await post("/api/import", file, "application/octet-stream");
  } catch (err) {
    toast(err.message, { action: { label: "Try again", run: () => importFile(file) } });
    return null;
  }
  if (answer.question !== "collision") return answer;
  let imported = null;
  const d = dialog({
    title: "This meeting is here already",
    body: [h("p", {}, collisionText(answer))],
    buttons: [{ label: "Keep Mine" }, { label: "Import as a Separate Meeting", value: "separate",
      run: async () => { imported = await post("/api/import?separate=1", file, "application/octet-stream"); } }],
  });
  await d.result;
  return imported;
}

// The voices that came with an import: added to the voice bank on a yes,
// deleted on a no; Esc leaves the question on the meeting. Resolves with
// the meeting as the server has it then (with ``undo``), or null.
export async function askVoices(meetingId, voices, from) {
  let answer = null;
  const decide = (add) => async () => {
    answer = await post(`/api/meetings/${encodeURIComponent(meetingId)}/imported-voices`, { add });
  };
  // Biometric data: the default (focus, Return) is to keep them out.
  const d = dialog({
    title: "Add their voices?",
    body: [h("p", {}, voicesQuestion(voices, from))],
    buttons: [{ label: "Add to Voice Bank", value: "yes", run: decide(true) },
      { label: "Don’t Add", value: "no", run: decide(false) }],
  });
  const value = await d.result;
  return value ? { ...answer, added: value === "yes" } : null;
}

// Answer the voices question from the meeting page's buttons.
export async function decideVoices(meetingId, add, button) {
  return busy(button, post(`/api/meetings/${encodeURIComponent(meetingId)}/imported-voices`, { add }));
}
