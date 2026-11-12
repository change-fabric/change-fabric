// Run with `npm test` (node --test, which strips the types itself).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { activeWordIndex, captionText, formatDuration, highlightLoop, NARROW_QUERY, pickVariant, type MediaEntry } from "../src/media.ts";

const slotSource = readFileSync(new URL("../src/components/MediaSlot.tsx", import.meta.url), "utf8");

test("the caption drops a leading title so it never restates the runtime", () => {
  const title = "change fabric in 45 seconds";
  assert.equal(
    captionText({ title, alt: `${title}: a narrated walkthrough of the toolkit` }),
    "A narrated walkthrough of the toolkit",
  );
  assert.equal(captionText({ title, alt: "A walkthrough with no title prefix" }), "A walkthrough with no title prefix");
  assert.equal(captionText({ title, alt: `${title}: ` }), `${title}: `);
});

// iOS Safari plays media only from inside the tap. The 0.13.1 slot swapped in
// a fresh <video> with <source> children and called play() from an effect;
// on an iPhone it sat at 00:00 / 00:00. Guard the shape of the fix: one
// player mounted up front, its src set and play() called in the click handler.
test("play() runs in the click handler on the mounted player, never in an effect", () => {
  const start = slotSource.slice(slotSource.indexOf("const start = () => {"));
  const body = start.slice(0, start.indexOf("\n  };"));
  assert.match(body, /pickVariant\(entry, isNarrow\(\)\)/, "the cut is chosen inside the tap");
  assert.match(body, /media\.src = chosen\.src;/);
  assert.match(body, /media\.play\(\)/);
  assert.ok(body.indexOf("media.src") < body.indexOf("media.play()"), "src must be set before play()");
  assert.match(slotSource, /onClick=\{start\}/);
  for (const effect of slotSource.split("useEffect(").slice(1)) {
    assert.doesNotMatch(effect.slice(0, effect.indexOf("}, [")), /\.play\(\)/, "play() inside a useEffect");
  }
  assert.doesNotMatch(slotSource, /<source\s+src=/, "a <source> child instead of the src set on tap");
  assert.match(slotSource, /preload="none"/);
  assert.match(slotSource, /playsInline/);
});

const slotEntry = (): MediaEntry => ({
  kind: "video",
  title: "Clip",
  src: "/media/wide.mp4",
  poster: "/media/wide.jpg",
  vtt: "/media/c.vtt",
  words: null,
  duration_ms: 44000,
  width: 1920,
  height: 1080,
  bytes: 1,
  alt: "A clip",
  transcript: "Words.",
  mobile: { src: "/media/tall.mp4", poster: "/media/tall.jpg", vtt: "/media/c.vtt", width: 1080, height: 1350, bytes: 1 },
});

test("a narrow viewport plays the mobile cut, a wide one the slot's own", () => {
  assert.deepEqual(pickVariant(slotEntry(), true), {
    src: "/media/tall.mp4", poster: "/media/tall.jpg", vtt: "/media/c.vtt", width: 1080, height: 1350,
  });
  assert.equal(pickVariant(slotEntry(), false).src, "/media/wide.mp4");
  const { mobile: _drop, ...single } = slotEntry();
  assert.equal(pickVariant(single, true).src, "/media/wide.mp4");
  assert.equal(pickVariant({ ...single, mobile: null }, true).src, "/media/wide.mp4");
});

test("the poster swap and the tap-time choice share one media query", () => {
  assert.match(slotSource, /<source media=\{NARROW_QUERY\}/);
  assert.match(slotSource, /matchMedia\(NARROW_QUERY\)/);
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.ok(css.includes(`@media ${NARROW_QUERY}`), `styles.css has no @media ${NARROW_QUERY} block`);
});

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
