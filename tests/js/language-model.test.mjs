// Settings → Language model: the choices, what goes where, the access log
// (palaver/webapp/static/logic.js).
import { test } from "node:test";
import assert from "node:assert/strict";

import { engineOptions, sendsText, accessLogText, testText, tokensText } from "../../palaver/webapp/static/logic.js";

function lm(extra = {}) {
  return {
    features: [
      { id: "notes", label: "Notes", sends: "the meeting's transcript", choice: "local", default: "local" },
      { id: "projects", label: "Projects", sends: "titles and summaries", choice: "anthropic", default: "local" },
    ],
    providers: [
      { id: "anthropic", label: "Anthropic API", sends_to: "Anthropic", model: "claude-opus-5-5", ready: true,
        problem: null, key: "required", key_set: true, context_tokens: 1000000 },
      { id: "openai", label: "OpenAI-compatible", sends_to: "the endpoint you set", model: "", ready: false,
        problem: "Set the model name", key: "optional", key_set: false, context_tokens: 128000 },
    ],
    local: { model: "repo/gemma", models: [{ repo: "repo/gemma", label: "Gemma 4 12B", memory_gb: 14 }] },
    log: [],
    ...extra,
  };
}

test("engineOptions: local first, then each provider; one not set up can't be picked", () => {
  const options = engineOptions(lm());
  assert.deepEqual(options.map((o) => o.value), ["local", "anthropic", "openai"]);
  assert.equal(options[0].label, "On this Mac · Gemma 4 12B");
  assert.equal(options[1].label, "Anthropic API · claude-opus-5-5");
  assert.equal(options[1].disabled, false);
  assert.equal(options[2].disabled, true);
  assert.match(options[2].label, /set the model name first/);
});

test("engineOptions names a local model it doesn't know by its repo", () => {
  const options = engineOptions(lm({ local: { model: "someone/else", models: [] } }));
  assert.equal(options[0].label, "On this Mac · someone/else");
});

test("sendsText says plainly who gets what", () => {
  const data = lm();
  assert.equal(sendsText(data, data.features[0]), "Stays on this Mac.");
  assert.equal(sendsText(data, data.features[1]), "Sends titles and summaries to Anthropic.");
});

test("sendsText warns when the chosen provider is no longer set up: nothing runs instead", () => {
  const data = lm();
  data.providers[0] = { ...data.providers[0], ready: false, problem: "Add the API key", key_set: false };
  assert.equal(sendsText(data, data.features[1]),
    "Anthropic API is not set up (add the API key): nothing is sent, and projects wait until it is or you choose another model.");
});

test("accessLogText: what, how much, where to, how it went", () => {
  assert.equal(accessLogText({ feature: "notes", meetings: ["2026-10-27T16-03-07"], chars: 12345, provider: "anthropic",
    host: "api.anthropic.com", model: "claude-opus-5-5", ok: true, seconds: 12.3 }, lm()),
  "Notes · 1 meeting · 12,345 characters → Anthropic API (claude-opus-5-5) · 12.3 s");
  assert.equal(accessLogText({ feature: "projects", meetings: ["a", "b"], chars: 900, provider: "openai",
    host: "acme.openai.azure.com", model: "gpt-x", ok: false, error: "HTTP 503", seconds: 3 }, lm()),
  "Projects · 2 meetings · 900 characters → OpenAI-compatible (gpt-x, acme.openai.azure.com) · failed: HTTP 503");
  assert.equal(accessLogText({ feature: "test", meetings: [], chars: 80, provider: "anthropic", host: "h",
    model: "m", ok: true, seconds: 0.8 }, lm()), "Test · 80 characters → Anthropic API (m) · 0.8 s");
});

test("testText shows the answer and the time", () => {
  assert.equal(testText({ answer: "Hello there", seconds: 1.2 }), "“Hello there” in 1.2 s");
});

test("tokensText reads like a size", () => {
  assert.equal(tokensText(1000000), "1M tokens");
  assert.equal(tokensText(131072), "131k tokens");
  assert.equal(tokensText(128000), "128k tokens");
  assert.equal(tokensText(900), "900 tokens");
});
