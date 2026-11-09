// Run with `npm test` (node --test, which strips the types itself).
import { test } from "node:test";
import assert from "node:assert/strict";
import { activeWordIndex, formatDuration, highlightLoop } from "../src/media.ts";

test("durations format as m:ss", () => {
  assert.equal(formatDuration(0), "0:00");
  assert.equal(formatDuration(2000), "0:02");
  assert.equal(formatDuration(45000), "0:45");
  assert.equal(formatDuration(61400), "1:01");
  assert.equal(formatDuration(599600), "10:00");
});

const words = [
  { text: "A", start_ms: 0, end_ms: 300 },
  { text: "silent", start_ms: 300, end_ms: 900 },
  { text: "fixture", start_ms: 1000, end_ms: 1600 },
];

test("the active word is the one whose span holds the time", () => {
  assert.equal(activeWordIndex(words, 0), 0);
  assert.equal(activeWordIndex(words, 299), 0);
  assert.equal(activeWordIndex(words, 300), 1);
  assert.equal(activeWordIndex(words, 1599), 2);
});

test("no word is active in a gap, after the end, or with no words", () => {
  assert.equal(activeWordIndex(words, 950), -1);
  assert.equal(activeWordIndex(words, 1600), -1);
  assert.equal(activeWordIndex([], 10), -1);
  assert.equal(activeWordIndex(words, -5), -1);
});

function fakeFrames() {
  const pending = new Map<number, () => void>();
  let next = 1;
  return {
    pending,
    raf: (callback: () => void) => {
      pending.set(next, callback);
      return next++;
    },
    cancel: (id: number) => {
      pending.delete(id);
    },
    flush() {
      const due = [...pending.entries()];
      pending.clear();
      for (const [, callback] of due) callback();
    },
  };
}

test("the highlight loop keeps one pending frame however many timeupdates fire", () => {
  const frames = fakeFrames();
  const playing = true;
  let updates = 0;
  const loop = highlightLoop({
    playing: () => playing,
    update: () => updates++,
    clear: () => {},
    raf: frames.raf,
    cancel: frames.cancel,
  });
  loop.start();
  for (let i = 0; i < 5; i++) loop.onTimeUpdate();
  assert.equal(frames.pending.size, 1);
  frames.flush();
  loop.onTimeUpdate();
  assert.equal(frames.pending.size, 1);
  loop.start();
  assert.equal(frames.pending.size, 1);
  assert.equal(updates, 7);
});

test("after stop no frame fires and the highlight stays cleared", () => {
  const frames = fakeFrames();
  let playing = true;
  let active = 0;
  const loop = highlightLoop({
    playing: () => playing,
    update: () => (active = 3),
    clear: () => (active = -1),
    raf: frames.raf,
    cancel: frames.cancel,
  });
  loop.start();
  loop.onTimeUpdate();
  playing = false;
  loop.stop();
  assert.equal(frames.pending.size, 0);
  assert.equal(active, -1);
  loop.onTimeUpdate();
  frames.flush();
  assert.equal(active, -1);
});
