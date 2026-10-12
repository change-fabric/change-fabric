import { MARK_PATHS, MARK_VIEWBOX } from "../brand/mark";

// The woven mark. Each path carries its light and dark color role as classes
// (.mark-l-*, .mark-d-* in styles.css), so the same SVG follows the theme. The weave's
// gaps are empty space, not a painted background, so it sits on any surface.
export function Mark({ size = 24, className }: { size?: number; className?: string }) {
  return (
    <svg
      className={className ? `mark ${className}` : "mark"}
      viewBox={`0 0 ${MARK_VIEWBOX} ${MARK_VIEWBOX}`}
      width={size}
      height={size}
      aria-hidden="true"
      focusable="false"
    >
      {MARK_PATHS.map((p, i) => (
        <path key={i} className={`mark-l-${p.light} mark-d-${p.dark}`} d={p.d} />
      ))}
    </svg>
  );
}

export const SUBTITLE = "A local-first framework for software quality and release readiness.";

type WordTag = "span" | "h1";

// Mark left of the serif wordmark. With a subtitle, the sans subtitle sits
// under the wordmark and the mark spans both, as on the brand sheet; without
// one (the header), the mark sits beside the wordmark alone.
export function LockupHorizontal({ subtitle, wordAs: Word = "span" }: { subtitle?: string; wordAs?: WordTag }) {
  if (!subtitle) {
    return (
      <span className="lockup lockup-h">
        <Mark />
        <Word className="lockup-word">change fabric</Word>
      </span>
    );
  }
  return (
    <div className="lockup lockup-h lockup-sub">
      <Mark />
      <div className="lockup-text">
        <Word className="lockup-word">change fabric</Word>
        <p className="lockup-subtitle">{subtitle}</p>
      </div>
    </div>
  );
}

// Mark centered above the wordmark and subtitle.
export function LockupStacked({ subtitle, wordAs: Word = "span" }: { subtitle?: string; wordAs?: WordTag }) {
  return (
    <div className="lockup lockup-v">
      <Mark />
      <Word className="lockup-word">change fabric</Word>
      {subtitle && <p className="lockup-subtitle">{subtitle}</p>}
    </div>
  );
}
