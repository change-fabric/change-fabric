// cf:walkthrough diagram runtime. A classic script loaded after the vendored
// xyflow bundle (window.CfXyflow). It reads the scene spec from
// <script type="application/json" id="cf-diagram">, mounts React Flow once
// with every declared node and edge, and from then on derives the whole
// picture as a pure function of the capture clock.
//
// Determinism rules this file keeps:
// - React renders the node and edge set once. Per-frame state (visibility,
//   highlight, dim, pulse, label text) is written straight to the DOM as data
//   attributes and inline styles, so no frame waits on a React scheduler
//   task (MessageChannel runs on real time, not the fixed clock).
// - The camera never uses d3 transitions. Each frame computes the viewport
//   by folding the camera steps up to `now` and sets it with duration 0
//   inside flushSync.
// - Node sizes come from the spec alone (width from the longest label a node
//   ever shows, by character count; height fixed), so layout and camera
//   targets never depend on a ResizeObserver or text measurement.
// - Arrowheads are the runtime's own markers in user space units, swapped
//   per frame by colour, so they follow highlight and never scale with the
//   stroke width.
// - Handle sides come from the relative node positions at each frame.
//   Handles sit just outside the node border: an edge fading in under a
//   border's antialiased column rasterized differently between captures.
// - window.__cfDiagramReady turns true only once React Flow reports its nodes
//   initialized and two real frames have painted; the capture waits on it
//   before frame 0.
// - The state is applied right after every window.__cfAdvance, so a frame
//   shows exactly the state at its own virtual time.
(() => {
  window.__cfDiagramReady = false;
  // A breadcrumb the capture reports when the screen never gets ready.
  const status = (msg) => { window.__cfDiagramStatus = msg; };
  status('loading');
  const X = window.CfXyflow;
  const { React, createRoot, flushSync, ReactFlow, ReactFlowProvider, useReactFlow, useNodesInitialized, Handle, Position, dagre } = X;
  const h = React.createElement;
  const spec = JSON.parse(document.getElementById('cf-diagram').textContent);
  // The generator's frame: how much of the viewport bottom the caption band
  // takes. Camera targets are fitted and centred in the area above it.
  const frameEl = document.getElementById('cf-diagram-frame');
  const BOTTOM_INSET = (frameEl && JSON.parse(frameEl.textContent).bottom_inset) || 0;
  // Item colours the generator resolved from the theme ({ color, tint, ring }
  // hexes keyed by node id, edge id, and flow step index). A screen with no
  // coloured item has no such script and draws exactly as before.
  const colorsEl = document.getElementById('cf-diagram-colors');
  const COLORS = colorsEl ? JSON.parse(colorsEl.textContent) : { nodes: {}, edges: {}, steps: {} };

  const NODE_H = 56;
  const NODE_MIN_W = 140;
  const NODE_MAX_W = 260;
  const CHAR_W = 11;
  const NODE_PAD_W = 40;
  const DIM_OPACITY = 0.35;
  const FIT_MAX_ZOOM = 1.25;
  const FOCUS_MAX_ZOOM = 1.5;
  const FADE_MS = 300;
  const PULSE_MS = 800;
  const FLOW_MS = 1200;
  const FLOW_COUNT = 3;
  const FLOW_FADE_MS = 120;
  const FLOW_R = 4;
  const FLOW_HALO_R = 9;
  const MIN_ZOOM = 0.2;
  const MAX_ZOOM = 3;
  const NODE_SEP = 60;
  const RANK_SEP = 120;

  const style = document.createElement('style');
  style.textContent = `${X.css}
html, body, #cf-diagram-root { margin: 0; width: 100%; height: 100%; }
.react-flow { --xy-background-color: var(--cf-surface, #ffffff); background: var(--cf-surface, #ffffff); }
.cf-node { box-sizing: border-box; height: ${NODE_H}px; display: flex; align-items: center; justify-content: center;
  padding: 0 12px; border: 2px solid var(--cf-line, #94a3b8); border-radius: 10px; background: var(--cf-node, #f8fafc);
  color: var(--cf-text, #0f172a); font: 600 16px/1.2 system-ui, sans-serif; text-align: center; }
.cf-node[data-role="accent"] { border-color: var(--cf-accent, #2563eb); background: var(--cf-accent-tint, #dbeafe); }
.cf-node[data-role="muted"] { border-color: var(--cf-rule, #cbd5e1); background: var(--cf-surface, #ffffff); color: var(--cf-muted, #475569); }
.cf-node .react-flow__handle { visibility: hidden; pointer-events: none; }
.cf-node .react-flow__handle-right { right: -4px; } .cf-node .react-flow__handle-left { left: -4px; }
.cf-node .react-flow__handle-top { top: -4px; } .cf-node .react-flow__handle-bottom { bottom: -4px; }
.react-flow__node[data-cf-hl="1"] .cf-node { border-color: var(--cf-accent, #2563eb); box-shadow: 0 0 0 4px var(--cf-accent-tint, #dbeafe); }
.react-flow__edge-path { stroke: var(--cf-line, #94a3b8); stroke-width: 2; }
.react-flow__edge[data-cf-hl="1"] .react-flow__edge-path { stroke: var(--cf-accent, #2563eb); stroke-width: 3; }
.cf-flow-halo { fill: var(--cf-accent-tint, #dbeafe); fill-opacity: 0.85; stroke: var(--cf-accent, #2563eb); stroke-opacity: 0.25; stroke-width: 1; }
.cf-flow-core { fill: var(--cf-accent, #2563eb); stroke: var(--cf-surface, #ffffff); stroke-width: 1.5; }
.cf-node[data-color] { border-color: var(--cf-item); background: var(--cf-item-tint); color: var(--cf-text, #0f172a); }
.react-flow__node[data-cf-hl="1"] .cf-node[data-color] { border-color: var(--cf-item); box-shadow: 0 0 0 4px var(--cf-item-ring); }
.react-flow__edge.cf-colored .react-flow__edge-path { stroke: var(--cf-item); }
.react-flow__edge.cf-colored[data-cf-hl="1"] .react-flow__edge-path { stroke: var(--cf-item); stroke-width: 3; }
.react-flow__edge-text { fill: var(--cf-text, #0f172a); font: 500 13px system-ui, sans-serif; }
.react-flow__edge-textbg { fill: var(--cf-surface, #ffffff); }
`;
  document.head.appendChild(style);

  // Two fixed-size arrowheads, one per edge colour. Dimmed edges fade the
  // default one with the edge's own opacity.
  const MARKER = { base: 'cf-arrow', hl: 'cf-arrow-hl' };
  const markerDef = (id, color) => `<marker id="${id}" viewBox="0 0 12 12" markerWidth="12" markerHeight="12" markerUnits="userSpaceOnUse" refX="11" refY="6" orient="auto-start-reverse"><path d="M0,0 L12,6 L0,12 z" style="fill: ${color}"/></marker>`;
  const defs = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  defs.setAttribute('width', '0'); defs.setAttribute('height', '0'); defs.setAttribute('aria-hidden', 'true');
  defs.style.position = 'absolute';
  // A coloured edge wears an arrowhead of its own colour in every state.
  const itemColors = [...new Set(Object.values(COLORS.edges).map((c) => c.color))];
  const markerFor = (color) => `cf-arrow-c${itemColors.indexOf(color)}`;
  defs.innerHTML = `<defs>${markerDef(MARKER.base, 'var(--cf-line, #94a3b8)')}${markerDef(MARKER.hl, 'var(--cf-accent, #2563eb)')}${itemColors.map((c) => markerDef(markerFor(c), c)).join('')}</defs>`;

  const nodeIds = spec.nodes.map((n) => n.id);
  const edgeIds = spec.edges.map((e) => e.id);
  // Each step keeps its spec index, which keys a flow step's colour.
  const steps = (spec.steps || []).map((s, i) => Object.assign({}, s, { index: i })).sort((a, b) => a.t_ms - b.t_ms);
  const direction = (spec.layout && spec.layout.direction) || 'LR';

  // Width from the longest text the node ever shows, by character count, so
  // a relabel never reflows and no measurement is needed.
  const WIDTH = Object.fromEntries(spec.nodes.map((n) => {
    const texts = [n.label || ''].concat(steps.filter((s) => s.op === 'label' && s.id === n.id).map((s) => s.text || ''));
    const chars = Math.max(...texts.map((x) => x.length));
    const w = Math.min(NODE_MAX_W, Math.max(NODE_MIN_W, chars * CHAR_W + NODE_PAD_W));
    return [n.id, Math.round(w / 2) * 2];
  }));
  const isLR = direction === 'LR' || direction === 'RL';

  // Base positions: a pinned node keeps its position; under dagre the rest
  // come from one layout of the full node set, so add_node never reflows.
  const basePositions = () => {
    const out = {};
    const engine = (spec.layout && spec.layout.engine) || 'dagre';
    if (engine === 'dagre') {
      const g = new dagre.graphlib.Graph();
      g.setGraph({ rankdir: direction, nodesep: NODE_SEP, ranksep: RANK_SEP, marginx: 0, marginy: 0 });
      g.setDefaultEdgeLabel(() => ({}));
      for (const n of spec.nodes) g.setNode(n.id, { width: WIDTH[n.id], height: NODE_H });
      for (const e of spec.edges) g.setEdge(e.source, e.target);
      dagre.layout(g);
      // dagre may order a rank's nodes against the spec; reassign each rank's
      // cross-axis slots in spec order so parallel lanes read as written.
      const ranks = new Map();
      for (const id of nodeIds) {
        const p = g.node(id);
        const key = Math.round(isLR ? p.x : p.y);
        if (!ranks.has(key)) ranks.set(key, []);
        ranks.get(key).push(id);
      }
      for (const ids of ranks.values()) {
        const slots = ids.map((id) => (isLR ? g.node(id).y : g.node(id).x)).sort((a, b) => a - b);
        ids.forEach((id, i) => { if (isLR) g.node(id).y = slots[i]; else g.node(id).x = slots[i]; });
      }
      for (const id of nodeIds) { const p = g.node(id); out[id] = { x: Math.round(p.x - WIDTH[id] / 2), y: Math.round(p.y - NODE_H / 2) }; }
    }
    for (const n of spec.nodes) if (n.position) out[n.id] = { x: n.position.x, y: n.position.y };
    for (const id of nodeIds) if (!out[id]) out[id] = { x: 0, y: 0 };
    return out;
  };
  const BASE = basePositions();

  const clamp01 = (v) => Math.min(1, Math.max(0, v));
  const ease = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
  const lerp = (a, b, p) => a + (b - a) * p;
  const progress = (t, start, duration) => (duration > 0 ? ease(clamp01((t - start) / duration)) : (t >= start ? 1 : 0));

  // The scene state at time t, replayed from the spec. Pure: the same t
  // always gives the same state, whatever frames came before.
  const derive = (t, viewportSize) => {
    const shownAt = {};
    for (const id of spec.initial || []) shownAt[id] = -Infinity;
    const removedAt = {};
    const hl = new Set();
    const dim = new Set();
    const labels = {};
    const pulses = {};
    const flows = {};
    const moves = {};
    const camera = [];
    for (const s of steps) {
      if (s.t_ms > t) break;
      const ids = s.ids || (s.id ? [s.id] : []);
      switch (s.op) {
        case 'add_node':
        case 'connect':
          for (const id of ids) { shownAt[id] = s.t_ms; delete removedAt[id]; }
          break;
        case 'remove':
          for (const id of ids) removedAt[id] = s.t_ms;
          break;
        case 'highlight': for (const id of ids) { hl.add(id); dim.delete(id); } break;
        case 'dim': for (const id of ids) { dim.add(id); hl.delete(id); } break;
        case 'unhighlight': for (const id of ids) { hl.delete(id); dim.delete(id); } break;
        case 'label': labels[s.id] = s.text; break;
        case 'pulse_edge': for (const id of ids) pulses[id] = { start: s.t_ms, duration: s.duration || PULSE_MS }; break;
        case 'flow': for (const id of ids) flows[id] = (flows[id] || []).concat([s]); break;
        case 'move': moves[s.id] = (moves[s.id] || []).concat([s]); break;
        default: camera.push(s);
      }
    }
    const opacity = (id) => {
      let o = id in shownAt ? clamp01((t - shownAt[id]) / FADE_MS) : 0;
      if (id in removedAt) o = Math.min(o, 1 - clamp01((t - removedAt[id]) / FADE_MS));
      return o;
    };
    const positionAt = (id, at) => {
      let pos = BASE[id];
      for (const m of moves[id] || []) {
        if (m.t_ms > at) break;
        const p = progress(at, m.t_ms, m.duration || 0);
        pos = { x: lerp(pos.x, m.position.x, p), y: lerp(pos.y, m.position.y, p) };
      }
      return pos;
    };
    const positions = Object.fromEntries(nodeIds.map((id) => [id, positionAt(id, t)]));
    return { opacity, hl, dim, labels, pulses, flows, positions, viewport: cameraAt(t, camera, positionAt, viewportSize) };
  };

  const fitTarget = (ids, padding, at, positionAt, size, maxZoom = FIT_MAX_ZOOM) => {
    if (ids.length === 0) return null;
    let x0 = Infinity; let y0 = Infinity; let x1 = -Infinity; let y1 = -Infinity;
    for (const id of ids) {
      const p = positionAt(id, at);
      x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x + WIDTH[id]); y1 = Math.max(y1, p.y + NODE_H);
    }
    const w = x1 - x0; const hgt = y1 - y0;
    const zoom = Math.min(maxZoom, Math.max(MIN_ZOOM, Math.min(size.w / (w * (1 + 2 * padding)), size.h / (hgt * (1 + 2 * padding)))));
    return { x: size.w / 2 - (x0 + w / 2) * zoom, y: size.h / 2 - (y0 + hgt / 2) * zoom, zoom };
  };

  // The nodes on screen at time `at`, replayed from the whole spec, so a
  // camera step can aim at where its own tween ends.
  const visibleAt = (at) => {
    const on = new Set(spec.initial || []);
    for (const s of steps) {
      if (s.t_ms > at) break;
      const ids = s.ids || (s.id ? [s.id] : []);
      if (s.op === 'add_node' || s.op === 'connect') for (const id of ids) on.add(id);
      else if (s.op === 'remove') for (const id of ids) on.delete(id);
    }
    return nodeIds.filter((id) => on.has(id));
  };

  // Folds every camera step up to t: each one tweens from wherever the
  // camera was when it started toward its own target.
  const cameraAt = (t, camera, positionAt, viewport) => {
    const size = { w: viewport.w, h: Math.max(1, viewport.h - BOTTOM_INSET) };
    const first = visibleAt(0);
    let cur = fitTarget(first.length ? first : nodeIds, 0.2, 0, positionAt, size);
    camera.forEach((s, i) => {
      const next = camera[i + 1];
      const end = next && next.t_ms <= t ? next.t_ms : t;
      let target = null;
      if (s.op === 'fit_view') {
        const endAt = s.t_ms + (s.duration || 0);
        const ids = s.ids || visibleAt(endAt);
        target = fitTarget(ids.length ? ids : nodeIds, s.padding == null ? 0.2 : s.padding, endAt, positionAt, size);
      } else if (s.op === 'zoom_to') {
        const zoom = s.zoom;
        const cx = (size.w / 2 - cur.x) / cur.zoom; const cy = (size.h / 2 - cur.y) / cur.zoom;
        target = { x: size.w / 2 - cx * zoom, y: size.h / 2 - cy * zoom, zoom };
      } else if (s.op === 'focus') {
        const p = positionAt(s.id, s.t_ms);
        const zoom = Math.min(FOCUS_MAX_ZOOM, Math.max(MIN_ZOOM, s.zoom || cur.zoom));
        target = { x: size.w / 2 - (p.x + WIDTH[s.id] / 2) * zoom, y: size.h / 2 - (p.y + NODE_H / 2) * zoom, zoom };
      }
      if (!target) return;
      const p = progress(end, s.t_ms, s.duration || 0);
      cur = { x: lerp(cur.x, target.x, p), y: lerp(cur.y, target.y, p), zoom: lerp(cur.zoom, target.zoom, p) };
    });
    return cur;
  };

  // Every node carries a source and a target handle on each side; each edge
  // picks its sides from where the two nodes sit.
  const SIDES = { left: Position.Left, right: Position.Right, top: Position.Top, bottom: Position.Bottom };
  const nodeStyle = (id) => {
    const c = COLORS.nodes[id];
    const style = { width: `${WIDTH[id]}px` };
    return c ? Object.assign(style, { '--cf-item': c.color, '--cf-item-tint': c.tint, '--cf-item-ring': c.ring }) : style;
  };
  const CfNode = ({ id, data }) => h('div', { className: 'cf-node', 'data-role': data.role || 'default', 'data-color': COLORS.nodes[id] ? '1' : undefined, style: nodeStyle(id) },
    ...Object.entries(SIDES).flatMap(([side, position]) => [
      h(Handle, { key: `t-${side}`, id: `t-${side}`, type: 'target', position, isConnectable: false }),
      h(Handle, { key: `s-${side}`, id: `s-${side}`, type: 'source', position, isConnectable: false })
    ]),
    h('span', { className: 'cf-node-label' }, data.label));
  const nodeTypes = { cf: CfNode };

  // Left/right sides when the nodes leave room for an arrow between them and
  // are not steeply stacked; otherwise top/bottom.
  const sidesFor = (e, positions) => {
    const a = positions[e.source]; const b = positions[e.target];
    const dx = (b.x + WIDTH[e.target] / 2) - (a.x + WIDTH[e.source] / 2);
    const dy = (b.y + NODE_H / 2) - (a.y + NODE_H / 2);
    const gapX = Math.abs(dx) - (WIDTH[e.source] + WIDTH[e.target]) / 2;
    if (gapX < 24 || Math.abs(dy) > 2 * Math.abs(dx)) return dy >= 0 ? ['bottom', 'top'] : ['top', 'bottom'];
    return dx >= 0 ? ['right', 'left'] : ['left', 'right'];
  };

  const toNodes = (positions) => spec.nodes.map((n) => ({
    id: n.id, type: 'cf', position: positions[n.id], width: WIDTH[n.id], height: NODE_H,
    data: { label: n.label, role: n.role }, draggable: false, selectable: false, connectable: false
  }));
  const toEdges = (positions) => spec.edges.map((e) => {
    const [from, to] = sidesFor(e, positions);
    return {
      id: e.id, source: e.source, target: e.target, sourceHandle: `s-${from}`, targetHandle: `t-${to}`,
      label: e.label, selectable: false, focusable: false,
      labelShowBg: true, labelBgPadding: [8, 4], labelBgBorderRadius: 4,
      ...(COLORS.edges[e.id] ? { className: 'cf-colored', style: { '--cf-item': COLORS.edges[e.id].color } } : {})
    };
  });

  // A flow step's dots at time t: each dot i starts stagger*i after the
  // step, glides source to target over `duration` with eased progress, and
  // the batch repeats `repeat` times, or for the rest of the scene on loop.
  // Pure in t, like everything else: a dot's place comes from the clock.
  const flowDots = (s, t) => {
    const duration = s.duration || FLOW_MS;
    const count = s.count || FLOW_COUNT;
    const stagger = s.stagger == null ? Math.round(duration / count) : s.stagger;
    const period = duration + (count - 1) * stagger;
    const runs = s.loop ? Infinity : (s.repeat || 1);
    const dots = [];
    for (let i = 0; i < count; i += 1) {
      const since = t - s.t_ms - i * stagger;
      if (since < 0) continue;
      const run = Math.floor(since / period);
      if (run >= runs) continue;
      const local = since - run * period;
      if (local >= duration) continue;
      const alpha = clamp01(Math.min(local, duration - local) / FLOW_FADE_MS);
      dots.push({ p: ease(local / duration), alpha, color: COLORS.steps[String(s.index)] });
    }
    return dots;
  };

  // The dots ride in the edge's own group, so they share its viewport
  // transform and opacity, and are placed along the path React Flow drew
  // for this frame, so they follow the edge when a node moves.
  const SVG_NS = 'http://www.w3.org/2000/svg';
  const dotPaint = (dot, c) => {
    const [halo, core] = dot.childNodes;
    const want = c ? [`fill: ${c.tint}; stroke: ${c.color}`, `fill: ${c.color}`] : ['', ''];
    if (halo.getAttribute('style') !== want[0]) { if (want[0]) halo.setAttribute('style', want[0]); else halo.removeAttribute('style'); }
    if (core.getAttribute('style') !== want[1]) { if (want[1]) core.setAttribute('style', want[1]); else core.removeAttribute('style'); }
  };
  const drawFlow = (el, path, steps, t, edgeColor) => {
    let g = el.querySelector(':scope > g.cf-flow');
    const dots = path ? (steps || []).flatMap((s) => flowDots(s, t)) : [];
    if (dots.length === 0) { if (g) g.remove(); return; }
    if (!g) { g = document.createElementNS(SVG_NS, 'g'); g.setAttribute('class', 'cf-flow'); g.setAttribute('aria-hidden', 'true'); el.appendChild(g); }
    while (g.childNodes.length > dots.length) g.lastChild.remove();
    while (g.childNodes.length < dots.length) {
      const dot = document.createElementNS(SVG_NS, 'g');
      const halo = document.createElementNS(SVG_NS, 'circle'); halo.setAttribute('class', 'cf-flow-halo'); halo.setAttribute('r', String(FLOW_HALO_R));
      const core = document.createElementNS(SVG_NS, 'circle'); core.setAttribute('class', 'cf-flow-core'); core.setAttribute('r', String(FLOW_R));
      dot.append(halo, core);
      g.appendChild(dot);
    }
    const length = path.getTotalLength();
    dots.forEach((d, i) => {
      const pt = path.getPointAtLength(d.p * length);
      const dot = g.childNodes[i];
      dot.setAttribute('transform', `translate(${pt.x.toFixed(2)} ${pt.y.toFixed(2)})`);
      dot.setAttribute('opacity', d.alpha.toFixed(3));
      dotPaint(dot, d.color || edgeColor);
    });
  };

  const live = { rf: null, setNodes: null, setEdges: null, positions: BASE, container: null };

  const sizeOf = () => ({ w: live.container.clientWidth, h: live.container.clientHeight });

  const samePositions = (a, b) => nodeIds.every((id) => a[id].x === b[id].x && a[id].y === b[id].y);

  const apply = () => {
    if (!live.rf) return;
    const t = performance.now();
    const s = derive(t, sizeOf());
    flushSync(() => {
      if (!samePositions(s.positions, live.positions)) { live.positions = s.positions; live.setNodes(toNodes(s.positions)); live.setEdges(toEdges(s.positions)); }
      live.rf.setViewport(s.viewport, { duration: 0 });
    });
    for (const id of nodeIds) {
      const el = live.container.querySelector(`.react-flow__node[data-id="${CSS.escape(id)}"]`);
      if (!el) continue;
      el.style.opacity = String(s.opacity(id) * (s.dim.has(id) ? DIM_OPACITY : 1));
      el.dataset.cfHl = s.hl.has(id) ? '1' : '0';
      el.dataset.cfDim = s.dim.has(id) ? '1' : '0';
      const label = el.querySelector('.cf-node-label');
      const text = id in s.labels ? s.labels[id] : spec.nodes.find((n) => n.id === id).label;
      if (label && label.textContent !== text) label.textContent = text;
    }
    for (const id of edgeIds) {
      const el = live.container.querySelector(`.react-flow__edge[data-id="${CSS.escape(id)}"]`);
      if (!el) continue;
      let o = s.opacity(id);
      if (s.dim.has(id)) o *= DIM_OPACITY;
      el.style.opacity = String(o);
      const pulse = s.pulses[id];
      const on = pulse && t < pulse.start + pulse.duration;
      el.dataset.cfHl = s.hl.has(id) || on ? '1' : '0';
      const path = el.querySelector('.react-flow__edge-path');
      // Only touch the attribute on a change, so a frame repaints nothing new.
      const own = COLORS.edges[id];
      const marker = `url(#${own ? markerFor(own.color) : el.dataset.cfHl === '1' ? MARKER.hl : MARKER.base})`;
      if (path && path.getAttribute('marker-end') !== marker) path.setAttribute('marker-end', marker);
      if (path) path.style.strokeWidth = on ? String(3 + 3 * Math.sin(Math.PI * clamp01((t - pulse.start) / pulse.duration))) : '';
      drawFlow(el, path, s.flows[id], t, own);
    }
  };

  const raf = window.__cfRealRaf || window.requestAnimationFrame.bind(window);

  const Ready = () => {
    const rf = useReactFlow();
    const initialized = useNodesInitialized({ includeHiddenNodes: true });
    status(initialized ? 'nodes initialized' : 'mounted, waiting for node measurement');
    React.useEffect(() => {
      if (!initialized || live.rf) return;
      live.rf = rf;
      apply();
      status('waiting for two painted frames');
      raf(() => raf(() => { apply(); status('ready'); window.__cfDiagramReady = true; }));
    }, [initialized, rf]);
    return null;
  };

  const Diagram = () => {
    const [nodes, setNodes] = React.useState(() => toNodes(BASE));
    const [edges, setEdges] = React.useState(() => toEdges(BASE));
    live.setNodes = setNodes;
    live.setEdges = setEdges;
    return h(ReactFlow, {
      nodes, edges, nodeTypes,
      proOptions: { hideAttribution: true },
      nodesDraggable: false, nodesConnectable: false, elementsSelectable: false,
      panOnDrag: false, zoomOnScroll: false, zoomOnPinch: false, zoomOnDoubleClick: false, panOnScroll: false,
      preventScrolling: true, minZoom: MIN_ZOOM, maxZoom: MAX_ZOOM, onlyRenderVisibleElements: false
    }, h(Ready));
  };

  // Every advance of the capture clock re-derives the frame at its new time.
  if (typeof window.__cfAdvance === 'function') {
    const advance = window.__cfAdvance;
    window.__cfAdvance = (ms) => { const now = advance(ms); apply(); return now; };
  } else {
    const loop = () => { apply(); window.requestAnimationFrame(loop); };
    window.requestAnimationFrame(loop);
  }

  // React Flow remounts an edge's element once a move has it re-measure
  // the nodes, which lands after the frame's apply and drops what apply
  // wrote onto it (arrowhead colour, flow dots). Re-applying the same
  // virtual time when an edge element appears restores it before the frame
  // is captured; apply is pure in t, so the result is the same either way.
  const isEdge = (n) => n.nodeType === 1 && (n.classList.contains('react-flow__edge') || n.querySelector('.react-flow__edge'));
  const watchEdges = () => new MutationObserver((records) => {
    if (records.some((r) => [...r.addedNodes].some(isEdge))) apply();
  }).observe(live.container, { childList: true, subtree: true });

  const mount = () => {
    live.container = document.getElementById('cf-diagram-root');
    document.body.appendChild(defs);
    watchEdges();
    status('rendering');
    createRoot(live.container).render(h(ReactFlowProvider, null, h(Diagram)));
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount); else mount();
})();
