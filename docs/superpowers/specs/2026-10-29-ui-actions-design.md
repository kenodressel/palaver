# Meetings window: actions you can see, feedback you can follow

Date: 2026-10-29 · Status: draft for review · Mockup: [2026-10-29-ui-actions-mockup.html](2026-10-29-ui-actions-mockup.html) (open it in a browser; contents are made up)

## Why

The Meetings window grew feature by feature. Each action got whatever form was handy when it was built. Most meeting-level actions are tiny text links in the date line ("change event", "move to trash", "review again"). "join with the one before" sits under the header. A speaker lane has "remove" and "merge" as plain words. ✎ and ✂ hide next to transcript times. Every notice has its own style. The user's words: it "follows no coherent design concept", and the actions are "anything but visible".

Second, actions give no feedback. Trash makes the meeting vanish and silently opens the newest one. Join and split reload the page with a grey sentence. Merging speakers makes a lane disappear. Nothing animates. The user wants it to feel "snappy": instant feedback, being able to follow what changed, and undo.

The visual language stays. Colours, Bricolage/Instrument type, pill shapes, speaker lanes and cards all stay. This is about order, visibility and feedback, not a restyle.

## Goals

- One rule for where an action lives and how prominent it looks, applied everywhere.
- Every click answers within 100 ms. Every change shows what happened and offers a way back.
- A start page, "Today", for opening the app, and a top navigation bar.
- Everything that waits on the user ("needs you") in one pattern instead of scattered chips and notices.

## Non-goals

- No new visual style, no new fonts or colours, no framework rewrite. The page stays vanilla JS with `h()` in `palaver/webapp/static/app.js`.
- No new features beyond what the structure needs. Actions keep their current meaning. Undo, the Today page, ⌘K and the menu bar behaviour are the additions.
- No change to how recordings are processed.

## Anti-goals (a failure even if it works)

- Actions moved into ⋯ menus where nobody finds them. Every ⋯ action is also in the macOS menu bar, the list's right-click menu and ⌘K.
- Animation that slows the user down. Nothing over 300 ms for feedback, never blocking input.
- Confirmation dialogs for reversible things.
- Losing the meeting list next to the meeting. The user called it "extremely good".

## Decided with the user

0. **The UI is English everywhere**, as today: page, native menus, menu bar menu. The German labels in the mockup are placeholders; this document uses the English labels.

1. **Top navigation bar:** Today · Meetings · People · Projects · Glossary, with search/⌘K on the right. This is direction C of the mockup.
2. **"Today" is the start page** when the window opens. It holds:
   - a large "Live now" card during a call (live transcript, speakers);
   - the next meeting with its prep;
   - "Needs you" (open questions, answered in place);
   - the latest meetings.
3. **"Meetings" keeps list and meeting side by side**, as today. A meeting clicked on Today opens there.
4. **The review flow and "needs you" are the same thing.**
   - Open items show on Today and as a strip at the top of each meeting ("3 things to check …").
   - "Review all in order" replaces today's review entry.
5. **Meeting header:**
   - Frequent actions are visible buttons: Play, and Write notes/Rewrite notes as the one primary (violet) button.
   - Everything rare goes in a ⋯ menu: Change Event…, Join with Previous/Next, Split At…, Review Again, and Move to Trash (red, last, separated). The mockup also shows "Exportieren…": that is not part of this work (no export exists; *builder-check call: dropped*).
6. **Speaker lanes** get a ⋯ menu each (Rename, Play Voice, Merge Into…, Not a Speaker) instead of the words "remove"/"merge".
7. **Toasts with Undo** after every action that changes something.
8. **Instant feedback and visible transitions.** See the feedback rules below.
9. **Menu bar icon:** a left click opens the window, a right click shows the menu. The user chose this knowing that Apple's HIG says a menu bar extra should show a menu on click.
10. **Order:** phase 1 is the action and feedback system in today's layout. Phase 2 is the navigation, Today and ⌘K.

## Action rule (everywhere)

| Level | Looks like | Used for |
|---|---|---|
| Primary | violet filled pill button, at most one per view | the main thing to do here (e.g. Write notes) |
| Frequent | pill button with icon + label in a fixed toolbar | Play, Edit, … |
| Rare | item in a ⋯ menu (only when ≥ 3 items, per Apple HIG); same items in the macOS menu bar, right-click menu and ⌘K | Change Event, Join, Split |
| Destructive | red item, last in its menu, behind a separator; reversible → undo, not a dialog | Move to Trash, Not a Speaker |
| Link | underlined/coloured text | navigation only (to a project, open a meeting), never an action |

Suggestions stay chips (project "Northwind?", speaker name guesses), in one consistent chip style.

## Where today's actions go

