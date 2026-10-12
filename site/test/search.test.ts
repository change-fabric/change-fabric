// Run with `npm test` (node --test, which strips the types itself).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createSearch, stem } from "../src/search.ts";

const entries = [
  { name: "cf:status", description: "Report this session's progress on a fixed interval." },
  { name: "cf:resolve-threads", description: "Resolve review threads on a pull request." },
  { name: "away_guard.rb", description: "Denies an AskUserQuestion call made while away mode is on." },
  { name: "cf:screenshot", description: "Captures before/after screenshots of every route." },
];
const score = createSearch(entries);
const find = (query: string) =>
  entries
    .map((entry) => ({ name: entry.name, score: score(query, entry) }))
    .filter((hit) => hit.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((hit) => hit.name);

test("punctuation splits words", () => {
  assert.equal(find("cf sta")[0], "cf:status");
  assert.equal(find("Cf sta")[0], "cf:status");
  assert.deepEqual(find("away guard"), ["away_guard.rb"]);
});

test("a run-together query finds the squeezed name", () => {
  assert.equal(find("cfstatus")[0], "cf:status");
  assert.equal(find("awayguard")[0], "away_guard.rb");
});

test("stems meet their base word", () => {
  assert.equal(stem("threads"), stem("thread"));
  assert.equal(stem("reviewing"), stem("review"));
  assert.ok(find("reviewing").includes("cf:resolve-threads"));
  assert.ok(find("screenshotting").includes("cf:screenshot"));
});

test("one typo is forgiven", () => {
  assert.equal(find("staus")[0], "cf:status");
  assert.equal(find("screnshot")[0], "cf:screenshot");
  assert.equal(find("thraeds")[0], "cf:resolve-threads");
});

test("every word must match, and short words never fuzz", () => {
  assert.deepEqual(find("status zebra"), []);
  assert.deepEqual(find("qz"), []);
});

test("a name hit outranks a description hit", () => {
  const more = [...entries, { name: "cf:other", description: "Shows the status of things." }];
  const rank = createSearch(more);
  const top = more.sort((a, b) => rank("status", b) - rank("status", a))[0];
  assert.equal(top.name, "cf:status");
});
