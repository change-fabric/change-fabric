// Copies the CHANGE.md frontmatter spec into the site at build time, as the
// derived artifacts kept in sync with their sources:
//   src/generated/spec.md    imported and rendered as the styled HTML spec page
//   public/spec/<version>.md  the raw plain-markdown copy served for agents/tools
// The version segment comes from each spec's own "Schema version" line, so a
// raw file's URL always matches the version it contains. All are git-ignored
// because they are derived, not authored here. Runs as the prebuild/predev step.
//
// A raw file is written for every version the site knows about, not just the
// current one: the current spec from its canonical source, and every superseded
// version from the frozen src/archive/<version>.md the /spec pages already
// render. Writing only the current one was a slow leak. It relied on each
// version having been deployed while it was current, since deploy.sh never
// deletes old objects, and any version that missed that window had no raw file
// at all. 0.10.0 was the one that surfaced it: its HTML page rendered from the
// archive while /spec/0.10.0.md fell through to the SPA's index.html, which
// answers a request for markdown with a page of HTML. Rebuilding all of them
// every time makes the raw files a function of the tree rather than of deploy
// history.
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const rawDir = resolve(here, "../public/spec");

function schemaVersion(markdown, label) {
  const match = markdown.match(/^Schema version:\s*(\S+)/m);
  if (!match) {
    throw new Error(`${label} is missing a 'Schema version:' line`);
  }
  return match[1];
}

function writeRaw(version, markdown) {
  const raw = resolve(rawDir, `${version}.md`);
  writeFileSync(raw, markdown);
  return raw;
}

const source = resolve(here, "../../skills/change/reference/CHANGE-frontmatter-spec.md");
const markdown = readFileSync(source, "utf8");
const version = schemaVersion(markdown, "the spec");

const generated = resolve(here, "../src/generated/spec.md");
mkdirSync(dirname(generated), { recursive: true });
writeFileSync(generated, markdown);
mkdirSync(rawDir, { recursive: true });

const written = [ generated, writeRaw(version, markdown) ];

// An archive file whose contents disagree with its filename would publish the
// wrong text at a permanent url, so it fails the build rather than deploying.
const archiveDir = resolve(here, "../src/archive");
for (const file of readdirSync(archiveDir).filter((name) => name.endsWith(".md")).sort()) {
  const archived = readFileSync(resolve(archiveDir, file), "utf8");
  const archivedVersion = schemaVersion(archived, `src/archive/${file}`);
  const expected = file.replace(/\.md$/, "");
  if (archivedVersion !== expected) {
    throw new Error(`src/archive/${file} declares Schema version ${archivedVersion}`);
  }
  written.push(writeRaw(archivedVersion, archived));
}

console.log(`embedded spec v${version}, plus ${written.length - 2} archived version(s)`);
for (const path of written) {
  console.log(`  -> ${path}`);
}
