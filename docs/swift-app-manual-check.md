# Swift app: manual check before 0.5.0

Everything below needs you at the Mac. None of it was run unattended: the
app was built, signed and installed into a throwaway home by
`make smoke-install`, but never started.

## 0. Install the build

1. Quit Palaver, or wait until it is idle (`palaver daemon status`).
2. In the `swift-app` worktree:
   `PALAVER_SIGN_IDENTITY="Palaver Release" make release`, then
   `PALAVER_ASSETS_DIR="$PWD/dist" sh dist/install.sh`.
3. Open Palaver. macOS may ask for the microphone and System Audio
   Recording again: the app's executable is new. The Keychain may ask once
   whether `palaver-python` may read your Notion token. Choose "Always Allow".
4. Check `~/Library/Logs/palaver/daemon.log`. It should have an `app_start`
   line with `"app": "native"`, and `crashes.log` should have nothing new.

## 0b. What `make smoke-install` cannot check

The smoke never starts the app, so these two are checked here, with the app
running:

- `palaver app ping` says "Palaver answers on …/app.sock (pid N)", and N is
  the pid of `Contents/MacOS/Palaver` (`pgrep -f Contents/MacOS/Palaver`).
- The window's server is up: `pgrep -fl webapp-serve` shows one process, and
  a left-click on the icon opens the window with your meetings.

## 1. Hardware capture (5 minutes, nothing else running)

`~/Applications/Palaver.app/Contents/MacOS/Palaver --capture-check 60 /tmp/palaver-check`

Play a video and talk now and then. Mic and system should both be about
60 s and there should be no write failures. Run it once with headphones and
once without.

## 2. A manual recording

1. Right-click the menu bar icon and choose Start Recording. Talk for 2
   minutes with something playing, then choose Stop Recording.
2. Check the meeting folder:
   - `mic_raw.wav` and `system.wav` are there, with no `.part` files;
   - `meta.json` has `stop_reason`;
   - `session.log` has `record_start` and `record_stop`.
3. Processing should run, and the transcript, the speakers and the notes
   should look right. Mic and system should line up: an echo of your own
   voice in the system track shows up at the same moment.

## 3. A real Teams call

Start a call and let Palaver pick it up within a few seconds (🔴 in the
menu bar). Check these:

- the levels in the menu move;
- the coach status shows up;
- the call stops after the grace period;
- the transcript, the alignment and the notes are good.

Leave the call and rejoin within 5 minutes. The two parts should become
one meeting.

## 4. Window and menus

- Left-click the icon: the window opens. Close it with ⌘W, and the Dock
  icon goes away.
- Right-click the icon: the menu has the status line, Start/Stop,
  Open Meetings ⌘M, Settings… ⌘,, Report a Problem…, Check for Updates…
  and Quit ⌘Q.
- In the window, try the Meeting, View and Help menus, Edit → Undo after a
  ⌘⌫, ⇧⌘R to start and stop a recording, and ⌘K.
- Run `palaver app restart-web`. The window should reload in place.
- Quit with ⌘Q in the window during a recording. The recording should be
  processed now (reason `by_you`), and no `webapp-serve` should be left
  running.

## 5. Notifications

- When processing finishes, a notification appears as Palaver's.
- Clicking it opens that meeting in the window.
- Settings shows the notification permission correctly.
- Start the app a second time with
  `open -n ~/Applications/Palaver.app`. You should get "Palaver is already
  running", and the first app should keep running untouched.

## 6. The update path

1. Install 0.3.14 (the last Python app) from GitHub, queue or leave a
   meeting unprocessed, and then update in the app to a test build of this
   branch.
2. Check that the swap works:
   - the new app starts and `started-ok` is written;
   - `daemon.json`, the queue and `previous-app` are handled;
   - the queued meeting is processed.
3. Then update from this build to a later test build. The same should
   happen.
