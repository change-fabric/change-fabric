import { test } from "node:test";
import assert from "node:assert/strict";
import { skillMediaSlot } from "../src/media-slots.ts";

test("the walkthrough skill page shows the self walkthrough slot", () => {
  assert.equal(skillMediaSlot("walkthrough"), "walkthrough-self");
  assert.equal(skillMediaSlot("narrate"), "narrate-sample");
});

test("other skills and prototype keys map to no slot", () => {
  assert.equal(skillMediaSlot("diagram"), undefined);
  assert.equal(skillMediaSlot("toString"), undefined);
});
