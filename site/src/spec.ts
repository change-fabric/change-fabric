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
import archivedV0_10_0 from "./archive/0.10.0.md?raw";
import archivedV0_11_0 from "./archive/0.11.0.md?raw";
import archivedV0_12_0 from "./archive/0.12.0.md?raw";
import archivedV0_13_0 from "./archive/0.13.0.md?raw";
import archivedV0_14_0 from "./archive/0.14.0.md?raw";
import archivedV0_15_0 from "./archive/0.15.0.md?raw";
import archivedV0_15_1 from "./archive/0.15.1.md?raw";
import archivedV0_16_0 from "./archive/0.16.0.md?raw";
import archivedV0_17_0 from "./archive/0.17.0.md?raw";
import archivedV0_18_0 from "./archive/0.18.0.md?raw";
import archivedV0_19_0 from "./archive/0.19.0.md?raw";
import archivedV0_20_0 from "./archive/0.20.0.md?raw";
import archivedV0_21_0 from "./archive/0.21.0.md?raw";
import archivedV0_22_0 from "./archive/0.22.0.md?raw";
import archivedV0_23_0 from "./archive/0.23.0.md?raw";
import archivedV0_24_0 from "./archive/0.24.0.md?raw";
import archivedV0_25_0 from "./archive/0.25.0.md?raw";
import archivedV0_26_0 from "./archive/0.26.0.md?raw";
import archivedV0_27_0 from "./archive/0.27.0.md?raw";
import archivedV0_28_0 from "./archive/0.28.0.md?raw";
import archivedV0_29_0 from "./archive/0.29.0.md?raw";
import archivedV0_30_0 from "./archive/0.30.0.md?raw";
import archivedV0_32_0 from "./archive/0.32.0.md?raw";
import archivedV0_33_0 from "./archive/0.33.0.md?raw";
import archivedV0_35_0 from "./archive/0.35.0.md?raw";
import archivedV0_34_0 from "./archive/0.34.0.md?raw";
import archivedV0_31_0 from "./archive/0.31.0.md?raw";

// The canonical CHANGE.md frontmatter spec, embedded at build time (see
// scripts/embed-spec.mjs), plus the version history the /spec pages render.
//
// Only the CURRENT version is derived (src/generated/spec.md, regenerated
// every build from skills/change/reference/CHANGE-frontmatter-spec.md).
// Every superseded version is a frozen snapshot checked into src/archive/,
// since the live source only ever holds the current text. A version bump
// that does not also freeze a src/archive/<old-version>.md entry here
// silently drops that version from /spec and 404s its own HTML page, and
// drops its public/spec/<version>.md raw file too, since embed-spec.mjs
// writes one per archive entry: copy the previous CHANGE-frontmatter-spec.md
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
  { version: CURRENT_VERSION, date: "2026-11-25", status: "current", markdown: specMarkdown },
  { version: "0.35.0", date: "2026-11-25", status: "superseded", markdown: archivedV0_35_0 },
  { version: "0.34.0", date: "2026-11-25", status: "superseded", markdown: archivedV0_34_0 },
  { version: "0.33.0", date: "2026-11-24", status: "superseded", markdown: archivedV0_33_0 },
  { version: "0.32.0", date: "2026-11-22", status: "superseded", markdown: archivedV0_32_0 },
  { version: "0.31.0", date: "2026-11-20", status: "superseded", markdown: archivedV0_31_0 },
  { version: "0.30.0", date: "2026-11-20", status: "superseded", markdown: archivedV0_30_0 },
  { version: "0.29.0", date: "2026-11-20", status: "superseded", markdown: archivedV0_29_0 },
  { version: "0.28.0", date: "2026-11-20", status: "superseded", markdown: archivedV0_28_0 },
  { version: "0.27.0", date: "2026-11-19", status: "superseded", markdown: archivedV0_27_0 },
  { version: "0.26.0", date: "2026-11-19", status: "superseded", markdown: archivedV0_26_0 },
  { version: "0.25.0", date: "2026-11-19", status: "superseded", markdown: archivedV0_25_0 },
  { version: "0.24.0", date: "2026-11-18", status: "superseded", markdown: archivedV0_24_0 },
  { version: "0.23.0", date: "2026-11-18", status: "superseded", markdown: archivedV0_23_0 },
  { version: "0.22.0", date: "2026-11-18", status: "superseded", markdown: archivedV0_22_0 },
  { version: "0.21.0", date: "2026-11-18", status: "superseded", markdown: archivedV0_21_0 },
  { version: "0.20.0", date: "2026-11-17", status: "superseded", markdown: archivedV0_20_0 },
  { version: "0.19.0", date: "2026-11-16", status: "superseded", markdown: archivedV0_19_0 },
  { version: "0.18.0", date: "2026-11-13", status: "superseded", markdown: archivedV0_18_0 },
  { version: "0.17.0", date: "2026-11-10", status: "superseded", markdown: archivedV0_17_0 },
  { version: "0.16.0", date: "2026-11-10", status: "superseded", markdown: archivedV0_16_0 },
  { version: "0.15.1", date: "2026-11-08", status: "superseded", markdown: archivedV0_15_1 },
  { version: "0.15.0", date: "2026-11-07", status: "superseded", markdown: archivedV0_15_0 },
  { version: "0.14.0", date: "2026-11-05", status: "superseded", markdown: archivedV0_14_0 },
  { version: "0.13.0", date: "2026-10-29", status: "superseded", markdown: archivedV0_13_0 },
  { version: "0.12.0", date: "2026-09-17", status: "superseded", markdown: archivedV0_12_0 },
  { version: "0.11.0", date: "2026-09-15", status: "superseded", markdown: archivedV0_11_0 },
  { version: "0.10.0", date: "2026-08-22", status: "superseded", markdown: archivedV0_10_0 },
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

// A link that leaves the site opens in a new tab, as every hand-written
// external link on the site does. Only marked's own <a href="..."> output
// reaches this, so the attribute order is fixed.
function externalLinksInNewTab(html: string): string {
  return html.replace(
    /<a href="(https?:\/\/[^"]*)"/g,
    '<a href="$1" target="_blank" rel="noopener noreferrer"',
  );
}

export function specHtml(markdown: string): string {
  return externalLinksInNewTab(focusableScrollRegions(marked.parse(markdown, { async: false })));
}

export function specPath(version: string): string {
  return `/spec/${version}`;
}

// The raw plain-markdown counterpart, a real static file served as text, not a
// client route.
export function rawPath(version: string): string {
  return `/spec/${version}.md`;
}
