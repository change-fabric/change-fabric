// Run with `npm test` (node --test, which strips the types itself).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolveManifest, validateManifest } from "../scripts/embed-media.mjs";

const readJson = (relative: string) => JSON.parse(readFileSync(new URL(relative, import.meta.url), "utf8"));

const video = () => ({
  kind: "video",
  title: "Clip",
  src: "a1b2c3d4e5f6.mp4",
  poster: "0f1e2d3c4b5a.jpg",
  vtt: "9a8b7c6d5e4f.vtt",
  words: null,
  duration_ms: 45000,
  width: 1280,
  height: 720,
  bytes: 6123456,
  alt: "A clip",
  transcript: "Words.",
});
const manifest = (slots: Record<string, unknown>) => ({ version: 1, base: "/media/", slots });

test("the committed manifest is valid and carries the self walkthrough", () => {
  const { slots } = resolveManifest(readJson("../media/manifest.json"));
  assert.deepEqual(Object.keys(slots), ["walkthrough-self"]);
  assert.equal(slots["walkthrough-self"].kind, "video");
});

test("the verify fixture manifest is valid", () => {
  const resolved = resolveManifest(readJson("../verify/fixtures/media/manifest.json"));
  assert.deepEqual(Object.keys(resolved.slots).sort(), ["fixture-audio", "fixture-video"]);
});

test("file names resolve to /media/ URLs and nulls stay null", () => {
  const { slots } = resolveManifest(manifest({ clip: video() }));
  assert.equal(slots.clip.src, "/media/a1b2c3d4e5f6.mp4");
  assert.equal(slots.clip.poster, "/media/0f1e2d3c4b5a.jpg");
  assert.equal(slots.clip.vtt, "/media/9a8b7c6d5e4f.vtt");
  assert.equal(slots.clip.words, null);
});

test("an unknown kind fails naming the slot", () => {
  assert.throws(() => validateManifest(manifest({ clip: { ...video(), kind: "gif" } })), /slot "clip".*unknown kind/);
});

test("a missing required field fails naming the slot and field", () => {
  const { transcript: _drop, ...rest } = video();
  assert.throws(() => validateManifest(manifest({ clip: rest })), /slot "clip".*transcript/);
});

test("a file name that is not a content hash fails", () => {
  assert.throws(() => validateManifest(manifest({ clip: { ...video(), src: "final.mp4" } })), /slot "clip".*src/);
});

test("a video needs a poster and dimensions; audio does not", () => {
  assert.throws(() => validateManifest(manifest({ clip: { ...video(), poster: null } })), /poster/);
  const audio = { ...video(), kind: "audio", src: "a1b2c3d4e5f6.mp3", poster: null, width: null, height: null };
  assert.doesNotThrow(() => validateManifest(manifest({ sample: audio })));
});

test("a mobile cut resolves its files and needs its own size", () => {
  const mobile = { src: "aaaaaaaaaaaa.mp4", poster: "bbbbbbbbbbbb.jpg", vtt: "9a8b7c6d5e4f.vtt", width: 1080, height: 1350, bytes: 1 };
  const { slots } = resolveManifest(manifest({ clip: { ...video(), mobile } }));
  assert.equal(slots.clip.mobile.src, "/media/aaaaaaaaaaaa.mp4");
  assert.equal(slots.clip.mobile.poster, "/media/bbbbbbbbbbbb.jpg");
  assert.equal(slots.clip.mobile.height, 1350);
  assert.equal(resolveManifest(manifest({ clip: video() })).slots.clip.mobile, undefined);
  assert.throws(() => validateManifest(manifest({ clip: { ...video(), mobile: { ...mobile, src: "tall.mp4" } } })), /mobile\.src/);
  assert.throws(() => validateManifest(manifest({ clip: { ...video(), mobile: { ...mobile, height: 0 } } })), /mobile\.height/);
  const audio = { ...video(), kind: "audio", src: "a1b2c3d4e5f6.mp3", poster: null, width: null, height: null, mobile };
  assert.throws(() => validateManifest(manifest({ sample: audio })), /only a video/);
});

test("the committed walkthrough carries a portrait mobile cut", () => {
  const { slots } = resolveManifest(readJson("../media/manifest.json"));
  const mobile = slots["walkthrough-self"].mobile;
  assert.ok(mobile, "walkthrough-self has no mobile cut");
  assert.ok(mobile.height > mobile.width, "the mobile cut is not portrait");
});
