// Generates the /recipes section's data from the example CHANGE.md recipes in
// skills/change/reference/recipes/<slug>/, so the site shows exactly the files
// the repo's own test validates against ChangeSchema:
//   src/generated/recipes.json  one entry per recipe, sorted by recipe.yml order
// Git-ignored, derived at build time (prebuild/predev), same as the other
// embed-*.mjs scripts. A file a recipe.yml lists but that is missing fails the
// build.
import { readFileSync, readdirSync, writeFileSync, mkdirSync, statSync, existsSync } from "node:fs";
import { dirname, resolve, join, extname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../..");
const recipesDir = join(repoRoot, "skills/change/reference/recipes");
const outDir = resolve(here, "../src/generated");
mkdirSync(outDir, { recursive: true });

function unquote(value) {
  const trimmed = value.trim();
  const quoted = trimmed.match(/^"(.*)"$/) || trimmed.match(/^'(.*)'$/);
  return quoted ? quoted[1] : trimmed;
}

// recipe.yml is a small, known shape: scalar title, summary, order and
// gitignore, a `files:` list of plain paths, and a `notes: |` block scalar.
// A hand-rolled parser avoids a YAML dependency for six fields, the same
// trade embed-reference.mjs makes for SKILL.md frontmatter.
function parseRecipeYaml(raw, source) {
  const meta = { files: [] };
  const lines = raw.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const key = line.match(/^([a-z_]+):\s*(.*)$/);
    if (!key) continue;
    const [, name, rest] = key;
    if (name === "files") {
      while (i + 1 < lines.length && /^\s+-\s+/.test(lines[i + 1])) {
        meta.files.push(unquote(lines[++i].replace(/^\s+-\s+/, "")));
      }
    } else if (rest.trim() === "|") {
      const block = [];
      while (i + 1 < lines.length && (/^\s+/.test(lines[i + 1]) || lines[i + 1] === "")) {
        block.push(lines[++i].replace(/^ {2}/, ""));
      }
      meta[name] = block.join("\n").trim();
    } else {
      meta[name] = unquote(rest);
    }
  }
  for (const required of ["title", "summary", "order"]) {
    if (!meta[required]) throw new Error(`${source} is missing ${required}`);
  }
  meta.order = Number(meta.order);
  return meta;
}

function langFor(path) {
  if (path.endsWith(".example")) return "bash";
  const ext = extname(path);
  if (ext === ".md") return "markdown";
  if (ext === ".yml" || ext === ".yaml") return "yaml";
  return "text";
}

function buildRecipes() {
  return readdirSync(recipesDir)
    .filter((entry) => statSync(join(recipesDir, entry)).isDirectory())
    .map((slug) => {
      const dir = join(recipesDir, slug);
      const sidecar = join(dir, "recipe.yml");
      const meta = parseRecipeYaml(readFileSync(sidecar, "utf8"), sidecar);
      const files = meta.files.map((path) => {
        const full = join(dir, path);
        if (!existsSync(full)) {
          throw new Error(`${sidecar} lists missing file ${path}`);
        }
        return { path, lang: langFor(path), text: readFileSync(full, "utf8") };
      });
      return {
        slug,
        order: meta.order,
        title: meta.title,
        summary: meta.summary,
        notes: meta.notes ?? "",
        gitignore: meta.gitignore ?? "",
        files,
      };
    })
    .sort((a, b) => a.order - b.order)
    .map(({ order, ...recipe }) => recipe);
}

try {
  const recipes = buildRecipes();
  const out = join(outDir, "recipes.json");
  writeFileSync(out, JSON.stringify(recipes, null, 2));
  console.log(`embedded recipes: ${recipes.length}`);
  console.log(`  -> ${out}`);
} catch (error) {
  console.error(`embed-recipes: ${error.message}`);
  process.exit(1);
}
