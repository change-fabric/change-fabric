// cf:walkthrough diagram swimlanes. A classic script the generator inlines
// only into a screen whose spec declares `lanes`, between the xyflow bundle
// and cf_diagram_runtime.js, so a screen without lanes keeps its bytes and
// the runtime itself never learns about lanes.
//
// It works in two halves:
// - prepare (runs at load, before the runtime parses the spec): lays every
//   node out once, places each laned node inside its band, pins every node
//   to that position, and rewrites a `travel` step on a node into the two
//   `move` steps the runtime already knows (a jump to the lane's start and
//   an eased glide to its end). The travel step itself becomes an empty
//   add_node in place, so step indices (which key flow colours) hold and the
//   runtime's camera fold never sees an op it does not aim.
// - attach (called by a one-line script after the runtime): draws the bands,
//   their labels and separators behind the diagram, and any marker travel in
//   front of it, as a pure function of the capture clock, after every
//   __cfAdvance the runtime has already wrapped. No CSS or SMIL animation.
//
// The node sizing and dagre constants mirror cf_diagram_runtime.js; the
// diagram unit test asserts they match.
(() => {
  const dataEl = document.getElementById('cf-diagram-lanes');
  const specEl = document.getElementById('cf-diagram');
  if (!dataEl || !specEl) return;
  const LANES = JSON.parse(dataEl.textContent);
  const spec = JSON.parse(specEl.textContent);
  const { dagre } = window.CfXyflow;
  const iconsEl = document.getElementById('cf-diagram-icons');
  const ICONS = iconsEl ? JSON.parse(iconsEl.textContent) : {};
  const iconOf = (n) => (n.icon ? ICONS[`${n.icon}/${n.icon_weight || 'regular'}`] : null);

  const NODE_H = 56;
  const NODE_MIN_W = 140;
  const NODE_MAX_W = 260;
  const CHAR_W = 11;
  const NODE_PAD_W = 40;
  const ICON_PX = 20;
  const ICON_GAP = 8;
  const NODE_SEP = 60;
  const RANK_SEP = 120;
  const FADE_MS = 300;
  const DIM_OPACITY = 0.35;
  const LANE_PAD = 28;
  const ROW_GAP = 24;
  const LANE_MIN = 120;
  const ALONG_PAD = 80;
  const TRAVEL_MS = 1600;
  const MARKER_FADE_MS = 120;
  const MARKER_R = 7;
  const MARKER_HALO_R = 15;

  const horizontal = LANES.direction !== 'vertical';
  const along = horizontal ? 'x' : 'y';
  const cross = horizontal ? 'y' : 'x';
  const steps = spec.steps || [];
  const nodeIds = spec.nodes.map((n) => n.id);
  const laneIds = LANES.lanes.map((l) => l.id);

  const WIDTH = Object.fromEntries(spec.nodes.map((n) => {
    const texts = [n.label || ''].concat(steps.filter((s) => s.op === 'label' && s.id === n.id).map((s) => s.text || ''));
    const chars = Math.max(...texts.map((x) => x.length));
    const icon = iconOf(n) ? ICON_PX + ICON_GAP : 0;
    const w = Math.min(NODE_MAX_W + icon, Math.max(NODE_MIN_W, chars * CHAR_W + NODE_PAD_W + icon));
    return [n.id, Math.round(w / 2) * 2];
  }));
  const size = (id, axis) => (axis === 'x' ? WIDTH[id] : NODE_H);
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

  // -- prepare -----------------------------------------------------------

  const direction = (spec.layout && spec.layout.direction) || 'LR';
  const pos = {};
  if (((spec.layout && spec.layout.engine) || 'dagre') === 'dagre') {
    const g = new dagre.graphlib.Graph();
    g.setGraph({ rankdir: direction, nodesep: NODE_SEP, ranksep: RANK_SEP, marginx: 0, marginy: 0 });
    g.setDefaultEdgeLabel(() => ({}));
    for (const n of spec.nodes) g.setNode(n.id, { width: WIDTH[n.id], height: NODE_H });
    for (const e of spec.edges) g.setEdge(e.source, e.target);
    dagre.layout(g);
    for (const id of nodeIds) { const p = g.node(id); pos[id] = { x: Math.round(p.x - WIDTH[id] / 2), y: Math.round(p.y - NODE_H / 2) }; }
  }
  const pinned = new Set();
  for (const n of spec.nodes) if (n.position) { pos[n.id] = { x: n.position.x, y: n.position.y }; pinned.add(n.id); }
  for (const id of nodeIds) if (!pos[id]) pos[id] = { x: 0, y: 0 };

  // Bands stack along the cross axis in spec order. Inside a band, nodes
  // keep their along coordinate and take rows greedily, so two nodes that
  // would overlap sit one row apart; the band grows to fit its rows. A
  // pinned node keeps only its along coordinate: the band owns the other.
  const bands = {};
  let edge = 0;
  for (const lane of LANES.lanes) {
    const members = spec.nodes.filter((n) => n.lane === lane.id).map((n) => n.id)
      .sort((a, b) => pos[a][along] - pos[b][along] || nodeIds.indexOf(a) - nodeIds.indexOf(b));
    const rows = [];
    const rowOf = {};
    for (const id of members) {
      let r = rows.findIndex((row) => row.end + ROW_GAP <= pos[id][along]);
      if (r < 0) { rows.push({ end: -Infinity, size: 0 }); r = rows.length - 1; }
      rows[r].end = pos[id][along] + size(id, along);
      rows[r].size = Math.max(rows[r].size, size(id, cross));
      rowOf[id] = r;
    }
    const content = rows.reduce((sum, row) => sum + row.size, 0) + ROW_GAP * Math.max(0, rows.length - 1);
    const extent = Math.max(LANE_MIN, content + 2 * LANE_PAD);
    let at = edge + (extent - content) / 2;
    const rowStart = rows.map((row) => { const s = at; at += row.size + ROW_GAP; return s; });
    for (const id of members) pos[id][cross] = Math.round(rowStart[rowOf[id]] + (rows[rowOf[id]].size - size(id, cross)) / 2);
    bands[lane.id] = { start: edge, extent };
    edge += extent;
  }

  // A laid-out node outside every lane keeps its place relative to the
  // other such nodes, centred on the stack of bands.
  const free = nodeIds.filter((id) => !spec.nodes.find((n) => n.id === id).lane && !pinned.has(id));
  if (free.length && spec.layout && spec.layout.engine === 'manual') free.length = 0;
  if (free.length) {
    const lo = Math.min(...free.map((id) => pos[id][cross]));
    const hi = Math.max(...free.map((id) => pos[id][cross] + size(id, cross)));
    const shift = Math.round(edge / 2 - (lo + hi) / 2);
    for (const id of free) pos[id][cross] += shift;
  }

  // Travel runs from just before the first laned node to just past the
  // last, across every lane alike; a travelling node is not part of it.
  const travellers = new Set(steps.filter((s) => s.op === 'travel' && s.id).map((s) => s.id));
  const laned = spec.nodes.filter((n) => n.lane && !travellers.has(n.id)).map((n) => n.id);
  const span = laned.length
    ? [Math.min(...laned.map((id) => pos[id][along])) - ALONG_PAD, Math.max(...laned.map((id) => pos[id][along] + size(id, along))) + ALONG_PAD]
    : [0, 600];

  for (const n of spec.nodes) n.position = { x: Math.round(pos[n.id].x), y: Math.round(pos[n.id].y) };
  const markers = [];
  steps.forEach((s, i) => {
    if (s.op !== 'travel') return;
    const band = bands[s.lane];
    const duration = s.duration == null ? TRAVEL_MS : s.duration;
    if (s.id) {
      const mid = band.start + (band.extent - size(s.id, cross)) / 2;
      const at = (a) => ({ [along]: Math.round(a), [cross]: Math.round(mid) });
      steps.push({ t_ms: s.t_ms, op: 'move', id: s.id, position: at(span[0]) },
        { t_ms: s.t_ms, op: 'move', id: s.id, position: at(span[1] - size(s.id, along)), duration });
    } else {
      markers.push({ t_ms: s.t_ms, duration, lane: s.lane });
    }
    steps[i] = { t_ms: s.t_ms, op: 'add_node', ids: [] };
  });
  spec.steps = steps;
  specEl.textContent = JSON.stringify(spec);

  // -- draw --------------------------------------------------------------

  const clamp01 = (v) => clamp(v, 0, 1);
  const ease = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
  const ordered = steps.map((s, i) => [s, i]).sort((a, b) => a[0].t_ms - b[0].t_ms || a[1] - b[1]).map(([s]) => s);
  const named = (spec.initial || []).filter((id) => laneIds.includes(id));

  // Lane state at t, replayed from the original spec's ops: a lane shows
  // from the start when `initial` names it, or when `initial` names no lane.
  const derive = (t) => {
    const shownAt = {};
    for (const id of named.length ? named : laneIds) shownAt[id] = -Infinity;
    const removedAt = {};
    const hl = new Set();
    const dim = new Set();
    for (const s of ordered) {
      if (s.t_ms > t) break;
      const ids = (s.ids || (s.id ? [s.id] : [])).filter((id) => laneIds.includes(id));
      for (const id of ids) {
        if (s.op === 'add_node') { shownAt[id] = s.t_ms; delete removedAt[id]; }
        else if (s.op === 'remove') removedAt[id] = s.t_ms;
        else if (s.op === 'highlight') { hl.add(id); dim.delete(id); }
        else if (s.op === 'dim') { dim.add(id); hl.delete(id); }
        else if (s.op === 'unhighlight') { hl.delete(id); dim.delete(id); }
      }
    }
    const opacity = (id) => {
      let o = id in shownAt ? clamp01((t - shownAt[id]) / FADE_MS) : 0;
      if (id in removedAt) o = Math.min(o, 1 - clamp01((t - removedAt[id]) / FADE_MS));
      return o * (dim.has(id) ? DIM_OPACITY : 1);
    };
    return { opacity, hl };
  };

  const css = document.createElement('style');
  css.textContent = `
body { background: var(--cf-surface, #ffffff); }
#cf-diagram-root { position: relative; z-index: 1; }
#cf-diagram-root .react-flow { background: transparent; --xy-background-color: transparent; }
.cf-lanes, .cf-lane-markers { position: fixed; inset: 0; pointer-events: none; overflow: visible; }
.cf-lanes { z-index: 0; }
.cf-lane-markers { z-index: 2; }
.cf-lane { position: absolute; box-sizing: border-box; border: 0 solid var(--cf-rule, #cbd5e1); }
.cf-lanes[data-dir="horizontal"] .cf-lane { left: 0; right: 0; border-top-width: 1px; border-bottom-width: 1px; }
.cf-lanes[data-dir="vertical"] .cf-lane { top: 0; bottom: 0; border-left-width: 1px; border-right-width: 1px; }
.cf-lane-label { position: absolute; box-sizing: border-box; white-space: nowrap; padding: 2px 10px; border-left: 4px solid;
  color: var(--cf-text, #0f172a); font: 600 15px/1.3 system-ui, sans-serif; letter-spacing: 0.02em; }
.cf-lanes[data-dir="horizontal"] .cf-lane-label { left: 12px; top: 10px; }
.cf-lanes[data-dir="vertical"] .cf-lane-label { left: 10px; top: 12px; }
.cf-lane-label svg { width: 18px; height: 18px; margin-right: 6px; vertical-align: -3px; }
.cf-lane-marker { position: absolute; border-radius: 50%; box-sizing: border-box; }
`;
  document.head.appendChild(css);

  const layer = (cls) => { const el = document.createElement('div'); el.className = cls; el.setAttribute('aria-hidden', 'true'); return el; };
  const back = layer('cf-lanes');
  back.dataset.dir = horizontal ? 'horizontal' : 'vertical';
  const front = layer('cf-lane-markers');
  const laneEls = {};
  for (const lane of LANES.lanes) {
    const el = document.createElement('div');
    el.className = 'cf-lane';
    el.dataset.lane = lane.id;
    const label = document.createElement('div');
    label.className = 'cf-lane-label';
    label.style.borderLeftColor = lane.color;
    const paths = lane.icon && ICONS[lane.icon];
    if (paths) {
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('viewBox', '0 0 256 256');
      svg.setAttribute('aria-hidden', 'true');
      svg.style.fill = lane.color;
      for (const [d, opacity] of paths) {
        const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('d', d);
        if (opacity != null) path.setAttribute('opacity', String(opacity));
        svg.appendChild(path);
      }
      label.appendChild(svg);
    }
    label.appendChild(document.createTextNode(lane.label));
    el.appendChild(label);
    back.appendChild(el);
    laneEls[lane.id] = el;
  }
  const markerEls = markers.map((m) => {
    const lane = LANES.lanes.find((l) => l.id === m.lane);
    const halo = document.createElement('div');
    halo.className = 'cf-lane-marker';
    Object.assign(halo.style, { width: `${2 * MARKER_HALO_R}px`, height: `${2 * MARKER_HALO_R}px`, background: lane.tint_hl, border: `1px solid ${lane.color}` });
    const core = document.createElement('div');
    core.className = 'cf-lane-marker';
    Object.assign(core.style, { width: `${2 * MARKER_R}px`, height: `${2 * MARKER_R}px`, background: lane.color, left: `${MARKER_HALO_R - MARKER_R - 1}px`, top: `${MARKER_HALO_R - MARKER_R - 1}px` });
    halo.appendChild(core);
    front.appendChild(halo);
    return halo;
  });

  // The camera the runtime set this frame, read back from React Flow.
  const viewport = () => {
    const el = document.querySelector('.react-flow__viewport');
    const m = el && el.style.transform.match(/translate\(([-\d.e]+)px,\s*([-\d.e]+)px\)\s*scale\(([-\d.e]+)\)/);
    return m ? { x: Number(m[1]), y: Number(m[2]), zoom: Number(m[3]) } : null;
  };
  const set = (el, key, value) => { if (el.style[key] !== value) el.style[key] = value; };
  const px = (v) => `${v.toFixed(2)}px`;

  const draw = () => {
    const vp = viewport();
    if (!vp) return;
    const t = performance.now();
    const s = derive(t);
    const off = horizontal ? vp.y : vp.x;
    for (const lane of LANES.lanes) {
      const el = laneEls[lane.id];
      const band = bands[lane.id];
      set(el, horizontal ? 'top' : 'left', px(band.start * vp.zoom + off));
      set(el, horizontal ? 'height' : 'width', px(band.extent * vp.zoom));
      set(el, 'background', s.hl.has(lane.id) ? lane.tint_hl : lane.tint);
      set(el, 'opacity', String(s.opacity(lane.id)));
      el.dataset.cfHl = s.hl.has(lane.id) ? '1' : '0';
    }
    markers.forEach((m, i) => {
      const el = markerEls[i];
      const local = t - m.t_ms;
      const on = local >= 0 && local <= m.duration;
      set(el, 'display', on ? 'block' : 'none');
      if (!on) return;
      const band = bands[m.lane];
      const a = (span[0] + (span[1] - span[0]) * ease(clamp01(local / m.duration))) * vp.zoom + (horizontal ? vp.x : vp.y);
      const c = (band.start + band.extent / 2) * vp.zoom + off;
      set(el, 'left', px((horizontal ? a : c) - MARKER_HALO_R));
      set(el, 'top', px((horizontal ? c : a) - MARKER_HALO_R));
      set(el, 'opacity', clamp01(Math.min(local, m.duration - local) / MARKER_FADE_MS).toFixed(3));
    });
  };

  window.__cfLanes = {
    bands, span,
    attach() {
      document.body.prepend(back);
      document.body.appendChild(front);
      if (typeof window.__cfAdvance === 'function') {
        const advance = window.__cfAdvance;
        window.__cfAdvance = (ms) => { const now = advance(ms); draw(); return now; };
      } else {
        const loop = () => { draw(); window.requestAnimationFrame(loop); };
        window.requestAnimationFrame(loop);
      }
      // The runtime flips ready once its first frame has painted; draw that
      // frame's bands too, before the capture takes frame 0.
      let ready = window.__cfDiagramReady;
      Object.defineProperty(window, '__cfDiagramReady', { configurable: true, get: () => ready, set: (v) => { ready = v; if (v) draw(); } });
    }
  };
})();
