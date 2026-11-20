// Ask your meetings (#42): how its answers read, their citations and sources, and what the page keeps.
import { test } from "node:test";
import assert from "node:assert/strict";

import { keepAsked, askAnswerParts, askSourcePlace, askSourceQuote, askModelText, askBasisText, askLeftOutText,
  askEmptyText, askSinceOptions, ASK_KEEP, placeOf, hashOf } from "../../web/logic.js";

const line = { n: 2, meeting: "2026-10-28T10-00-00", title: "Weekly with Northwind", start: "2026-10-28T10:00:00+01:00",
  kind: "line", time: 754.2, speaker: "Lena", text: "Die Laufzeit bleibt bei 24 Monaten." };
const decision = { n: 5, meeting: "2026-11-02T09-00-00", title: "Contract review", start: "2026-11-02T09:00:00+01:00",
  kind: "decision", time: null, speaker: "", text: "Term stays at 24 months" };

test("the answer's citations are the sources it has, the rest stays text", () => {
  assert.deepEqual(askAnswerParts("The term stays at 24 months [2][5], said again later [9].", [line, decision]), [
    { text: "The term stays at 24 months " }, { n: 2, source: line }, { n: 5, source: decision },
    { text: ", said again later [9]." },
  ]);
  assert.deepEqual(askAnswerParts("No passage says so.", []), [{ text: "No passage says so." }]);
  assert.deepEqual(askAnswerParts("[2]", [line]), [{ n: 2, source: line }]);
  assert.deepEqual(askAnswerParts("", [line]), []);
});

test("a source says where it is and what it says", () => {
  assert.equal(askSourcePlace(line), "12:34");
  assert.equal(askSourcePlace({ ...line, time: 3725 }), "1:02:05");
  assert.equal(askSourcePlace(decision), "Decision");
  assert.equal(askSourcePlace({ ...decision, kind: "step" }), "Next step");
  assert.equal(askSourcePlace({ ...decision, kind: "my_notes" }), "My notes");
  assert.equal(askSourcePlace({ ...decision, kind: "my_notes", time: 61 }), "01:01");
  assert.equal(askSourceQuote(line), "Lena: “Die Laufzeit bleibt bei 24 Monaten.”");
  assert.equal(askSourceQuote(decision), "“Term stays at 24 months”");
  assert.equal(askSourceQuote({ ...decision, kind: "step", speaker: "Jonas" }), "Jonas: “Term stays at 24 months”");
});

test("the model line names the model and what stays on this Mac, or says why there is none", () => {
  assert.equal(askModelText({ ready: true, model: "Claude Opus 5.5, cloud", local: false }),
    "Claude Opus 5.5, cloud · runs only when you ask · meetings kept on this Mac stay out");
  assert.equal(askModelText({ ready: true, model: "Gemma, on this Mac", local: true }),
    "Gemma, on this Mac · runs only when you ask · nothing leaves this Mac");
  assert.equal(askModelText({ ready: false, reason: "No model yet: choose one for Notes in Settings → Language model." }),
    "No model yet: choose one for Notes in Settings → Language model.");
  assert.equal(askModelText(null), "");
});

test("under an answer: what it rests on, and the meetings a cloud model was not given", () => {
  assert.equal(askBasisText({ passages: 14, meetings: 6, engine: "Anthropic API" }), "From 14 passages in 6 meetings · Anthropic API");
  assert.equal(askBasisText({ passages: 1, meetings: 1, engine: null }), "From 1 passage in 1 meeting");
  assert.equal(askLeftOutText({ left_out: 0 }), null);
  assert.equal(askLeftOutText({ left_out: 1 }), "1 meeting kept on this Mac matches too: it was left out, a cloud model never sees it.");
  assert.equal(askLeftOutText({ left_out: 3 }),
    "3 meetings kept on this Mac match too: they were left out, a cloud model never sees them.");
  assert.equal(askEmptyText({ left_out: 0 }), "Nothing in your meetings matches this question. Try other words, or fewer filters.");
  assert.equal(askEmptyText({ left_out: 2 }), "Only meetings kept on this Mac match. Ask on this Mac to include them.");
});

test("the session keeps the newest answers, a question asked again once", () => {
  const a = (question, at) => ({ question, asked_at: at });
  let kept = [];
  for (let i = 0; i < 7; i++) kept = keepAsked(kept, a(`Question ${i}`, `t${i}`));
  assert.equal(kept.length, ASK_KEEP);
  assert.deepEqual(kept.map((x) => x.question), ["Question 6", "Question 5", "Question 4", "Question 3", "Question 2"]);
  kept = keepAsked(kept, a(" question 4 ", "t9"));
  assert.deepEqual(kept.map((x) => x.asked_at), ["t9", "t6", "t5", "t3", "t2"]);
  assert.deepEqual(keepAsked(null, a("Q", "t")), [a("Q", "t")]);
});

test("the since filter offers the last 30 days, 3 months and year before today", () => {
  assert.deepEqual(askSinceOptions(new Date(2026, 10, 20, 15, 30)), [
    { value: "", label: "Any time" }, { value: "2026-10-21", label: "Last 30 days" },
    { value: "2026-08-21", label: "Last 3 months" }, { value: "2025-11-20", label: "Last 12 months" },
  ]);
});

test("the page has its own address", () => {
  assert.deepEqual(placeOf("#/ask"), { view: "ask" });
  assert.equal(hashOf({ view: "ask" }), "#/ask");
});
