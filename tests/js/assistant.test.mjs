// The live assistant on the Live view (#15): its buttons, its model line and how its answers read.
import { test } from "node:test";
import assert from "node:assert/strict";

import { assistantModelText, assistantButton, catchupTitle, nextStepsTitle, nextStepText, quoteText, assistantEmptyText,
  ASSISTANT_KINDS, ASSISTANT_MINUTES } from "../../web/logic.js";

const ready = { ready: true, reason: null, model: "Claude Opus 5.5, cloud", local: false, warning: null };

test("the model line names the model, or says why there is none", () => {
  assert.equal(assistantModelText(ready), "Claude Opus 5.5, cloud · runs only when you ask · not part of the notes");
  assert.equal(assistantModelText({ ready: false, reason: "No model yet: choose one for Notes in Settings → Language model." }),
    "No model yet: choose one for Notes in Settings → Language model.");
  assert.equal(assistantModelText(null), "");
});

test("the buttons wait for a model and for the ask that runs", () => {
  assert.deepEqual(assistantButton("catchup", ready, null), { label: "Catch me up", disabled: false });
  assert.deepEqual(assistantButton("next_steps", ready, "catchup"), { label: "Next steps so far", disabled: true });
  assert.deepEqual(assistantButton("ask", ready, "ask"), { label: "Thinking…", disabled: true });
  assert.deepEqual(assistantButton("ask", { ready: false }, null), { label: "Ask", disabled: true });
  assert.deepEqual(assistantButton("ask", null, null), { label: "Ask", disabled: true });
  assert.deepEqual(ASSISTANT_KINDS, ["catchup", "next_steps", "ask"]);
  assert.deepEqual(ASSISTANT_MINUTES, [5, 10, 15]);
});

test("the answers read as the call's times, owners and quotes", () => {
  assert.equal(catchupTitle({ minutes: 10, until: 754.2 }), "Last 10 minutes · up to 12:34");
  assert.equal(nextStepsTitle({ until: 3725 }), "Next steps so far · up to 1:02:05");
  assert.equal(nextStepText({ owner: "Carla", task: "Send the offer by Friday" }), "Carla: Send the offer by Friday");
  assert.equal(nextStepText({ owner: "", task: "Check the budget" }), "Check the budget");
  assert.equal(quoteText({ time: "12:34", speaker: "Valerie", text: "Das Budget sind 40.000 Euro." }),
    "12:34 · Valerie: “Das Budget sind 40.000 Euro.”");
  assert.equal(quoteText({ time: "", speaker: "", text: "40.000" }), "“40.000”");
  assert.equal(assistantEmptyText("next_steps"), "No next steps or decisions yet.");
});
