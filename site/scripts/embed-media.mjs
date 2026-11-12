// Validates the committed media manifest (site/media/manifest.json, written
// only by scripts/site_media_publish.rb) and writes src/generated/media.json
// with every file name resolved to its /media/ URL, for the MediaSlot
// component. Runs as the prebuild/predev step after embed-changelog.
//
// The manifest names content-addressed files that live in the site bucket,
// never in git, so a fresh clone builds with no media bytes at all: the slot
// degrades on its own. An absent manifest writes an empty slot map.
//
// A build with VITE_MEDIA_FIXTURE=1 (only verify/media.mjs makes one) also
// merges the fixture manifest under verify/fixtures/media/, whose bytes the
// verify server serves. A production build never reads it.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const KINDS = ["video", "audio"];
const HASH_NAME = /^[0-9a-f]{12}\.(mp4|mp3|vtt|json|jpg|webp)$/;
const TEXT_FIELDS = ["title", "alt", "transcript"];
const COUNT_FIELDS = ["duration_ms", "bytes"];

function fail(slot, message) {
  throw new Error(`media manifest slot "${slot}": ${message}`);
}

function checkName(slot, field, value, { optional = false } = {}) {
  if (value === null && optional) return;
  if (typeof value !== "string" || !HASH_NAME.test(value)) {
    fail(slot, `${field} must be a 12-hex content-hash file name, got ${JSON.stringify(value)}`);
  }
}

function checkSlot(slot, entry) {
  if (entry === null || typeof entry !== "object") fail(slot, "entry must be an object");
  if (!KINDS.includes(entry.kind)) fail(slot, `unknown kind ${JSON.stringify(entry.kind)}`);
  for (const field of TEXT_FIELDS) {
    if (typeof entry[field] !== "string" || entry[field].trim() === "") {
      fail(slot, `missing required field ${field}`);
    }
  }
  for (const field of COUNT_FIELDS) {
    if (!Number.isInteger(entry[field]) || entry[field] <= 0) {
      fail(slot, `missing required field ${field}`);
    }
  }
  checkName(slot, "src", entry.src);
  checkName(slot, "vtt", entry.vtt);
  const video = entry.kind === "video";
  checkName(slot, "poster", entry.poster, { optional: !video });
  checkName(slot, "words", entry.words, { optional: true });
  for (const field of ["width", "height"]) {
    const value = entry[field];
    const ok = video ? Number.isInteger(value) && value > 0 : value === null || Number.isInteger(value);
    if (!ok) fail(slot, `missing required field ${field}`);
  }
  if (entry.mobile !== undefined && entry.mobile !== null) checkMobile(slot, entry);
}

// The optional portrait cut of a video: its own files and size, sharing the
// slot's title, transcript, and duration.
function checkMobile(slot, entry) {
  const mobile = entry.mobile;
  if (entry.kind !== "video") fail(slot, "only a video takes a mobile cut");
  if (typeof mobile !== "object" || Array.isArray(mobile)) fail(slot, "mobile must be an object");
  for (const field of ["src", "poster", "vtt"]) checkName(slot, `mobile.${field}`, mobile[field]);
  for (const field of ["width", "height", "bytes"]) {
    if (!Number.isInteger(mobile[field]) || mobile[field] <= 0) fail(slot, `missing required field mobile.${field}`);
  }
}

// Throws naming the slot on any shape error; returns the manifest unchanged.
export function validateManifest(manifest) {
  if (manifest === null || typeof manifest !== "object") {
    throw new Error("media manifest must be a JSON object");
  }
  if (manifest.version !== 1) throw new Error(`media manifest version must be 1, got ${manifest.version}`);
  if (manifest.base !== "/media/") throw new Error(`media manifest base must be "/media/", got ${manifest.base}`);
  if (manifest.slots === null || typeof manifest.slots !== "object" || Array.isArray(manifest.slots)) {
    throw new Error("media manifest slots must be an object");
  }
  for (const [slot, entry] of Object.entries(manifest.slots)) checkSlot(slot, entry);
  return manifest;
}

// The page-facing shape: same fields, file names turned into URLs.
export function resolveManifest(manifest) {
  validateManifest(manifest);
  const url = (name) => (name === null || name === undefined ? null : `${manifest.base}${name}`);
  const slots = {};
  for (const [slot, entry] of Object.entries(manifest.slots)) {
    slots[slot] = {
      ...entry,
      src: url(entry.src),
      poster: url(entry.poster),
      vtt: url(entry.vtt),
      words: url(entry.words),
      ...(entry.mobile
        ? { mobile: { ...entry.mobile, src: url(entry.mobile.src), poster: url(entry.mobile.poster), vtt: url(entry.mobile.vtt) } }
        : {}),
    };
  }
  return { slots };
}

function readManifest(path) {
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf8"));
}

function main() {
  const here = dirname(fileURLToPath(import.meta.url));
  const site = resolve(here, "..");
  const manifest = readManifest(resolve(site, "media/manifest.json"));
  const resolved = manifest === null ? { slots: {} } : resolveManifest(manifest);

  if (process.env.VITE_MEDIA_FIXTURE === "1") {
    const fixture = resolveManifest(readManifest(resolve(site, "verify/fixtures/media/manifest.json")));
    Object.assign(resolved.slots, fixture.slots);
  }

  const out = resolve(site, "src/generated/media.json");
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, `${JSON.stringify(resolved, null, 2)}\n`);
  console.log(`embed-media: ${Object.keys(resolved.slots).length} slot(s) -> src/generated/media.json`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