| Today | New home |
|---|---|
| "Write/Rewrite notes" button | primary button in the meeting toolbar; while running, shows progress (see feedback) |
| "change event" / "pick event" link | ⋯ → Change Event… (the picker itself stays) |
| "move to trash" link | ⋯ → Move to Trash (⌘⌫); list right-click |
| "review again" link, "Reviewed ✓" | status pill "✓ Reviewed" in the date line; ⋯ → Review Again |
| "join with the one before/after" links | ⋯ → Join with Previous/Next (⌘J for previous); also a "continues in …" tab at the ribbon's edge when a neighbour exists (phase 2) |
| ✂ on transcript lines, cut hint text, cut bar | line toolbar "Split here" + ⋯ → Split At… (opens the same cut bar); the cut bar's four choices stay |
| ✎ on transcript lines | line toolbar on hover, right side of the line: Play from here, Edit, Fix spelling, Copy, Split here; same in right-click |
| selection popover "Fix spelling…" | stays, also reachable from the line toolbar |
| lane "remove" / "merge" / "by voice ×" / play icon | lane ⋯: Rename, Play Voice, Merge Into…, Not <Name> (for voice/inferred names), Not a Speaker |
| inferred-name row (Yes/No), name chips, cut suggestion, event missing, unsure project | "needs you" items: strip at the top of the meeting, cards on Today |
| sidebar text tabs, gear, filter dropdown, review button | top navigation bar; settings as a gear at the bar's right end; filter becomes part of the Meetings list header (phase 2) |
| Projects "Merge into…" / "Delete", People actions | same action rule: ⋯ per row, destructive with undo |

## Feedback rules

Based on NN/g's response-time limits and practitioner guidance on motion (sources at the end):

1. **Within 100 ms of a click**, the control shows it is working: pressed state, then a small spinner if the result takes longer than ~300 ms. It is disabled while working. No action may look like nothing happened.
2. **Optimistic where safe.** Renaming, project chips, naming a speaker and confirming a suggestion update the page at once and roll back with an error toast if the server says no.
3. **Show the way, not just the result:**
   - Trash: the list item slides out (transform + fade, ~200 ms, then the gap collapses). The next meeting is selected, visibly.
   - Join: the two list items move together into one, and the joined meeting is highlighted.
   - Split: the new meeting appears in the list with a brief highlight. The page says where the rest went, with a link.
   - Merging speakers: the merged lane's segments take the target's colour and the lane collapses into the target.
   - Removing a speaker: the lane fades and collapses. Its transcript lines fade out.
   - Restored by undo: the item returns to its place and flashes once.
4. **Durations:**
   - 100–150 ms for press and hover feedback;
   - 200–300 ms for state changes and list moves;
   - nothing over 500 ms.
   - With `prefers-reduced-motion`, only cross-fades are used.
5. **Long operations.** Over 1 s: a busy state. Over 10 s (Write notes, reprocessing): step text and rough remaining time, e.g. "Writing notes · ~40 s". Also:
   - a way to cancel;
   - the user can keep working elsewhere;
   - the list item shows the state too.
6. **Errors** say in plain words what did not happen and offer "Try again". This is shown in a toast or in place, never as `alert()`.

## Undo

- **The toast:**
  - Bottom centre, dark pill, one line in plain language, e.g. “‘Foundry’ moved to Trash” or “Speaker 3 → Henrik · 14 lines”.
  - One "Undo" button and a draining bar.
  - 8 s, paused while hovered or focused.
  - `role="status"` in a polite live region that exists before the text goes in.
  - A new toast replaces the old one. The old action stays undoable via ⌘Z.
- **⌘Z / Edit → Undo** undoes the last change, independent of the toast. Undo history: last 20 changes for the session, page-side, each entry knowing its inverse API call.
- **Actions and their inverse:**

| Action | Undo |
|---|---|
| Move meeting to trash | restore from `Recordings/.trash` (new API) |
| Join | split back at the join point, restoring both meetings' ids, names and projects (builder decides: inverse `split` or a saved pre-join copy; `cutting.py` says split and join "undo each other") |
| Split (own meeting / to next) | join back |
| Split with discard before/after | restore the discarded part from `.trash` and join it back |
| Merge speakers | un-merge (exists: `mergeSpeaker(label, null)`) |
| Remove speaker | restore (exists: `removeSpeaker(label, false)`) |
| Name a speaker / reject a voice name | set the previous name |
| Project added / removed / confirmed | the inverse project change |
| Calendar event changed | set the previous event (or "none") |
| Line edited | previous text (exists: back to heard) |
| Marked reviewed | review again (exists) |
| Glossary respell everywhere | revert those replacements (builder: if not cheaply reversible, keep the current confirm-free flow but say so in the toast without undo) |
| Delete or merge a project, delete a glossary term, rename a person, name voices across meetings | restore a snapshot of the affected store (projects store, glossary, people/voices data) taken just before the change; these are small JSON files. *Builder-check call:* every action that loses its `confirm()` gets undo this way, so none becomes irreversible without warning |

- **Confirmation dialogs** remain only for the truly irreversible. Today none exists in the UI. A later "Empty Trash" would get one, with a specific button label ("Delete Permanently").

## macOS integration

