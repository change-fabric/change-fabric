// cf:walkthrough diagram motion layer: the `count` and `draw` steps. Inlined
// only into a screen whose spec has one, so every other diagram screen keeps
// its bytes. Two halves, like the lane layer:
// - before the runtime reads the spec: a counted node is sized for the
//   widest text it ever shows (its label, its label steps, and the count's
//   formatted from and to values), written as cf_width, so a count never
//   reflows the layout;
// - attach (called after the runtime): wraps __cfAdvance once more, so on
//   every frame, after the runtime has written its own state, a counted
//   node's label shows the count's value and a drawn edge shows the share of
//   its path the draw has reached.
// Everything is a pure function of the capture clock through CfEase.p
// (scripts/walkthrough_ease.js); nothing reads wall time.
(() => {
  const specEl = document.getElementById('cf-diagram');
  const spec = JSON.parse(specEl.textContent);
  const E = window.CfEase;
  // Mirrors the runtime's node sizing (asserted by the lane tests).
  const NODE_MIN_W = 220;
  const NODE_MAX_W = 460;
  const CHAR_W = 17;
  const NODE_PAD_W = 56;
  const ICON_PX = 32;
  const ICON_GAP = 12;
  const COUNT_MS = 1200;
  const DRAW_MS = 900;

  const steps = (spec.steps || []).slice().sort((a, b) => a.t_ms - b.t_ms);
  const counts = steps.filter((s) => s.op === 'count');
  const draws = steps.filter((s) => s.op === 'draw');

  for (const n of spec.nodes) {
    const own = counts.filter((s) => s.id === n.id);
    if (own.length === 0 || n.cf_width) continue;
    const texts = [n.label || ''].concat(steps.filter((s) => s.op === 'label' && s.id === n.id).map((s) => s.text || ''))
      .concat(own.flatMap((s) => [E.number(s.from, s.format), E.number(s.to, s.format)]));
    const chars = Math.max(...texts.map((x) => x.length));
    const icon = n.icon ? ICON_PX + ICON_GAP : 0;
    const w = Math.min(NODE_MAX_W + icon, Math.max(NODE_MIN_W, chars * CHAR_W + NODE_PAD_W + icon));
    n.cf_width = Math.round(w / 2) * 2;
  }
  specEl.textContent = JSON.stringify(spec);

  // The latest step of a list for id at or before t, or null.
  const latest = (list, id, t) => {
    let hit = null;
    for (const s of list) { if (s.t_ms > t) break; if (s.id === id) hit = s; }
    return hit;
  };

  const css = document.createElement('style');
  css.textContent = '.react-flow__node[data-cf-count] .cf-node-label { font-variant-numeric: tabular-nums; }';
  document.head.appendChild(css);

  let lastT = 0;
  const draw = (t) => {
    lastT = t;
    const root = document.getElementById('cf-diagram-root');
    if (!root) return;
    for (const id of new Set(counts.map((s) => s.id))) {
      const el = root.querySelector(`.react-flow__node[data-id="${CSS.escape(id)}"]`);
      const s = latest(counts, id, t);
      if (!el || !s) continue;
      if (!el.hasAttribute('data-cf-count')) el.setAttribute('data-cf-count', '');
      const label = el.querySelector('.cf-node-label');
      const value = s.from + (s.to - s.from) * E.p(t, s.t_ms, s.duration == null ? COUNT_MS : s.duration);
      const text = E.number(value, s.format);
      if (label && label.textContent !== text) label.textContent = text;
    }
    for (const id of new Set(draws.map((s) => s.id))) {
      const el = root.querySelector(`.react-flow__edge[data-id="${CSS.escape(id)}"]`);
      const path = el && el.querySelector('.react-flow__edge-path');
      if (!path) continue;
      const s = latest(draws, id, t);
      // Undrawn until its first draw starts, then drawn on with the curve.
      const share = s ? E.p(t, s.t_ms, s.duration == null ? DRAW_MS : s.duration) : 0;
      if (path.getAttribute('pathLength') !== '1') path.setAttribute('pathLength', '1');
      path.style.strokeDasharray = '1 1';
      path.style.strokeDashoffset = String(1 - share);
      if (share < 1) path.removeAttribute('marker-end');
    }
  };

  window.__cfMotion = {
    attach() {
      if (typeof window.__cfAdvance === 'function') {
        const advance = window.__cfAdvance;
        window.__cfAdvance = (ms) => { const now = advance(ms); draw(performance.now()); return now; };
      }
      // The runtime re-applies its own state when React Flow remounts an
      // edge; draw again over it at the same virtual time.
      const root = document.getElementById('cf-diagram-root');
      if (root) new MutationObserver(() => draw(lastT)).observe(root, { childList: true, subtree: true });
      draw(performance.now());
    }
  };
})();
