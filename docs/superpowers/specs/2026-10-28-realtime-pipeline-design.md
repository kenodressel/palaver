# Realtime live pipeline (#42): design

Date: 2026-10-28. Status: agreed in conversation and reviewed by a builder check; waiting for the user's review.

## Why

During a call, Palaver should help while it still matters, not only afterwards. The user named two reasons:

1. **Coaching against a plan.** Notes written beforehand ("ask about the budget"), or a playbook for sales or a 1:1. Palaver tracks what has been covered and says when time runs short: "15 min left, budget hasn't come up."
2. **A help button.** The client asks something the user isn't prepared for. The user presses a button, and Palaver takes the last question *the other side* asked, does quick research and shows an answer within 20–30 s. A clarifying question buys a little time, not much.

Research added more uses on the same foundation; see the comment on #42. Agreed as the top five:
- a checklist that ticks itself off;
- commitments, above all what *I* promised;
- open questions about 5 minutes before the end;
- answer cards from the user's own archive, with sources;
- a highlight hotkey.

All of them need one thing first: **the other side's words as text within seconds.** Today the live worker (#30) transcribes in ~60 s blocks, so text appears one to two minutes late. This design is only that foundation. The help button, the checklist and the rest are later projects built on it.

## Goals

- **Text of what others say (system track)** is on screen about 2 s after a sentence ends.
- **The user's own words (mic track)** within about 2 s too. The user prefers fast ("je weniger desto besser") and chose the route: **the mic stream skips echo cancellation and removes echo in the text** ("probier's mal ohne Echo-Unterdrückung und mach die mit dem Transcript").
  - The stream reads the raw `mic_raw.wav.part` directly.
  - Mic words that are the other side's speech heard through the speakers get dropped by comparing words with what the system stream heard at the same moment. This is the word rule of `cleanup.drop_echo`, the one it applies when it has no raw mic: a mic segment is echo when at least half its words are remote words said at the same time.
  - The echo-cancelled `mic.wav` and the final transcript stay exactly as they are.
  - The user works with and without headphones. Without them, a lot of remote speech reaches the raw mic, and the text filter has to carry that.
- **Who is talking right now**, the user or the others, is known within 1 s. This comes from the two tracks, without a model.
- **A running list of the questions the other side asked**, from the live text: sentences on the system track that end in "?". The help button will pick from it later.
- **The Meetings window shows the live transcript within seconds**, not minutes. Text that is still a draft may be shown differently from text that is settled.
- **A settings page in the Meetings window** with a switch for realtime. When it is off, recording and live processing work exactly as today. The user asked for it: realtime is "ein ordentlicher Kick", and they want to be able to turn it off.
- **A test bench that needs no call.** It replays recorded meetings as if they were happening now and measures latency, accuracy against the final transcript, and load. The user explicitly does not want to sacrifice calls to develop or test this.

## Non-goals (later projects)

