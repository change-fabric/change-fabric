import { marked } from "marked";
import specMarkdown from "./generated/spec.md?raw";
import archivedV0_1_0 from "./archive/0.1.0.md?raw";
import archivedV0_2_0 from "./archive/0.2.0.md?raw";

// The canonical CHANGE.md frontmatter spec, embedded at build time (see
// scripts/embed-spec.mjs), plus the version history the /spec pages render.
//
// Only the CURRENT version is derived (src/generated/spec.md, regenerated
// every build from skills/change/reference/CHANGE-frontmatter-spec.md).
// Every superseded version is a frozen snapshot checked into src/archive/,
// since the live source only ever holds the current text. A version bump
// that does not also freeze a src/archive/<old-version>.md entry here
// silently drops that version from /spec and 404s its own HTML page (its
// public/spec/<version>.md raw file survives untouched across deploys
// since deploy.sh never deletes old objects, but nothing in VERSIONS
// points to it anymore): copy the previous CHANGE-frontmatter-spec.md
// (e.g. via `git show change-schema/v<old>:skills/change/reference/
// CHANGE-frontmatter-spec.md`) into src/archive/<old-version>.md, import
// it below with `?raw`, and add it to VERSIONS as one more `superseded` row.

export const SPEC_MARKDOWN = specMarkdown;

function parseVersion(markdown: string): string {
  const match = markdown.match(/^Schema version:\s*(\S+)/m);
  return match ? match[1] : "unknown";
}

export const CURRENT_VERSION = parseVersion(specMarkdown);

export interface SpecVersion {
  version: string;
  date: string;
  status: "current" | "superseded";
  // The raw markdown for this version: specMarkdown for the current row,
  // a frozen src/archive/<version>.md import for every superseded row.
  markdown: string;
}

export const VERSIONS: SpecVersion[] = [
  { version: CURRENT_VERSION, date: "2026-07-22", status: "current", markdown: specMarkdown },
  { version: "0.2.0", date: "2026-07-22", status: "superseded", markdown: archivedV0_2_0 },
  { version: "0.1.0", date: "2026-07-21", status: "superseded", markdown: archivedV0_1_0 },
];

export function findVersion(version: string): SpecVersion | undefined {
  return VERSIONS.find((entry) => entry.version === version);
}

export function specHtml(markdown: string): string {
  return marked.parse(markdown, { async: false });
}

export function specPath(version: string): string {
  return `/spec/${version}`;
}

// The raw plain-markdown counterpart, a real static file served as text, not a
// client route.
export function rawPath(version: string): string {
  return `/spec/${version}.md`;
}
