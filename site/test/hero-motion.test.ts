// Run with `npm test` (node --test, which strips the types itself).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
const light = readFileSync(new URL("../src/fabricLight.ts", import.meta.url), "utf8");
const home = readFileSync(new URL("../src/pages/Home.tsx", import.meta.url), "utf8");

function rules(selector: string): string[] {
  const out: string[] = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  for (let m = re.exec(css); m; m = re.exec(css)) {
    if (m[1].split(",").some((s) => s.trim() === selector)) out.push(m[2]);
  }
  return out;
}

test("the hero light only transitions compositor properties", () => {
  const props = [".fabric-light", ".shell:has(.home)::after"].flatMap(rules).join(";");
  const transitions = [...props.matchAll(/transition:\s*([^;]+)/g)].map((m) => m[1]);
  assert.ok(transitions.length > 0, "the hero light fades in");
  for (const t of transitions) {
    for (const part of t.split(",")) {
      const prop = part.trim().split(/\s+/)[0];
      assert.ok(["opacity", "visibility", "none"].includes(prop), `non-compositor transition: ${prop}`);
    }
  }
  assert.doesNotMatch(rules(".fabric-light").join(";"), /animation/);
});

test("reduced motion turns the light off and drops its fade", () => {
  assert.match(home, /prefers-reduced-motion: reduce/);
  const reduced = /@media \(prefers-reduced-motion: reduce\) \{\s*\.fabric-light,\s*\.shell:has\(\.home\)::after \{\s*transition: none;/;
  assert.match(css, reduced);
});

test("the sun eases toward the scroll target on rAF instead of snapping", () => {
  assert.match(light, /requestAnimationFrame\(draw\)/);
  assert.match(light, /Math\.exp\(-dt \/ \d+\)/);
  assert.doesNotMatch(light, /setInterval|setTimeout/);
  assert.doesNotMatch(light, /const p = Math\.min\(Math\.max\(scrollY/);
});

test("the hero video sits a full step below the calls to action", () => {
  assert.ok(rules(".hero .media-slot").some((r) => /margin:\s*var\(--s7\)/.test(r)));
});
