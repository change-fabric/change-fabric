// Generates the /reference section's data from the repo's actual skills and
// hooks, so the site can never drift from what's really installed:
//   src/generated/reference/skills.json  one entry per skills/<name>/SKILL.md
//   src/generated/reference/hooks.json   one entry per script wired in
//                                        install.rb's Installer::HOOKS map
// Both are git-ignored, derived at build time (prebuild/predev), same as
// embed-spec.mjs's src/generated/spec.md.
import { readFileSync, readdirSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const outDir = resolve(here, "../src/generated/reference");
mkdirSync(outDir, { recursive: true });

function splitFrontmatter(raw) {
  const match = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (!match) return { frontmatter: "", body: raw };
  return { frontmatter: match[1], body: match[2] };
}

// The frontmatter here is a small, known shape (name, description, and an
// optional auto.basenames list) - a hand-rolled parser avoids taking on a
// full YAML dependency in a build script for three fields.
function parseSkillFrontmatter(frontmatter) {
  const nameMatch = frontmatter.match(/^name:\s*(.+)$/m);
  const descMatch = frontmatter.match(/^description:\s*(.+)$/m);
  const basenamesMatch = frontmatter.match(/^\s*basenames:\s*\[(.*)\]/m);
  return {
    name: nameMatch ? nameMatch[1].trim() : null,
    description: descMatch ? descMatch[1].trim() : "",
    autoBasenames: basenamesMatch
      ? basenamesMatch[1]
          .split(",")
          .map((entry) => entry.trim())
          .filter(Boolean)
      : [],
  };
}

function buildSkills() {
  const skillsDir = join(repoRoot, "skills");
  const entries = readdirSync(skillsDir).filter((entry) => {
    const path = join(skillsDir, entry);
    return statSync(path).isDirectory();
  });

  return entries
    .map((dirName) => {
      const skillPath = join(skillsDir, dirName, "SKILL.md");
      let raw;
      try {
        raw = readFileSync(skillPath, "utf8");
      } catch {
        return null;
      }
      const { frontmatter, body } = splitFrontmatter(raw);
      const meta = parseSkillFrontmatter(frontmatter);
      if (!meta.name) return null;
      return {
        id: dirName,
        name: meta.name,
        description: meta.description,
        autoBasenames: meta.autoBasenames,
        body: body.trim(),
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.name.localeCompare(b.name));
}

// Installer::HOOKS in install.rb is the single source of truth for which
// script runs on which Claude Code event. Parsed as text (not required as
// Ruby) since this is a Node build script; the hash's shape is stable and
// small enough that a targeted regex is more honest here than pulling in a
// Ruby subprocess for one lookup.
function parseHooksManifest() {
  const installRb = readFileSync(join(repoRoot, "install.rb"), "utf8");
  const hooksBlockMatch = installRb.match(/HOOKS\s*=\s*\{([\s\S]*?)\}\.freeze/);
  if (!hooksBlockMatch) {
    throw new Error("could not find Installer::HOOKS in install.rb");
  }
  const block = hooksBlockMatch[1];
  const eventLine = /'([A-Za-z]+)'\s*=>\s*%w\[([^\]]*)\]/g;

  const scriptToEvents = new Map();
  let match;
  while ((match = eventLine.exec(block))) {
    const [, event, scriptsRaw] = match;
    for (const script of scriptsRaw.trim().split(/\s+/)) {
      if (!scriptToEvents.has(script)) scriptToEvents.set(script, []);
      scriptToEvents.get(script).push(event);
    }
  }
  return scriptToEvents;
}

// Every hook script opens with a `#!/usr/bin/env ruby`, a frozen_string_literal
// magic comment, a block of `require`/`require_relative` lines, then a comment
// paragraph describing what the hook does before the first `class`. That
// paragraph is the one place these scripts already document themselves in
// prose; this pulls it out rather than inventing a second description.
function extractLeadingComment(rubySource) {
  const lines = rubySource.split("\n");
  let i = 0;
  while (i < lines.length && (lines[i].startsWith("#!") || lines[i].startsWith("# frozen") || /^require/.test(lines[i]) || lines[i].trim() === "")) {
    i++;
  }
  const commentLines = [];
  while (i < lines.length && lines[i].startsWith("#")) {
    commentLines.push(lines[i].replace(/^#\s?/, ""));
    i++;
  }
  return commentLines.join(" ").trim();
}

function buildHooks() {
  const scriptToEvents = parseHooksManifest();
  const scriptsDir = join(repoRoot, "scripts");

  return [...scriptToEvents.entries()]
    .map(([script, events]) => {
      const scriptPath = join(scriptsDir, script);
      let source;
      try {
        source = readFileSync(scriptPath, "utf8");
      } catch {
        return { id: script, script, events, description: "" };
      }
      return {
        id: script,
        script,
        events,
        description: extractLeadingComment(source),
      };
    })
    .sort((a, b) => a.script.localeCompare(b.script));
}

const skills = buildSkills();
const hooks = buildHooks();

writeFileSync(join(outDir, "skills.json"), JSON.stringify(skills, null, 2));
writeFileSync(join(outDir, "hooks.json"), JSON.stringify(hooks, null, 2));

console.log(`embedded reference data: ${skills.length} skills, ${hooks.length} hooks`);
console.log(`  -> ${join(outDir, "skills.json")}`);
console.log(`  -> ${join(outDir, "hooks.json")}`);
