// Copies the canonical CHANGE.md frontmatter spec into the site at build time,
// as two derived artifacts kept in sync with the source:
//   src/generated/spec.md    imported and rendered as the styled HTML spec page
//   public/spec/<version>.md  the raw plain-markdown copy served for agents/tools
// The version segment comes from the spec's own "Schema version" line, so the
// raw file's URL always matches the version it contains. Both are git-ignored
// because they are derived, not authored here. Runs as the prebuild/predev step.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, "../../skills/change/reference/CHANGE-frontmatter-spec.md");
const markdown = readFileSync(source, "utf8");

const versionMatch = markdown.match(/^Schema version:\s*(\S+)/m);
if (!versionMatch) {
  throw new Error("spec is missing a 'Schema version:' line");
}
const version = versionMatch[1];

const generated = resolve(here, "../src/generated/spec.md");
mkdirSync(dirname(generated), { recursive: true });
writeFileSync(generated, markdown);

const raw = resolve(here, `../public/spec/${version}.md`);
mkdirSync(dirname(raw), { recursive: true });
writeFileSync(raw, markdown);

console.log(`embedded spec v${version}`);
console.log(`  -> ${generated}`);
console.log(`  -> ${raw}`);
