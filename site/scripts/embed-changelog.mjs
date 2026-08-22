// Parses the root CHANGELOG.md (the spec track's release history) into two
// derived artifacts kept in sync with the source:
//   src/generated/changelog.json  imported by the /changelog page component
//   public/changelog.xml          the RSS 2.0 feed served at /changelog.xml
// Both are git-ignored because they are derived, not authored here. Runs as
// the prebuild/predev step, after embed-spec and embed-reference. Only the
// spec track (CHANGELOG.md) feeds this: no toolkit (skills/v*) or site
// (site/v*) tag content belongs here.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");

const changelogPath = resolve(repoRoot, "CHANGELOG.md");
const raw = readFileSync(changelogPath, "utf8");

const HEADER = /^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})\s*$/;

function parseChangelog(source) {
  const lines = source.split("\n");
  const starts = [];
  lines.forEach((line, index) => {
    const match = line.match(HEADER);
    if (match) starts.push({ index, version: match[1], date: match[2] });
  });
  if (starts.length === 0) {
    throw new Error("CHANGELOG.md has no '## [X.Y.Z] - YYYY-MM-DD' section");
  }
  return starts.map((start, i) => {
    const end = i + 1 < starts.length ? starts[i + 1].index : lines.length;
    const body = lines.slice(start.index + 1, end).join("\n").trim();
    const firstSection = body.search(/^### /m);
    const lede = (firstSection === -1 ? body : body.slice(0, firstSection)).trim();
    return { version: start.version, date: start.date, lede, body };
  });
}

// releaseNotes.ts cannot be imported directly (Node cannot import a .ts file
// here), so it is read as text, matching embed-reference.mjs's precedent.
// Only its headline field is merged in, by exact version-string match.
function parseHeadlines(source) {
  const entry =
    /"(\d+\.\d+\.\d+)":\s*\{\s*version:\s*"\1",\s*date:\s*"\d{4}-\d{2}-\d{2}",\s*headline:\s*("(?:[^"\\]|\\.)*")/g;
  const headlines = new Map();
  let match;
  while ((match = entry.exec(source))) {
    headlines.set(match[1], JSON.parse(match[2]));
  }
  return headlines;
}

function xmlEscape(value) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function pubDate(date) {
  return new Date(`${date}T00:00:00Z`).toUTCString();
}

const CHANNEL_TITLE = "change fabric spec releases";
const CHANNEL_LINK = "https://www.changefabric.org/changelog";
const CHANNEL_DESCRIPTION = "Release history of the CHANGE.md frontmatter specification.";
const FEED_URL = "https://www.changefabric.org/changelog.xml";

function renderFeed(entries) {
  const items = entries
    .map((entry) => {
      const headlineHtml = entry.headline
        ? `<p><strong>${entry.headline}</strong></p>\n`
        : "";
      const bodyHtml = marked.parse(entry.body, { async: false });
      const description = xmlEscape(headlineHtml + bodyHtml);
      const date = pubDate(entry.date);
      return [
        "    <item>",
        `      <title>Spec ${entry.version}</title>`,
        `      <link>${CHANNEL_LINK}#v${entry.version}</link>`,
        `      <guid isPermaLink="false">changefabric-spec-${entry.version}</guid>`,
        `      <pubDate>${date}</pubDate>`,
        `      <description>${description}</description>`,
        "    </item>",
      ].join("\n");
    })
    .join("\n");

  const lastBuildDate = pubDate(entries[0].date);

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">',
    "  <channel>",
    `    <title>${CHANNEL_TITLE}</title>`,
    `    <link>${CHANNEL_LINK}</link>`,
    `    <description>${CHANNEL_DESCRIPTION}</description>`,
    "    <language>en</language>",
    `    <lastBuildDate>${lastBuildDate}</lastBuildDate>`,
    `    <atom:link href="${FEED_URL}" rel="self" type="application/rss+xml"/>`,
    items,
    "  </channel>",
    "</rss>",
    "",
  ].join("\n");
}

const entries = parseChangelog(raw);

const releaseNotesPath = resolve(repoRoot, "site/src/releaseNotes.ts");
const releaseNotesSource = readFileSync(releaseNotesPath, "utf8");
const headlines = parseHeadlines(releaseNotesSource);

const withHeadlines = entries.map((entry) => ({
  version: entry.version,
  date: entry.date,
  headline: headlines.get(entry.version) ?? null,
  lede: entry.lede,
  body: entry.body,
}));

// Drift guard: the currently published spec version must have its own
// CHANGELOG entry, so a released-spec-without-a-changelog-entry fails the
// local build rather than only release-spec.yml at tag time.
const specPath = resolve(repoRoot, "skills/change/reference/CHANGE-frontmatter-spec.md");
const specMarkdown = readFileSync(specPath, "utf8");
const specVersionMatch = specMarkdown.match(/^Schema version:\s*(\S+)/m);
if (!specVersionMatch) {
  throw new Error("spec is missing a 'Schema version:' line");
}
const publishedVersion = specVersionMatch[1];
if (!entries.some((entry) => entry.version === publishedVersion)) {
  throw new Error(
    `CHANGELOG.md has no entry for the currently published spec version ${publishedVersion}`,
  );
}

const jsonOut = resolve(here, "../src/generated/changelog.json");
mkdirSync(dirname(jsonOut), { recursive: true });
writeFileSync(jsonOut, JSON.stringify(withHeadlines, null, 2));

const xmlOut = resolve(here, "../public/changelog.xml");
mkdirSync(dirname(xmlOut), { recursive: true });
writeFileSync(xmlOut, renderFeed(withHeadlines));

console.log(`embedded changelog: ${withHeadlines.length} versions`);
console.log(`  -> ${jsonOut}`);
console.log(`  -> ${xmlOut}`);
