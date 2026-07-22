import { marked } from "marked";
import specMarkdown from "./generated/spec.md?raw";

// The canonical CHANGE.md frontmatter spec, embedded at build time (see
// scripts/embed-spec.mjs), plus the version history the /spec pages render.

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
  // The raw markdown for a version. Only the current version is embedded here;
  // a future version adds its own entry (and its archived markdown) as one more
  // row, which is all the versions index and this map need to grow.
  markdown: string;
}

export const VERSIONS: SpecVersion[] = [
  { version: CURRENT_VERSION, date: "2026-07-21", status: "current", markdown: specMarkdown },
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
