// cf:walkthrough element runtime. A classic script inlined after
// scripts/walkthrough_ease.js into the page scripts/walkthrough_element.rb
// builds for an element scene. It reads the plan (beats and steps, every time
// already in frames) from <script type="application/json" id="cf-element">,
// builds each beat's DOM once, and from then on derives every frame as a pure
// function of the frame number.
//
// Determinism rules this file keeps:
// - Time is the frame number only: f = round(performance.now() * fps / 1000)
//   - 1, read from the capture's fixed clock (frame i of the capture sees
//   (i + 1) frame lengths), never wall time, and all motion is
//   CfEase.p(f, start, length, ease).
// - Layout never depends on a measurement taken mid-motion: the beats are
//   built once at load, a count's box is as wide as its widest value in
//   tabular figures, and a line chart's geometry comes from the plan.
// - No CSS transitions or keyframes: every frame writes opacity and transform
//   inline.
(() => {
  const E = window.CfEase;
  const PLAN = JSON.parse(document.getElementById('cf-element').textContent);
  const FRAME = JSON.parse(document.getElementById('cf-element-frame').textContent);
  const FPS = PLAN.fps;
  const TYPE = FRAME.type || { label: 28, body: 40, statement: 96 };
  // Small text sits a step over the label minimum, so the 0.96 scale-in
  // never takes it under 28 px (scripts/walkthrough_clipcheck.rb).
  const SMALL_PX = Math.ceil(TYPE.label / 0.96) + 1;
  const SCALE_FROM = 0.96;
  const DIM_OPACITY = 0.35;
  const frames = (ms) => Math.max(1, Math.round((ms * FPS) / 1000));
  const TINT_F = frames(200);
  const GLIDE_F = frames(600);
  const PRESS_F = frames(120);
  const PROJ_F = frames(400);

  const style = document.createElement('style');
  style.textContent = `
:root { --font-sans: ${FRAME.font ? FRAME.font.sans : '"Inter", system-ui, sans-serif'}; --font-serif: ${FRAME.font ? FRAME.font.serif : '"Source Serif 4", Georgia, serif'}; }
html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: var(--cf-surface, #0f172a); }
body { background: var(--bg-gradient, var(--cf-surface, #0f172a)); }
#cf-element-root { position: relative; width: 100%; height: 100%; color: var(--cf-text, #f1f5f9); font-family: var(--font-sans); }
.cf-beat { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; opacity: 0; will-change: opacity, transform; }
.cf-statement { margin: 0; font: 600 ${TYPE.statement}px/1.32 var(--font-serif); letter-spacing: -0.01em; text-align: center; }
.cf-statement span { display: block; white-space: nowrap; }
.cf-card { box-sizing: border-box; padding: 48px; border-radius: 28px; background: var(--cf-node, #1e293b); border: 1px solid var(--cf-rule, #334155);
  box-shadow: var(--shadow-2, 0 24px 64px rgba(0, 0, 0, 0.28)); }
.cf-card-head { display: flex; align-items: center; justify-content: space-between; gap: 24px; }
.cf-card-title { font: 600 ${Math.round(TYPE.body * 1.2)}px/1.2 var(--font-sans); white-space: nowrap; }
.cf-card-sub { margin-top: 8px; font: 400 ${SMALL_PX}px/1.3 var(--font-sans); color: var(--cf-muted, #cbd5e1); white-space: nowrap; }
.cf-badge { flex: none; padding: 6px 18px; border-radius: 999px; background: var(--cf-accent-tint, #1b2e4b); color: var(--cf-text, #f1f5f9);
  font: 600 ${SMALL_PX}px/1.3 var(--font-sans); white-space: nowrap; }
.cf-rows { margin-top: 32px; }
.cf-row { display: flex; justify-content: space-between; gap: 24px; padding: 16px 0; border-top: 1px solid var(--cf-rule, #334155);
  font: 400 ${SMALL_PX}px/1.3 var(--font-sans); white-space: nowrap; }
.cf-row-label { color: var(--cf-muted, #cbd5e1); }
.cf-row-value { font-weight: 600; font-variant-numeric: tabular-nums; }
.cf-number { display: flex; flex-direction: column; align-items: center; gap: 16px; }
.cf-number-value { font: 700 ${TYPE.statement * 2}px/1.2 var(--font-sans); font-variant-numeric: tabular-nums; letter-spacing: -0.02em;
  text-align: center; white-space: nowrap; }
.cf-number-label { font: 500 ${TYPE.body}px/1.2 var(--font-sans); color: var(--cf-muted, #cbd5e1); white-space: nowrap; }
.cf-line { display: flex; flex-direction: column; align-items: center; gap: 24px; }
.cf-line-label { font: 600 ${TYPE.body}px/1.2 var(--font-sans); white-space: nowrap; }
.cf-list { box-sizing: border-box; width: 960px; padding: 24px; border-radius: 28px; background: var(--cf-node, #1e293b);
  border: 1px solid var(--cf-rule, #334155); box-shadow: var(--shadow-2, 0 24px 64px rgba(0, 0, 0, 0.28)); position: relative; }
.cf-list-row { padding: 20px 24px; border-radius: 16px; font: 500 ${Math.round(TYPE.body * 0.85)}px/1.3 var(--font-sans); white-space: nowrap; }
.cf-controls { display: flex; gap: 16px; margin-top: 24px; padding: 0 8px; }
.cf-control { padding: 14px 28px; border-radius: 14px; background: var(--cf-accent, #60a5fa); color: var(--cf-surface, #0f172a);
  font: 600 ${SMALL_PX}px/1.3 var(--font-sans); white-space: nowrap; }
.cf-cursor { position: absolute; left: 0; top: 0; width: 44px; height: 44px; pointer-events: none; transform-origin: 6px 4px; }
`;
  document.head.appendChild(style);

  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };
  const svg = (tag, attrs) => {
    const n = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [k, v] of Object.entries(attrs || {})) n.setAttribute(k, String(v));
    return n;
  };

  // -- build ---------------------------------------------------------------

  const counts = PLAN.steps.filter((s) => s.op === 'count');
  const draws = PLAN.steps.filter((s) => s.op === 'draw');
  const latest = (list, id, f) => {
    let hit = null;
    for (const s of list) if (s.id === id && s.t_f <= f && (!hit || s.t_f >= hit.t_f)) hit = s;
    return hit;
  };
  const first = (list, id) => list.filter((s) => s.id === id).sort((a, b) => a.t_f - b.t_f)[0] || null;

  const build = {
    statement(b) {
      const p = el('p', 'cf-statement');
      for (const line of b.lines) p.appendChild(el('span', null, line));
      return { node: p };
    },
    card(b) {
      const card = el('div', 'cf-card');
      card.style.width = `${b.width || 720}px`;
      const head = el('div', 'cf-card-head');
      const titles = el('div');
      titles.appendChild(el('div', 'cf-card-title', b.title));
      if (b.subtitle) titles.appendChild(el('div', 'cf-card-sub', b.subtitle));
      head.appendChild(titles);
      if (b.badge) head.appendChild(el('span', 'cf-badge', b.badge));
      card.appendChild(head);
      if (b.rows && b.rows.length) {
        const rows = el('div', 'cf-rows');
        for (const r of b.rows) {
          const row = el('div', 'cf-row');
          row.appendChild(el('span', 'cf-row-label', r.label));
          row.appendChild(el('span', 'cf-row-value', r.value));
          rows.appendChild(row);
        }
        card.appendChild(rows);
      }
      return { node: card };
    },
    number(b) {
      const wrap = el('div', 'cf-number');
      const value = el('div', 'cf-number-value', E.number(b.value, b.format));
      // As wide as the widest value it ever shows, in tabular figures, so a
      // count never changes its width mid-count.
      const texts = [E.number(b.value, b.format)].concat(counts.filter((s) => s.id === b.id)
        .flatMap((s) => [E.number(s.from, s.format || b.format), E.number(s.to, s.format || b.format)]));
      value.style.minWidth = `${Math.max(...texts.map((x) => x.length))}ch`;
      wrap.appendChild(value);
      if (b.label) wrap.appendChild(el('div', 'cf-number-label', b.label));
      return { node: wrap, value };
    },
    line(b) {
      const W = 1200; const H = 520; const PAD = 24;
      const wrap = el('div', 'cf-line');
      if (b.label) wrap.appendChild(el('div', 'cf-line-label', b.label));
      const pts = b.points; const proj = b.projection || [];
      const all = pts.concat(proj);
      const lo = Math.min(...all); const hi = Math.max(...all);
      const span = hi - lo || 1;
      const x = (i) => PAD + (i * (W - 2 * PAD)) / Math.max(1, all.length - 1);
      const y = (v) => H - PAD - ((v - lo) / span) * (H - 2 * PAD);
      const d = (vals, from) => vals.map((v, i) => `${i ? 'L' : 'M'}${x(from + i).toFixed(1)},${y(v).toFixed(1)}`).join(' ');
      const s = svg('svg', { width: W, height: H, viewBox: `0 0 ${W} ${H}`, 'aria-hidden': 'true' });
      const gid = `cf-grad-${b.id}`; const cid = `cf-clip-${b.id}`;
      const defs = svg('defs');
      const grad = svg('linearGradient', { id: gid, x1: 0, y1: 0, x2: 0, y2: 1 });
      grad.appendChild(svg('stop', { offset: 0, 'stop-color': 'var(--cf-accent, #60a5fa)', 'stop-opacity': 0.35 }));
      grad.appendChild(svg('stop', { offset: 1, 'stop-color': 'var(--cf-accent, #60a5fa)', 'stop-opacity': 0 }));
      const clip = svg('clipPath', { id: cid });
      const clipRect = svg('rect', { x: 0, y: 0, width: 0, height: H });
      clip.appendChild(clipRect);
      defs.appendChild(grad); defs.appendChild(clip);
      s.appendChild(defs);
      const last = pts.length - 1;
      const area = svg('path', { d: `${d(pts, 0)} L${x(last).toFixed(1)},${H - PAD} L${x(0).toFixed(1)},${H - PAD} Z`, fill: `url(#${gid})`, 'clip-path': `url(#${cid})` });
      const stroke = svg('path', { d: d(pts, 0), fill: 'none', stroke: 'var(--cf-accent, #60a5fa)', 'stroke-width': 6,
        'stroke-linecap': 'round', 'stroke-linejoin': 'round', pathLength: 1, 'stroke-dasharray': '1 1' });
      s.appendChild(area); s.appendChild(stroke);
      let projection = null; let glow = null;
      if (proj.length) {
        projection = svg('path', { d: d([pts[last]].concat(proj), last), fill: 'none', stroke: 'var(--cf-accent, #60a5fa)', 'stroke-width': 4,
          'stroke-linecap': 'round', 'stroke-dasharray': '14 12', opacity: 0 });
        const end = all.length - 1;
        glow = svg('g', { opacity: 0 });
        glow.appendChild(svg('circle', { cx: x(end), cy: y(all[end]), r: 22, fill: 'var(--cf-accent, #60a5fa)', opacity: 0.22 }));
        glow.appendChild(svg('circle', { cx: x(end), cy: y(all[end]), r: 10, fill: 'var(--cf-accent, #60a5fa)' }));
        s.appendChild(projection); s.appendChild(glow);
      }
      wrap.appendChild(s);
      return { node: wrap, stroke, clipRect, projection, glow, W };
    },
    cursor(b) {
      const list = el('div', 'cf-list');
      const rows = b.rows.map((r) => { const row = el('div', 'cf-list-row', r); list.appendChild(row); return row; });
      let controls = [];
      if (b.controls && b.controls.length) {
        const bar = el('div', 'cf-controls');
        controls = b.controls.map((c) => { const n = el('span', 'cf-control', c.label); bar.appendChild(n); return { node: n, dims: !!c.dims }; });
        list.appendChild(bar);
      }
      const pointer = svg('svg', { class: 'cf-cursor', viewBox: '0 0 24 24', 'aria-hidden': 'true' });
      pointer.appendChild(svg('path', { d: 'M3 2 L3 19 L8 14.5 L11.5 22 L14.5 20.6 L11 13.3 L17.5 13.3 Z', fill: '#ffffff', stroke: '#0f172a', 'stroke-width': 1.4, 'stroke-linejoin': 'round' }));
      list.appendChild(pointer);
      return { node: list, rows, controls, pointer };
    }
  };

  const root = document.getElementById('cf-element-root');
  const beats = PLAN.beats.map((b) => {
    const host = el('section', 'cf-beat');
    host.dataset.id = b.id;
    const parts = build[b.type](b);
    host.appendChild(parts.node);
    root.appendChild(host);
    return Object.assign({ b, host }, parts);
  });

  // -- per frame -------------------------------------------------------------

  // A beat's entrance share and its visibility (entrance times exit).
  const presence = (b, f) => {
    const enter = E.p(f, b.enter_f, b.land_f - b.enter_f);
    const exit = b.exit_f == null ? 0 : E.p(f, b.exit_f, b.exit_end_f - b.exit_f);
    return { enter, opacity: f < b.enter_f ? 0 : enter * (1 - exit) };
  };

  const step = {
    number(x, f) {
      const s = latest(counts, x.b.id, f);
      const v = s ? s.from + (s.to - s.from) * E.p(f, s.t_f, s.dur_f) : x.b.value;
      const text = E.number(v, (s && s.format) || x.b.format);
      if (x.value.textContent !== text) x.value.textContent = text;
    },
    line(x, f) {
      const s = latest(draws, x.b.id, f) || null;
      // Undrawn until its first draw starts; fully drawn without one.
      const share = s ? E.p(f, s.t_f, s.dur_f) : (first(draws, x.b.id) ? 0 : 1);
      x.stroke.setAttribute('stroke-dashoffset', (1 - share).toFixed(4));
      x.clipRect.setAttribute('width', (share * x.W).toFixed(1));
      if (x.projection) {
        const end = s ? s.t_f + s.dur_f : (first(draws, x.b.id) ? Infinity : x.b.land_f);
        const o = share < 1 ? 0 : E.p(f, end, PROJ_F);
        x.projection.setAttribute('opacity', o.toFixed(3));
        x.glow.setAttribute('opacity', o.toFixed(3));
      }
    },
    cursor(x, f) {
      const b = x.b;
      const row = x.rows[b.click - 1];
      const tx = row.offsetLeft + row.offsetWidth * 0.72; const ty = row.offsetTop + row.offsetHeight * 0.5;
      const g = E.p(f, b.click_f - GLIDE_F, GLIDE_F);
      const px = tx + 240 * (1 - g); const py = ty + 200 * (1 - g);
      const pressed = f >= b.click_f && f < b.click_f + PRESS_F;
      x.pointer.style.transform = `translate(${px.toFixed(1)}px, ${py.toFixed(1)}px) scale(${pressed ? 0.85 : 1})`;
      const tint = E.p(f, b.click_f, TINT_F);
      row.style.background = tint > 0 ? `color-mix(in srgb, var(--cf-accent-tint, #1b2e4b) ${(tint * 100).toFixed(1)}%, transparent)` : '';
      for (const c of x.controls) if (c.dims) c.node.style.opacity = String(1 - (1 - DIM_OPACITY) * tint);
    }
  };

  const frameAt = (now) => Math.round((now * FPS) / 1000) - 1;
  const apply = () => {
    const f = frameAt(performance.now());
    for (const x of beats) {
      const { enter, opacity } = presence(x.b, f);
      x.host.style.opacity = opacity.toFixed(4);
      x.host.style.transform = `scale(${(SCALE_FROM + (1 - SCALE_FROM) * enter).toFixed(5)})`;
      x.host.style.visibility = opacity > 0 ? 'visible' : 'hidden';
      if (step[x.b.type]) step[x.b.type](x, f);
    }
  };

  // -- clip check boxes ------------------------------------------------------

  const opacityOf = (n0) => {
    let o = 1;
    for (let n = n0; n && n !== document.body; n = n.parentElement) o *= Number(getComputedStyle(n).opacity);
    return o;
  };
  const scaleOf = (n) => (n.offsetWidth > 0 ? n.getBoundingClientRect().width / n.offsetWidth : 1);
  const overflows = (n) => n.clientWidth > 0 && (n.scrollWidth > n.clientWidth + 1 || n.scrollHeight > n.clientHeight + 1);
  const rectOf = (r) => ({ x: Math.round(r.left * 10) / 10, y: Math.round(r.top * 10) / 10, w: Math.round(r.width * 10) / 10, h: Math.round(r.height * 10) / 10 });
  const ownText = (n) => [...n.childNodes].filter((c) => c.nodeType === 3).map((c) => c.textContent).join('').trim();
  window.__cfBoxes = () => {
    const out = [];
    for (const x of beats) {
      if (x.host.style.visibility === 'hidden' || opacityOf(x.host) < 0.05) continue;
      out.push(Object.assign({ id: x.b.id, kind: 'node', text: '' }, rectOf(x.node.getBoundingClientRect())));
      for (const n of x.host.querySelectorAll('*')) {
        const text = ownText(n);
        if (!text || opacityOf(n) < 0.05) continue;
        const r = n.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) continue;
        const px = parseFloat(getComputedStyle(n).fontSize) * scaleOf(n);
        out.push(Object.assign({ id: `${x.b.id}:${text}`, kind: 'text', text, font_px: Math.round(px * 10) / 10, overflow: overflows(n) }, rectOf(r)));
      }
    }
    return out;
  };

  apply();
  if (typeof window.__cfAdvance === 'function') {
    const advance = window.__cfAdvance;
    window.__cfAdvance = (ms) => { const now = advance(ms); apply(); return now; };
  } else {
    const loop = () => { apply(); window.requestAnimationFrame(loop); };
    window.requestAnimationFrame(loop);
  }
})();
