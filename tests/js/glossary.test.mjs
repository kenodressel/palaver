import { test } from "node:test";
import assert from "node:assert/strict";
import { heardSpellings } from "../../web/logic.js";

test("a suggested term renamed to a known one brings what was heard along (#38)", () => {
  const term = { kind: "term", term: "Tiemo", variants: [] };
  assert.deepEqual(heardSpellings(term, [], "Timo"), ["Tiemo"]);
  assert.deepEqual(heardSpellings(term, [], "Tiemo"), []);  // kept as it is: a new term, nothing respelled
  const cluster = { kind: "cluster", term: "Wasti", variants: ["Wasti", "Vasti"] };
  assert.deepEqual(heardSpellings(cluster, ["Wasti", "Vasti"], "Wasti"), ["Vasti"]);
  assert.deepEqual(heardSpellings(cluster, ["Wasti", "Vasti"], "Basti"), ["Wasti", "Vasti"]);
  const variant = { kind: "variant", term: "Karel", variants: ["CAREL"] };
  assert.deepEqual(heardSpellings(variant, ["CAREL"], "Karel"), ["CAREL"]);
});
