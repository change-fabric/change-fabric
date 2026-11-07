export const MERGE_MODES = ["local-only", "merge-ready", "admin-bypass", "yolo"] as const;
export const COMMAND_MODES = [...MERGE_MODES, "away", "active"] as const;

// Mirrors scripts/merge_mode_slug.rb so "LOCAL-ONLY", "Local only", and
// "Merge ready (default)" reach the slug CfHostHook::MODE matches.
export function modeSlug<T extends string>(raw: string | undefined, known: readonly T[]): T | undefined {
  const slug = (raw ?? "")
    .trim()
    .replace(/\s*\(.*\)\s*$/, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
  return known.find((mode) => mode === slug);
}
