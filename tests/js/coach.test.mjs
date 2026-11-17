// The live coach on the meeting page (#41, #42): who talks, the nudge, the best next question.
import { test } from "node:test";
import assert from "node:assert/strict";

import { liveCoachFor, speakingText, questionsNote } from "../../web/logic.js";

const ID = "2026-10-30T10-00-00";
const coach = { meeting: ID, talk: { speaking: "me" }, text: "You 62 % of the last 10 min", nudge: null };

test("liveCoachFor shows the coach only on the meeting being recorded", () => {
  assert.equal(liveCoachFor(coach, { id: ID, status: "recording" }), coach);
  assert.equal(liveCoachFor(coach, { id: ID, status: "processing", live: { until: 3 } }), coach);
  assert.equal(liveCoachFor(coach, { id: "2026-10-30T09-00-00", status: "recording" }), null);
  assert.equal(liveCoachFor(coach, { id: ID, status: "ready" }), null);
  assert.equal(liveCoachFor(null, { id: ID, status: "recording" }), null);
  assert.equal(liveCoachFor(coach, null), null);
});

test("speakingText says who talks now", () => {
  assert.equal(speakingText({ speaking: "me" }), "You're talking");
  assert.equal(speakingText({ speaking: "others" }), "Others are talking");
  assert.equal(speakingText({ speaking: "both" }), "Both talking");
  assert.equal(speakingText({ speaking: null }), "Quiet");
  assert.equal(speakingText(null), null);
});

test("questionsNote says which model answered and that it keeps to the transcript", () => {
  assert.equal(questionsNote({ engine: "Gemma 4 12B on this Mac", questions: [{}] }),
    "Gemma 4 12B on this Mac · from what was said and your prep only");
  assert.equal(questionsNote({ engine: "Anthropic API", questions: [] }),
    "Anthropic API found nothing in the transcript to ask about yet.");
});

import { questionButton } from "../../web/logic.js";

test("questionButton names the model, waits for it, and says why it is off", () => {
  const local = { ready: true, reason: null, label: "Best next question (Gemma, on this Mac)", local: true, warning: null };
  assert.deepEqual(questionButton(local, null), { label: "Best next question (Gemma, on this Mac)", disabled: false, reason: null });
  assert.deepEqual(questionButton(local, { loading: true }), { label: "Thinking…", disabled: true, reason: null });
  const off = { ready: false, reason: "No model yet: choose one for Best next question in Settings → Language model.",
    label: "Best next question", local: false, warning: null };
  assert.deepEqual(questionButton(off, null), { label: "Best next question", disabled: true, reason: off.reason });
  assert.deepEqual(questionButton(null, null), { label: "Best next question", disabled: true, reason: null });
});

import { answerButton, answerHeading, answerNote } from "../../web/logic.js";

test("Best answer waits with Best next question and is off without a model", () => {
  const info = { ready: true, label: "Best next question (Gemma, on this Mac)" };
  assert.deepEqual(answerButton(info, null), { label: "Best answer", disabled: false });
  assert.deepEqual(answerButton(info, { kind: "answer", loading: true }), { label: "Thinking…", disabled: true });
  assert.deepEqual(answerButton(info, { kind: "questions", loading: true }), { label: "Best answer", disabled: true });
  assert.deepEqual(answerButton({ ready: false }, null), { label: "Best answer", disabled: true });
  assert.deepEqual(answerButton(null, null), { label: "Best answer", disabled: true });
  assert.deepEqual(questionButton(info, { kind: "answer", loading: true }),
    { label: "Best next question (Gemma, on this Mac)", disabled: true, reason: null });
});

test("answerHeading says what is answered, who asked and when", () => {
  assert.equal(answerHeading({ to: "When can you start?", asked_by: "Carla", time: "12:34" }), "To Carla at 12:34: When can you start?");
  assert.equal(answerHeading({ to: "Pricing", asked_by: "", time: "" }), "Pricing");
  assert.equal(answerHeading({ to: "", asked_by: "Carla" }), "");
});

test("answerNote names the model, or that nothing called for an answer", () => {
  assert.equal(answerNote({ engine: "Gemma 4 12B on this Mac", answer: { answer: "In March." } }),
    "Gemma 4 12B on this Mac · may use general knowledge, never made-up facts · check before you say it");
  assert.equal(answerNote({ engine: "Anthropic API", answer: { answer: "" } }),
    "Anthropic API found no open question to answer in the last minutes.");
});