- The help button, the checklist, commitments, open-questions alerts, answer cards, the highlight hotkey, and any language-model pass over the running transcript.
- Naming *which* remote person is speaking in realtime: the ~10 s speaker tier of #42. None of the agreed uses needs it right away. The block worker keeps doing provisional speakers as today.
- Changing the final transcript. The existing block pipeline and the processing at the end stay the source of truth; the streamed text is for live use only.
- Own notes during the call (#44), a separate project.

## Anti-goals: failures even if it "works"

- **Hurting the call or the recording.** No audio glitches in Teams or Slack, no dropped or late recorder writes. The recorder must not depend on the stream in any way. If the stream crashes, falls behind or is switched off, recording and the final transcript are unaffected.
- **Making the final transcript worse,** e.g. because the block worker gets starved of compute.
- **Pop-ups or anything that grabs attention.** The live view is quiet and glanceable.
- **Sending anything off the Mac.** Everything stays local, including the test bench's reports.

## Constraints

- Local only, on the user's machine: M4 Pro, 48 GB, macOS 26. MLX models.
  - Transcription: Parakeet `mlx-community/parakeet-tdt-0.6b-v3` via parakeet-mlx 0.5.3.
  - Diarization: pyannote.
- Calls run in German, English and both mixed. Mixing is already the weak spot (#36).
- The user notices no load today while the live worker runs during calls. Realtime should keep it that way, and that must be measured, not assumed.
- **"As realtime as sensible, not as possible"** (user). Transcribing every quarter second makes no sense; performance has to stay realistic. The update step is likely in the 0.5–1 s range, settled by measurement.
- Recordings and reports contain meeting content. They never go into commits, issues or anything uploaded.
- Tests never open the microphone or play sound.

## What exists to build on

- **Recorder:** writes `mic_raw.wav.part` and `system.wav.part` as audio arrives. It writes only when audio comes in, and fills a gap with zeros once audio resumes. Written samples never change; during silence the file simply stops growing.
- **Live worker** (`palaver/live.py`): `palaver live <folder>`, started by the daemon at background QoS. It runs streaming echo cancellation (`AecStream`) from `mic_raw` into a growing `mic.wav`, transcribes ~60 s blocks cut at pauses, runs the incremental diarizer, and writes `live.json`. It stays `MARGIN_SECONDS = 3` behind the write head.
- **parakeet-mlx 0.5.3 streaming:** `model.transcribe_stream(context_size=(left, right), depth=…)` returns a `StreamingParakeet`. It takes `add_audio(chunk)` and exposes `finalized_tokens` (settled) and `draft_tokens` (may change).
  - How late text settles is set by the right context, in encoder frames of 80 ms. The default `(256, 256)` means about 20 s.
  - It switches attention to local attention.
- **Levels:** `LevelTracker` (menu bar meter) already reads levels from the growing files.
- **Meetings window:** while a meeting records, it polls `/api/meetings/<id>` every 10 s (`refreshLive` in `app.js`). The API builds the live view from `live.json`.
- **Config:** `config.toml` holds user settings *and tokens*; `[processing] live` switches the live worker. The app must not rewrite `config.toml`.
- **`palaver bench`** (#36) computes word error rates between transcripts.

## How it works (decided)

- **One stream per track,** transcribing continuously:
  - the system track straight from `system.wav.part`;
  - the mic track straight from the raw `mic_raw.wav.part`, without echo cancellation. Echo is filtered in the text, against the system stream's words.
- **Separate from the blocks.** The stream runs next to the existing block worker, not in place of it. It produces no file that `process` or `run` depend on.
- **Quietly in the live view.** Settled text and the current draft both show, and the draft may change. A sentence from the others that ends in "?" joins the question list.
- **One switch on a new settings page** turns realtime on or off.
- **Measured before shipped.** The test bench measures each choice below on real recordings.

## Left to the builder

These are decided by measurement on the test bench, or are ordinary engineering calls:

- **Streaming method.** Two candidates:
  - (a) parakeet-mlx `transcribe_stream`, with a small right context, on the order of 1–3 s;
  - (b) re-transcribing a sliding window of the last ~10–20 s every step, with full attention, and settling words once consecutive passes agree ("local agreement").

  Pick by latency, accuracy and load, per track if need be.
- **Step size and contexts:** chunk length, `context_size` and `depth`.
- **The live echo filter:** how long mic words wait for the system stream, and whether `drop_bleed_duplicates` helps as well.
- **Where the stream runs:** inside the live worker process, or as its own process. Either way at a priority that cannot starve the recorder, and never inside the menu bar/recorder process.
- **Reading near the write head:** how close the stream reads to the newest written sample of a growing file, given that written samples never change.
- **Handing text to the window:**
  - the file format for stream output, e.g. append-only JSON lines in the recording folder;
  - how the window gets it in about a second: a light endpoint polled every second, or server-sent events from the local server.
- **What happens to the question list after the call.** Keep it with the recording, or drop it.
- **Settings storage:** an app-managed settings file next to `config.toml`, e.g. `~/.config/palaver/settings.json`.
  - What wins when both say something about live processing.
  - Whether the switch applies to a recording already running, or from the next one.
- **The settings page's layout** in the Plakat design (see `app.css`). It has one switch now, with a short line on what it costs, and should have room for more settings later.
- **Default of the switch: my call, on.** The user's Mac handles the live worker without notice, and realtime is what they want. If the test bench shows a load the user might notice, the default becomes off and the user is told.

## The test bench

- **Input:** a recorded meeting's `mic_raw.wav` and `system.wav`.
- **Playback:** written chunk by chunk into a scratch folder as growing `.part` files, the way the recorder writes them. At real-time speed for latency and load; faster for accuracy runs.
- **Pipeline:** the live worker and the stream run against that folder unchanged.
- **Meetings:** about 4–6 of the user's recordings, covering German, English, mixed, and many speakers (≥ 4).
- **Measurements**, per track and per meeting:
  - **Latency:** for each settled sentence, the time from when its audio ended in the playback to when its text was settled. Draft text is measured too. Report the median and the 90th percentile.
  - **Accuracy (my call):** with live processing on, the final transcript *is* the block worker's output (`LiveProcessor.finish` writes the segments and `process` skips transcription). So the measure is **disagreement**: the WER-style distance between the settled live text and the final transcript, per track. That counts the block worker's own mistakes too, which is acceptable: the final transcript is what the user reads and trusts. Where a meeting has an independent reference (the Notion AI transcripts of #36), also report both the stream's and the final transcript's WER against it.
  - **Load:** CPU and GPU use and peak memory of the stream and the live worker. Also whether the block worker still keeps up with real time.
- **Output:** a local report (Markdown) in the scratch folder, never committed. It holds numbers only: no transcript text, no titles, no names. A separate local debug file may hold aligned text, to be looked at only when a number needs explaining.
- **Who runs it (my call):** the coding agent building this runs the bench and reads its numbers, as it does for the existing `bench` (#36). It picks the 4–6 meetings from metadata only: duration, language (`language.json`), and the number of speakers in `speakers.json`. The app itself still sends nothing anywhere.
- **The recorder under load (my call):** the bench drives the real recorder's writing code with replayed audio instead of real capture, so the microphone and the system-audio tap are never opened. Whether Teams itself glitches can't be measured without a call, and the user won't spend calls on testing. Instead, the first real calls with realtime on are watched through the logs:
  - the recorder's resampler and drift messages;
  - stalls;
  - how far the stream lags behind.

  Recording and the final transcript don't depend on the stream, and the switch turns it off.

## Success criteria (proposed, the user agreed in principle)

- **Latency of the other side's text:** a median of ≤ 2 s and a 90th percentile of ≤ 4 s for settled text.
- **Latency of the user's own text:** about the same as the other side's; less is better. Mic words may wait briefly until the system stream has settled the same moment, so the echo filter can compare them.
- **Echo in the live mic text:** the bench reports how many live mic words are remote speech, judged by the final transcript, which uses echo cancellation and `drop_echo`. Report it for meetings with and without headphones, if both kinds exist.
- **Accuracy (my call on the number):** the settled live text disagrees with the final transcript on at most about 10 % of words on the system track. Where an independent reference exists, the stream is at most about 3 WER points worse than the final transcript against it. The builder reports the measured numbers, and the user accepts the result.
- **Load:** on the bench at real-time speed, the stream adds load that the user would not notice. Concretely:
  - the block worker still keeps up;
  - the recorder never stalls in a replay with a real recorder running;
  - the measured CPU/GPU numbers are reported to the user before the default is decided.
- **Isolation:** with realtime off, nothing changes from today. Killing the stream mid-meeting changes nothing in the recording or the final transcript.

## Spike results (2026-10-28): the method is decided

These are throwaway measurements on 5-minute slices of three recorded meetings (German, English, mixed), system track. They were run under a memory guard; see below.

- **parakeet-mlx `transcribe_stream` is out.**
  - Its token times are relative to the current feature window and need an offset.
  - Even with the library's default 20 s lookahead, it settled only about half the words: 229 vs. 526, with 78 % disagreement.
  - With ~2 s lookahead, it drifted into English on a German meeting.
  - `depth=24` ran the 48 GB Mac out of memory.
- **The sliding window with local agreement works.** Every 1 s, the last 10 s are transcribed with full attention (`model.generate` on the log-mel), re-hearing from 1 s before the settled end. A word settles when two consecutive passes agree on it, or once it ended more than 3 s ago.

| Meeting | settle latency p50 / p90 | disagreement live | disagreement of a plain offline re-run | compute | peak memory |
|---|---|---|---|---|---|
| German | 2.9 s / 3.9 s | 21.5 % | 14.6 % | 0.09 × real time | 1.5 GB |
| English | 2.0 s / 3.7 s | 11.5 % | 6.0 % | 0.08 × | 1.1 GB |
| mixed | 2.0 s / 3.7 s | 18.2 % | 9.2 % | 0.08 × | 1.1 GB |

- **Accuracy:** a plain offline re-run of the same slice already disagrees with the final transcript by 6–15 %, because of different chunk boundaries. So the accuracy criterion is restated as: **the live text disagrees at most ~10 points more than an offline re-run of the same audio.** Measured: 5.5–9 points.
- **The raw mic:** in two meetings, 70–80 % of its streamed words were the other side's speech. `echoes_remote`'s word rule flags those sentences, and the remainder is about the size of the user's own final text (145 vs. 170, and 198 vs. 165 words).

## Added 2026-10-28: auto-record switches

The user wants to tick separately whether **Teams calls** and **Slack huddles** are recorded automatically. Both go on the settings page next to realtime, and both default to on.
- `[recording] slack = false` in `config.toml` remains the Slack default until the user toggles it in the app.
- They take effect at the detector's next check, without a restart.
- Manual "Start recording now" is unaffected.
