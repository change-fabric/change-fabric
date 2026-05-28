/**
 * WCAG 2.1 contrast math (no deps). Used by the a11y contrast test
 * (src/a11y.test.ts) to gate every theme's text/background pairs, and reusable
 * anywhere a runtime check is wanted. Thresholds: 4.5 normal text, 3.0 large
 * text (>=24px, or >=18.66px bold) and UI components.
 */

export interface RGB {
  r: number;
  g: number;
  b: number;
}

/** Parse #rgb / #rrggbb into 0-255 channels. */
export function parseHex(hex: string): RGB {
  const h = hex.trim().replace(/^#/, "");
  const full =
    h.length === 3
      ? h
          .split("")
          .map((c) => c + c)
          .join("")
      : h;
  if (!/^[0-9a-fA-F]{6}$/.test(full)) {
    throw new Error(`a11y: cannot parse color "${hex}"`);
  }
  return {
    r: parseInt(full.slice(0, 2), 16),
    g: parseInt(full.slice(2, 4), 16),
    b: parseInt(full.slice(4, 6), 16),
  };
}

/** Alpha-composite a foreground over an opaque background (alpha 0..1). */
export function composite(fg: RGB, bg: RGB, alpha: number): RGB {
  return {
    r: fg.r * alpha + bg.r * (1 - alpha),
    g: fg.g * alpha + bg.g * (1 - alpha),
    b: fg.b * alpha + bg.b * (1 - alpha),
  };
}

function channel(c: number): number {
  const cs = c / 255;
  return cs <= 0.03928 ? cs / 12.92 : Math.pow((cs + 0.055) / 1.055, 2.4);
}

/** WCAG relative luminance. */
export function luminance(c: RGB): number {
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/** WCAG contrast ratio between two colors (1..21). Accepts hex or RGB. */
export function contrast(a: string | RGB, b: string | RGB): number {
  const ca = typeof a === "string" ? parseHex(a) : a;
  const cb = typeof b === "string" ? parseHex(b) : b;
  const la = luminance(ca);
  const lb = luminance(cb);
  const [hi, lo] = la >= lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}
