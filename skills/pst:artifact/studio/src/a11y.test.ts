import { describe, it, expect } from "vitest";
import { THEMES, STAT_COLORS, type ThemeKey } from "./lib/theme";
import { contrast, composite, parseHex } from "./lib/a11y";

// Automated WCAG AA gate over the real theme palette. This is the guardrail that
// would have caught the gradient-hero contrast bug. publish.py runs it before
// every build, so a contrast regression blocks publish.
//
// Thresholds: 4.5 for normal text; 3.0 for large/supplementary text. Not yet
// gated: the semantic Pill solid tones (success/warning/danger/info) - status
// chips, tuned separately.
const AA_NORMAL = 4.5;
const AA_SUPPLEMENTARY = 3.0;
const WHITE = "#ffffff";

describe("WCAG AA contrast across every theme", () => {
  (Object.keys(THEMES) as ThemeKey[]).forEach((key) => {
    const t = THEMES[key];
    const pairs: ReadonlyArray<readonly [string, string, string]> = [
      ["body text on bg", t.text, t.bg],
      ["body text on surface", t.text, t.surface],
      ["body text on subtle", t.text, t.subtle],
      ["muted text on bg", t.muted, t.bg],
      ["muted text on surface", t.muted, t.surface],
      ["accent (link/eyebrow) on bg", t.accent, t.bg],
      ["accent (link/eyebrow) on surface", t.accent, t.surface],
      [
        "accentText on accent (gradient hero + solid pills)",
        t.accentText,
        t.accent,
      ],
      ["white stat label on accent card", WHITE, t.accent],
    ];
    pairs.forEach(([what, fg, bg]) => {
      it(`${key}: ${what} >= ${AA_NORMAL}`, () => {
        expect(contrast(fg, bg)).toBeGreaterThanOrEqual(AA_NORMAL);
      });
    });
  });

  // Solid "big stockpile" stat cards: white label must clear AA; the small
  // italic note (90% white) is supplementary.
  Object.entries(STAT_COLORS).forEach(([name, hex]) => {
    it(`stat card "${name}": white label >= ${AA_NORMAL}`, () => {
      expect(contrast(WHITE, hex)).toBeGreaterThanOrEqual(AA_NORMAL);
    });
    it(`stat card "${name}": 90% white note >= ${AA_SUPPLEMENTARY}`, () => {
      const note = composite(parseHex(WHITE), parseHex(hex), 0.9);
      expect(contrast(note, hex)).toBeGreaterThanOrEqual(AA_SUPPLEMENTARY);
    });
  });
});
