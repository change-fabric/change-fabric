/**
 * Art direction presets. Each plan picks a base theme (and may override the
 * accent) so artifacts feel bespoke to the prompt instead of looking like the
 * same boilerplate template every time. Themes set CSS custom properties on the
 * plan wrapper; the kit components consume those vars. All themes are
 * light-leaning and editorial - generous negative space, real type pairings.
 */

export interface Theme {
  label: string;
  /** Page background. */
  bg: string;
  /** Raised surfaces (cards, frames). */
  surface: string;
  /** Subtle fills (table headers, wells). */
  subtle: string;
  /** Primary text. */
  text: string;
  /** Secondary text. */
  muted: string;
  /** Hairlines and borders. */
  border: string;
  /** Brand accent (links, pills, hero wash). */
  accent: string;
  /** Text on top of the accent. */
  accentText: string;
  /** font-family stack for display/headings. */
  displayFont: string;
  /** font-family stack for body copy. */
  bodyFont: string;
  /** font-family stack for code/mono. */
  monoFont: string;
  /** Default hero treatment when a plan doesn't specify one. */
  hero: "gradient" | "wash" | "rule";
}

const INTER = '"Inter Variable", system-ui, -apple-system, sans-serif';
const SORA = '"Sora Variable", system-ui, sans-serif';
const GROTESK = '"Space Grotesk Variable", system-ui, sans-serif';
const FRAUNCES = '"Fraunces Variable", Georgia, serif';
const NEWSREADER = '"Newsreader Variable", Georgia, serif';
const MONO =
  '"JetBrains Mono Variable", ui-monospace, SFMono-Regular, monospace';

export const THEMES = {
  /** Warm paper, serif display - long-form, narrative plans and briefs. */
  editorial: {
    label: "Editorial",
    bg: "#faf7f2",
    surface: "#ffffff",
    subtle: "#f3ede3",
    text: "#1f1b16",
    muted: "#6b6155",
    border: "#e7ded0",
    accent: "#b4541f",
    accentText: "#ffffff",
    displayFont: FRAUNCES,
    bodyFont: NEWSREADER,
    monoFont: MONO,
    hero: "wash",
  },
  /** Cool, geometric - architecture, migrations, systems work. */
  technical: {
    label: "Technical",
    bg: "#f7f9fc",
    surface: "#ffffff",
    subtle: "#eef2f8",
    text: "#10172a",
    muted: "#5a6478",
    border: "#dde4ef",
    accent: "#3a4cd6",
    accentText: "#ffffff",
    displayFont: GROTESK,
    bodyFont: INTER,
    monoFont: MONO,
    hero: "gradient",
  },
  /** Near-monochrome, maximal whitespace - exec summaries, crisp decisions. */
  minimal: {
    label: "Minimal",
    bg: "#fbfbfa",
    surface: "#ffffff",
    subtle: "#f2f2f0",
    text: "#161614",
    muted: "#6d6d68",
    border: "#e6e6e2",
    accent: "#161614",
    accentText: "#ffffff",
    displayFont: INTER,
    bodyFont: INTER,
    monoFont: MONO,
    hero: "rule",
  },
  /** Soft tint, friendly geometric - prototypes, product proposals. */
  vivid: {
    label: "Vivid",
    bg: "#f6f5ff",
    surface: "#ffffff",
    subtle: "#eeebff",
    text: "#181433",
    muted: "#5d5680",
    border: "#e2ddf6",
    accent: "#6d3bf5",
    accentText: "#ffffff",
    displayFont: SORA,
    bodyFont: INTER,
    monoFont: MONO,
    hero: "gradient",
  },
  /** Ivory, deep green, classic serif - formal proposals, stakeholder docs. */
  classic: {
    label: "Classic",
    bg: "#fbfaf6",
    surface: "#ffffff",
    subtle: "#f1f0e8",
    text: "#1c2019",
    muted: "#5f6657",
    border: "#e4e3d6",
    accent: "#1f5d3f",
    accentText: "#ffffff",
    displayFont: FRAUNCES,
    bodyFont: INTER,
    monoFont: MONO,
    hero: "wash",
  },
} satisfies Record<string, Theme>;

/**
 * Solid card colors for <Stat color="…"> (the "big stockpiles" cards). White
 * text sits on these, so each must clear WCAG AA (>=4.5) against white - see
 * src/a11y.test.ts. `ochre` was darkened from #b08227 (only 3.5:1) to pass.
 */
export const STAT_COLORS = {
  clay: "#9c4221",
  forest: "#2f5d3a",
  slate: "#395673",
  ochre: "#8a6418",
  plum: "#6d3b63",
} as const;

export type StatColor = keyof typeof STAT_COLORS;

export type ThemeKey = keyof typeof THEMES;

export const THEME_KEYS = Object.keys(THEMES) as [ThemeKey, ...ThemeKey[]];

/** Build the inline `style` string of CSS custom properties for a plan. */
export function themeVars(key: ThemeKey, accentOverride?: string): string {
  const t = THEMES[key] ?? THEMES.editorial;
  const accent = accentOverride || t.accent;
  return [
    `--bg:${t.bg}`,
    `--surface:${t.surface}`,
    `--subtle:${t.subtle}`,
    `--text:${t.text}`,
    `--muted:${t.muted}`,
    `--border:${t.border}`,
    `--accent:${accent}`,
    `--accent-text:${t.accentText}`,
    `--font-display:${t.displayFont}`,
    `--font-body:${t.bodyFont}`,
    `--font-mono:${t.monoFont}`,
  ].join(";");
}
