// What an action did is said once, in the toast (#27): never also as a grey line on the page, which stayed there long
// after the toast was gone (a cut, a glossary change). The page's grey lines are questions with buttons only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const APP = readFileSync(new URL("../../web/app.js", import.meta.url), "utf8");

test("the page says what an action did only in the toast", () => {
  const notices = [...APP.matchAll(/class: "inline-notice([^"]*)"/g)].map((m) => m[1].trim());
  // A question that asks something and has its buttons (forget a remembered series?) is no message.
  assert.deepEqual(notices, ["shared-ask"]);
  assert.doesNotMatch(APP, /state\.(notice|cutNotice)\b/);
});
