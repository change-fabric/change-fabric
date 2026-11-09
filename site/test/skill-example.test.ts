// Run with `npm test` (node --test, which strips the types itself).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { exampleMeta } from "../scripts/skill-example.mjs";

const diagram = readFileSync(new URL("../../skills/diagram/example.svg", import.meta.url), "utf8");

test("the cf:diagram example carries its title and size to the page", () => {
  assert.deepEqual(exampleMeta(diagram, "diagram"), {
    src: "/reference-examples/diagram.svg",
    alt: "How cf:diagram makes a diagram",
    width: 872,
    height: 384,
  });
});

test("the cf:diagram example themes itself for dark mode", () => {
  assert.match(diagram, /@media \(prefers-color-scheme: dark\)/);
});

test("an example without a title is rejected rather than shown without alt text", () => {
  assert.throws(
    () => exampleMeta('<svg width="10" height="10"></svg>', "nameless"),
    /skills\/nameless\/example\.svg/,
  );
});
