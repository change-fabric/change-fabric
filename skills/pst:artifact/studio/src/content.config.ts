import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";
import { THEME_KEYS } from "./lib/theme";

// One artifact = one MDX file at src/content/plans/<id>.mdx, where <id> is the
// stable, collision-checked short base62 id that lives forever in the URL
// (/p/<id>/<cosmetic-slug>). The filename IS the id, so routing never depends on
// the human-readable slug. Author the body bespoke per plan using the kit
// components - composition, art direction, and diagrams should fit the prompt,
// not a fixed template.
const plans = defineCollection({
  loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/plans" }),
  schema: z.object({
    title: z.string(),
    // Cosmetic, human-readable, free to change. Never used for routing.
    // NOT named `slug` on purpose: Astro's glob loader would hijack a `slug`
    // field as the entry id, breaking the stable-id-in-filename contract.
    permalink: z.string(),
    eyebrow: z.string().optional(),
    subtitle: z.string().optional(),
    summary: z.string().optional(),
    // Art direction. Pick a base theme, optionally override the accent.
    theme: z.enum(THEME_KEYS).default("editorial"),
    accent: z.string().optional(),
    tags: z.array(z.string()).default([]),
    status: z.enum(["draft", "shared", "final"]).default("draft"),
    // Where this plan came from (a markdown file, a conversation, a ticket).
    sourcePath: z.string().optional(),
    createdAt: z.coerce.date().optional(),
    updatedAt: z.coerce.date().optional(),
  }),
});

export const collections = { plans };