4. The failure branch of 0.3.14's swap (the new app never says it started).
   Install 0.3.14 again, then block the mark the swap waits for:
   `mkdir ~/Library/Application\ Support/palaver/started-ok` (a folder where
   the file should be: nobody can write it). Update in the app. After about
   2½ minutes (2 minutes waiting for the mark, then up to 30 s for the Swift
   app):
   - 0.3.14 is back in `~/Applications` and running, and Settings → Updates
     says "Palaver … did not start; 0.3.14 is back";
   - `pgrep -fl Contents/MacOS/Palaver` shows only 0.3.14's processes: no
     Swift app is left running next to it (0.3.14's swap ends only its own
     launcher; the Swift app quits by itself within a second once its bundle
     is put aside, with a "no longer the app this process started from" line
     in daemon.log);
   - `daemon.json` and the queue are as before.

   Then `rmdir ~/Library/Application\ Support/palaver/started-ok`.

## 7. The legacy fallback

1. `touch ~/Library/Application\ Support/palaver/legacy-app`, then quit and
   open Palaver. You should get the old Python menu bar app (rumps menu,
   same icon), and recording should work.
2. A notification click should still open the meeting.
3. Remove the file and restart. You should be back on the Swift app.
4. Also try `PALAVER_LEGACY_APP=1 ~/Applications/Palaver.app/Contents/MacOS/Palaver`
   from a terminal.

## 8. Tester feedback (#19, #20, #22, #23)

1. First start (#20): in a fresh home (or with `"setup"` removed from
   `settings.json` and no meetings), open Palaver. The window should open
   with the setup assistant. Close it without Finish or Skip, quit, open
   Palaver again: it stays in the menu bar (it opens by itself only once;
   `window-offered` in Application Support). Log out and in (login item):
   it stays quiet.
2. With Palaver running and its window closed, open it again from the
   Finder, Launchpad or Spotlight. The window should come to the front,
   on the page it showed last. Minimize the window, then click the Dock
   icon: it is restored.
3. A call recording (#23): when a Teams call starts recording, a
   notification "Recording the Teams call" appears, without sound, and goes
   away by itself; a click opens the meeting. With the window open, its
   title reads "Palaver — 🔴 Recording the Teams call" and the Dock icon
   has a "REC" badge; both go away when the call ends.
4. Live coach (#19): in a call, talk alone for over 3 minutes (the mic
   only). A "Live coach" notification "3-min monologue" should appear, no
   sound, at most one every 3 minutes. A quiet invitee shows as "Someone
   invited hasn't spoken yet" (no name in a notification). The meeting's `session.log` gets a
   `coach_nudge` line (kind and time only). With "Show nudges as
   notifications" off in Settings → Live coach, none appears.
5. Voice samples (#22): on a meeting with unnamed speakers, click a voice's
   ▶. It turns into a stop button; a click, Escape, or another voice's ▶
   stops it.

## 9. palaver-server and palaver-worker (phase 3, Task 67)

Only when `palaver daemon status` says idle (no recording, nothing
transcribing). The installed Palaver must be quit first: two apps never run
at once.

1. From the checkout (development build): `make app-swift server worker`,
   then start `native/.build/release/Palaver` from a terminal. A left-click
   on the icon opens the window with your meetings.
   - `pgrep -fl palaver-server` shows one process with
     `--listen-fd … --ready-fd … --app-socket … --python … --static …/palaver/webapp/static`;
     `pgrep -fl webapp-serve` shows none.
   - `palaver app restart-web` reloads the window in place, with a new
     palaver-server pid.
2. In the installed release (after section 0): the same, with
   `Contents/MacOS/palaver-server` and `--static
   …/Contents/Resources/python/palaver/webapp/static`.
3. After a recording, `pgrep -fl palaver-worker` shows the `live`, `stream`
   and `coach` workers during the call and `process <folder> --no-notes` (or
   `run`) after it; `notes` is still `palaver-python -m palaver notes`.
   The meeting's `session.log` has `process_start` with `"swift": true`. The menu's memory line counts the worker (and a
   `cloud-transcribe` helper under it, when a cloud service is chosen).
4. The fallback: `touch ~/Library/Application\ Support/palaver/legacy-server`,
   quit and open Palaver. `app.log` says "the window's server and the workers
   run in Python …"; `pgrep -fl webapp-serve` shows the Python server and the
   next recording runs `palaver-python -m palaver process`. Remove the file
   and restart: back on palaver-server and palaver-worker. Also try
   `PALAVER_LEGACY_SERVER=1 ~/Applications/Palaver.app/Contents/MacOS/Palaver`.