- **Native menu bar of the window** (`webapp/window.py` builds it today: Palaver, Edit, View). Add a **"Meeting"** menu that mirrors the ⋯ items with shortcuts:
  - Play/Pause (Space when not typing);
  - Write notes (⌘⇧N);
  - Change Event… ;
  - Join with Previous (⌘J);
  - Split At… ;
  - Review Again;
  - Move to Trash (⌘⌫).

  Items are disabled when they don't apply. Edit → Undo/Redo trigger the page's undo.
- **Right-click on a list item** shows the meeting's ⋯ menu (page-drawn, same component).
- **Menu bar icon:** left click opens/focuses the Meetings window. Right click (and ctrl-click) shows today's menu. Builder: rumps only does menus. This needs the NSStatusItem button's action with `sendActionOn` for left/right mouse up, or replacing rumps' status item handling.

## Phase 1: actions and feedback in today's layout

1. Shared components in `app.js`/`app.css`: toolbar button, ⋯ menu (keyboard: arrows, Enter, Esc; closes on outside click; red destructive section), toast with undo and ⌘Z history, busy state for buttons, list item enter/leave/flash transitions, reduced-motion fallbacks.
2. Meeting header toolbar and ⋯ menu; remove the small links from the date line; status pill for reviewed/live/processing.
3. Speaker lane ⋯ menus; merge and remove transitions.
4. Transcript line toolbar (hover, right side) and right-click; cut flow started from there or from ⋯.
5. Undo for every action in the table, including the new restore-from-trash API and join/split inverses.
6. Notes writing with progress text and cancel. Builder: cancel may mean "stop waiting and ignore the result" if the model call can't be interrupted.
7. "Meeting" menu in the native menu bar; Edit → Undo wired to the page.
8. Menu bar icon: left click opens the window, right click the menu.
9. Remove every `confirm()`/`alert()` from the page; errors go to toasts or in place.

## Phase 2: navigation, Today, ⌘K

1. Top navigation bar replacing the sidebar's brand/tabs/gear. The meeting list moves under "Meetings" (left column, as today) with search and the filter as part of its header.
2. Today page: Live now (only during a recording), Next meeting (from the calendar, with prep link), Needs you (cards with in-place answers, "Review all in order"), Recent (latest meetings, same list items).
3. "Needs you" model: one API listing open items per meeting (unnamed voices, inferred names, unsure projects, cut suggestion, missing event, unreviewed), used by Today, the meeting strip, the list dot and the counter.
4. ⌘K palette:
   - finds meetings, people and projects, and runs actions on the current meeting;
   - shows each command's shortcut;
   - shows recent items before typing;
   - opens and closes with ⌘K, Esc closes;
   - full keyboard support.
5. Split by hovering the ribbon (a cut line follows the pointer). The "Continues in …" tabs on the ribbon edge were built and then removed again (2026-10-30): the user did not find them worth the room.

## Later (noted, not in these phases)

- **Clean up the menu bar menu.** Old quick settings: "Open latest transcript in Notion", "Open latest recording folder", "Open log". "Record Teams calls and Slack huddles automatically" is still one item and must become two, matching the Settings page's separate switches.

## Constraints

- Plain JS/CSS in `palaver/webapp/static/`, no build step. The page runs in a WKWebView inside the menu bar app (`webapp/window.py`) and also in a normal browser for tests.
- Keep design tokens (`:root` in `app.css`) and dark mode. New colours, if any, are derived from existing tokens.
- API changes go through `palaver/webapp/api.py` and `server.py` with pytest coverage, like existing routes.
- WKWebView: `confirm()`/`alert()` work again (6490404) but phase 1 removes their use anyway.
- Visual checks with Playwright on a scratch copy of the recordings. Screenshots and `.playwright-mcp` contain meeting content and are deleted after each check.
- The app can be restarted only when Palaver is idle (check, then restart, gated in one script).

## Left to the builder

- Exact icons (inline SVG, stroke style as in the mockup), spacing and animation curves within the rules above.
- How undo of join/split is stored.
- Shortcut choices beyond those listed, avoiding clashes with WKWebView/macOS defaults.
- Whether the ⋯ menu is one shared component for header, lanes, list and Projects/People rows (expected: yes).

## Sources

- NN/g, Confirmation Dialogs: https://www.nngroup.com/articles/confirmation-dialog/
- NN/g, 10 Usability Heuristics: https://www.nngroup.com/articles/ten-usability-heuristics/
- NN/g, Response Times: The 3 Important Limits: https://www.nngroup.com/articles/response-times-3-important-limits/
- Apple HIG, The menu bar (menu bar extras): https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- Apple HIG, Pull-down buttons (More button, ≥ 3 items, destructive items): https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons
- Scott O'Hara, A toast to a11y toasts: https://scottohara.me/blog/2019/07/08/a-toast-to-a11y-toasts.html
- Vercel, Toast guidelines: https://vercel.com/design/toast
- Val Head, How fast should your UI animations be?: https://valhead.com/?p=2978
- Superhuman, How to build a remarkable command palette: https://blog.superhuman.com/how-to-build-a-remarkable-command-palette/
