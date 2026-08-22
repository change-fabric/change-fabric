import { marked } from "marked";
import specMarkdown from "./generated/spec.md?raw";
import archivedV0_1_0 from "./archive/0.1.0.md?raw";
import archivedV0_2_0 from "./archive/0.2.0.md?raw";
import archivedV0_3_0 from "./archive/0.3.0.md?raw";
import archivedV0_3_1 from "./archive/0.3.1.md?raw";
import archivedV0_4_0 from "./archive/0.4.0.md?raw";
import archivedV0_5_0 from "./archive/0.5.0.md?raw";
import archivedV0_6_0 from "./archive/0.6.0.md?raw";
import archivedV0_8_0 from "./archive/0.8.0.md?raw";
import archivedV0_9_0 from "./archive/0.9.0.md?raw";

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
// (e.g. via `git show spec/v<old>:skills/change/reference/
// CHANGE-frontmatter-spec.md`, or `change-schema/v<old>` for 0.3.1 and
// earlier, which predate the current tag prefix) into
// src/archive/<old-version>.md, import it below with `?raw`, and add it to
// VERSIONS as one more `superseded` row.

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
  { version: CURRENT_VERSION, date: "2026-08-22", status: "current", markdown: specMarkdown },
  { version: "0.9.0", date: "2026-08-22", status: "superseded", markdown: archivedV0_9_0 },
  { version: "0.8.0", date: "2026-08-21", status: "superseded", markdown: archivedV0_8_0 },
  { version: "0.6.0", date: "2026-08-02", status: "superseded", markdown: archivedV0_6_0 },
  { version: "0.5.0", date: "2026-08-01", status: "superseded", markdown: archivedV0_5_0 },
  { version: "0.4.0", date: "2026-07-27", status: "superseded", markdown: archivedV0_4_0 },
  { version: "0.3.1", date: "2026-07-22", status: "superseded", markdown: archivedV0_3_1 },
  { version: "0.3.0", date: "2026-07-22", status: "superseded", markdown: archivedV0_3_0 },
  { version: "0.2.0", date: "2026-07-22", status: "superseded", markdown: archivedV0_2_0 },
  { version: "0.1.0", date: "2026-07-21", status: "superseded", markdown: archivedV0_1_0 },
];

export function findVersion(version: string): SpecVersion | undefined {
  return VERSIONS.find((entry) => entry.version === version);
}

function escapeAttribute(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
}

// Wide rendered-markdown content scrolls inside its own box (see .scroll-region
// in styles.css), and a scroll container has to be reachable by keyboard or a
// keyboard-only user can never scroll it (axe-core scrollable-region-focusable).
// So every table and code sample marked emits gets tabindex plus a name taken
// from the heading it sits under.
//
// A table is wrapped rather than labelled in place: the role would replace the
// element's own table semantics, and the wrapper, not the table, is what
// scrolls. A <pre> carries no semantics worth keeping, so it is labelled
// directly and stays its own scroll box, background and padding intact.
//
// The only input here is marked's own output, whose <table> and <pre> shape is
// fixed, and markdown can nest neither inside the other.
function focusableScrollRegions(html: string): string {
  const taken = new Set<string>();
  let heading = "";

  function name(kind: string): string {
    const base = heading ? `${heading} ${kind}` : kind;
    let candidate = base;
    let ordinal = 2;
    while (taken.has(candidate)) {
      candidate = `${base} ${ordinal}`;
      ordinal += 1;
    }
    taken.add(candidate);
    return escapeAttribute(candidate);
  }

  return html.replace(
    /<h[1-6][^>]*>([\s\S]*?)<\/h[1-6]>|<table>[\s\S]*?<\/table>|<pre>[\s\S]*?<\/pre>/g,
    (match: string, headingHtml?: string) => {
      if (headingHtml !== undefined) {
        heading = headingHtml.replace(/<[^>]+>/g, "").trim();
        return match;
      }
      if (match.startsWith("<table")) {
        const label = name("table");
        return `<div class="scroll-region" tabindex="0" role="region" aria-label="${label}">${match}</div>`;
      }
      const label = name("code sample");
      return match.replace(
        "<pre>",
        `<pre class="scroll-region" tabindex="0" role="group" aria-label="${label}">`,
      );
    },
  );
}

export function specHtml(markdown: string): string {
  return focusableScrollRegions(marked.parse(markdown, { async: false }));
}

export function specPath(version: string): string {
  return `/spec/${version}`;
}

// The raw plain-markdown counterpart, a real static file served as text, not a
// client route.
export function rawPath(version: string): string {
  return `/spec/${version}.md`;
}
