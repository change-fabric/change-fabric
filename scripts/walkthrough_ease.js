// cf:walkthrough motion helper: the one easing source every runtime page
// shares. A classic script inlined ahead of the element runtime and of the
// diagram lane and motion layers; it defines window.CfEase and nothing else.
//
//   CfEase.p(t, start, dur, ease) -> 0..1
//
// t, start, and dur are in one unit (the element runtime passes frame
// numbers, the diagram layers milliseconds of the capture clock); nothing
// here reads a clock. ease is a preset name, a CSS cubic-bezier(...) string,
// or a function; the default is cosine ease-in-out. A zero duration is a
// step at start. Determinism: a cubic-bezier is solved by fixed-count
// bisection, so every engine lands on the same value for the same input.
(() => {
  const clamp01 = (v) => Math.min(1, Math.max(0, v));

  // The u in 0..1 where a rising fn(u) reaches p, by fixed-count bisection.
  const bisect = (fn, p) => {
    let lo = 0; let hi = 1;
    for (let i = 0; i < 40; i += 1) { const mid = (lo + hi) / 2; if (fn(mid) < p) lo = mid; else hi = mid; }
    return (lo + hi) / 2;
  };
  const bezier = (x1, y1, x2, y2) => {
    const at = (a, b, u) => 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u;
    return (p) => {
      if (p <= 0) return 0;
      if (p >= 1) return 1;
      return at(y1, y2, bisect((u) => at(x1, x2, u), p));
    };
  };
  const cosine = (p) => 0.5 - 0.5 * Math.cos(Math.PI * clamp01(p));
  const cubic = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
  const EASINGS = {
    cosine,
    linear: (p) => clamp01(p), 'ease-in-out': (p) => cubic(clamp01(p)),
    standard: bezier(0.4, 0, 0.2, 1), decelerate: bezier(0, 0, 0.2, 1), accelerate: bezier(0.4, 0, 1, 1),
    emphasized: bezier(0.22, 1, 0.36, 1), settle: bezier(0.16, 1, 0.3, 1)
  };
  // A name, a cubic-bezier string, or a function; unknown falls back to
  // `fallback` (cosine unless the caller names another preset).
  const easing = (name, fallback = 'cosine') => {
    if (typeof name === 'function') return name;
    if (!name) return EASINGS[fallback];
    if (EASINGS[name]) return EASINGS[name];
    const m = String(name).match(/^cubic-bezier\(([^)]*)\)$/);
    const v = m ? m[1].split(',').map(Number) : [];
    return v.length === 4 && v.every(Number.isFinite) ? bezier(...v) : EASINGS[fallback];
  };
  const p = (t, start, dur, ease) => {
    if (!(dur > 0)) return t >= start ? 1 : 0;
    return easing(ease)(clamp01((t - start) / dur));
  };

  // A count value as text: fixed decimals, comma grouping, prefix and
  // suffix. Written by hand (no Intl) so the digits never depend on the
  // page's locale data.
  const number = (value, format) => {
    const f = format || {};
    const decimals = Number.isInteger(f.decimals) ? f.decimals : 0;
    const fixed = Math.abs(value).toFixed(decimals);
    const [whole, frac] = fixed.split('.');
    const grouped = f.grouping === false ? whole : whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    const sign = value < 0 && Number(fixed) !== 0 ? '-' : '';
    return `${sign}${f.prefix || ''}${grouped}${frac ? `.${frac}` : ''}${f.suffix || ''}`;
  };

  window.CfEase = Object.freeze({ p, easing, bezier, bisect, cosine, cubic, clamp01, number, EASINGS });
})();
