import recipesJson from "./generated/recipes.json";

// Embedded at build time by scripts/embed-recipes.mjs, straight from
// skills/change/reference/recipes/<slug>/, the same files the repo's own test
// checks against ChangeSchema, so a recipe shown here is one that validates.

export interface RecipeFile {
  path: string;
  lang: string;
  text: string;
}

export interface Recipe {
  slug: string;
  title: string;
  summary: string;
  notes: string;
  gitignore: string;
  files: RecipeFile[];
}

export const RECIPES: Recipe[] = recipesJson;

export function findRecipe(slug: string): Recipe | undefined {
  return RECIPES.find((recipe) => recipe.slug === slug);
}

export function recipePath(slug: string): string {
  return `/recipes/${slug}`;
}

// A recipe that ships a .env.qa.example expects its QA credentials exported
// into cf:change's own environment before the run.
export function needsQaEnv(recipe: Recipe): boolean {
  return recipe.files.some((file) => file.path === ".env.qa.example");
}
