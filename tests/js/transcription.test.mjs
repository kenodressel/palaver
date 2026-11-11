// Settings → Transcription (#54): the choices, what goes where, the price,
// and transcription uploads in the shared access log (web/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  transcriberOptions, transcriptionSendsText, priceText, transcriptionTestText, monthText, accessLogText,
} from "../../web/logic.js";

function tr(extra = {}) {
  return {
    feature: { id: "transcription", label: "Transcription", sends: "the call's system track", choice: "local" },
    providers: [
      { id: "assemblyai", label: "AssemblyAI", sends_to: "AssemblyAI, on its servers in the region you choose",
        model: "universal-3-5-pro", ready: true, problem: null, key: "required", key_set: true, usd_per_hour: 0.28,
        region: "eu" },
      { id: "openai-transcribe", label: "OpenAI-compatible transcription", sends_to: "the endpoint you set",
        model: "whisper-1", ready: false, problem: "Save the endpoint", key: "optional", key_set: false,
        usd_per_hour: null },
    ],
    month: { seconds: 0, usd: 0, meetings: 0 },
    log: [],
    labels: { assemblyai: "AssemblyAI" },
    ...extra,
  };
}

test("transcriberOptions: this Mac first, then each service; one not set up can't be picked", () => {
  const options = transcriberOptions(tr());
  assert.deepEqual(options.map((o) => o.value), ["local", "assemblyai", "openai-transcribe"]);
  assert.equal(options[0].label, "On this Mac · Parakeet");
  assert.equal(options[1].label, "AssemblyAI · universal-3-5-pro");
  assert.equal(options[2].disabled, true);
  assert.match(options[2].label, /save the endpoint first/);
});

test("transcriptionSendsText says who gets what, and that the mic stays here", () => {
  assert.equal(transcriptionSendsText(tr()), "Both tracks are transcribed on this Mac.");
  const chosen = tr({ feature: { ...tr().feature, choice: "assemblyai" } });
  assert.equal(transcriptionSendsText(chosen),
    "Sends the call's system track to AssemblyAI, on its servers in the region you choose.");
  const broken = tr({ feature: { ...tr().feature, choice: "openai-transcribe" } });
  assert.equal(transcriptionSendsText(broken),
    "OpenAI-compatible transcription is not set up (save the endpoint): meetings are transcribed on this Mac until it is.");
});

test("priceText: the list price per hour, or that the endpoint decides", () => {
  assert.equal(priceText(tr().providers[0]), "About $0.28 per hour of audio sent (list price).");
  assert.equal(priceText(tr().providers[1]), "The price is what your endpoint charges.");
});

test("transcriptionTestText: how long it took and what an hour costs", () => {
  assert.equal(transcriptionTestText({ seconds: 3.4, usd_per_hour: 0.1, model: "stt-async-v5" }),
    "Answered in 3.4 s · about $0.10 per hour of audio");
  assert.equal(transcriptionTestText({ seconds: 1, usd_per_hour: null, model: "whisper-1" }), "Answered in 1 s");
});

test("monthText: minutes sent this month and their estimated cost", () => {
  assert.equal(monthText({ seconds: 0, usd: 0, meetings: 0 }), "Nothing was sent for transcription this month.");
  assert.equal(monthText({ seconds: 5400, usd: 0.42, meetings: 2 }),
    "This month: 2 meetings, 1.5 h of audio sent, about $0.42.");
  assert.equal(monthText({ seconds: 600, usd: 0.05, meetings: 1 }),
    "This month: 1 meeting, 10 min of audio sent, about $0.05.");
});

test("accessLogText shows an upload as audio, with the service's name", () => {
  const lm = { providers: [], labels: { assemblyai: "AssemblyAI" } };
  assert.equal(accessLogText({ feature: "transcription", meetings: ["2026-10-29T10-00-00"], chars: 0,
    audio_seconds: 1234.5, track: "system", provider: "assemblyai", host: "api.eu.assemblyai.com",
    model: "universal-3-5-pro", ok: true, seconds: 41.2 }, lm),
  "Transcription · 1 meeting · 21 min of the system track → AssemblyAI (universal-3-5-pro, api.eu.assemblyai.com) · 41.2 s");
  assert.equal(accessLogText({ feature: "test", meetings: [], chars: 0, audio_seconds: 2, provider: "assemblyai",
    host: "api.eu.assemblyai.com", model: "universal-3-5-pro", ok: false, error: "HTTP 401", seconds: 0.3 }, lm),
  "Test · 2 s of audio → AssemblyAI (universal-3-5-pro, api.eu.assemblyai.com) · failed: HTTP 401");
});

test("transcribedText: a meeting says which service heard it, and when this Mac stepped in", async () => {
  const { transcribedText } = await import("../../web/logic.js");
  assert.equal(transcribedText(null), null);
  assert.equal(transcribedText({ engine: "local" }), null);
  assert.equal(transcribedText({ engine: "live" }), null);
  assert.equal(transcribedText({ engine: "assemblyai", label: "AssemblyAI", sent_seconds: 1800, usd: 0.14 }),
    "System track transcribed by AssemblyAI (30 min sent, about $0.14)");
  assert.equal(transcribedText({ engine: "openai-transcribe", label: "OpenAI-compatible transcription",
    sent_seconds: 60, usd: null }), "System track transcribed by OpenAI-compatible transcription (1 min sent)");
  assert.equal(transcribedText({ engine: "local", fallback_from: "soniox", fallback_label: "Soniox", error: "HTTP 503" }),
    "Transcribed on this Mac: Soniox failed (HTTP 503)");
});
