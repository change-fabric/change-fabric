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
// - Node sizes are fixed constants, so layout and camera targets never depend
//   on a ResizeObserver measurement.
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
  const { React, createRoot, flushSync, ReactFlow, ReactFlowProvider, useReactFlow, useNodesInitialized, Handle, Position, MarkerType, dagre } = X;
  const h = React.createElement;
  const spec = JSON.parse(document.getElementById('cf-diagram').textContent);

  const NODE_W = 180;
  const NODE_H = 56;
  const FADE_MS = 300;
  const PULSE_MS = 800;
  const MIN_ZOOM = 0.2;
  const MAX_ZOOM = 3;
  const DIRS = { TB: [Position.Top, Position.Bottom], BT: [Position.Bottom, Position.Top], LR: [Position.Left, Position.Right], RL: [Position.Right, Position.Left] };

  const style = document.createElement('style');
  style.textContent = `${X.css}
html, body, #cf-diagram-root { margin: 0; width: 100%; height: 100%; }
.react-flow { --xy-background-color: var(--cf-surface, #ffffff); background: var(--cf-surface, #ffffff); }
.cf-node { box-sizing: border-box; width: ${NODE_W}px; height: ${NODE_H}px; display: flex; align-items: center; justify-content: center;
  padding: 0 12px; border: 2px solid var(--cf-line, #94a3b8); border-radius: 10px; background: var(--cf-node, #f8fafc);
  color: var(--cf-text, #0f172a); font: 600 16px/1.2 system-ui, sans-serif; text-align: center; }
.cf-node[data-role="accent"] { border-color: var(--cf-accent, #2563eb); background: var(--cf-accent-tint, #dbeafe); }
.cf-node .react-flow__handle { opacity: 0; pointer-events: none; }
.react-flow__node[data-cf-hl="1"] .cf-node { border-color: var(--cf-accent, #2563eb); box-shadow: 0 0 0 4px var(--cf-accent-tint, #dbeafe); }
.react-flow__node[data-cf-dim="1"] { filter: saturate(0.2); }
.react-flow__edge-path { stroke: var(--cf-line, #94a3b8); stroke-width: 2; }
.react-flow__edge[data-cf-hl="1"] .react-flow__edge-path { stroke: var(--cf-accent, #2563eb); stroke-width: 3; }
.react-flow__edge-text { fill: var(--cf-text, #0f172a); font: 500 13px system-ui, sans-serif; }
`;
  document.head.appendChild(style);

  const nodeIds = spec.nodes.map((n) => n.id);
  const edgeIds = spec.edges.map((e) => e.id);
  const steps = (spec.steps || []).slice().sort((a, b) => a.t_ms - b.t_ms);
  const direction = (spec.layout && spec.layout.direction) || 'LR';
  const [targetPos, sourcePos] = DIRS[direction] || DIRS.LR;

  // Base positions: a pinned node keeps its position; under dagre the rest
  // come from one layout of the full node set, so add_node never reflows.
  const basePositions = () => {
    const out = {};
    const engine = (spec.layout && spec.layout.engine) || 'dagre';
    if (engine === 'dagre') {
      const g = new dagre.graphlib.Graph();
      g.setGraph({ rankdir: direction, nodesep: 60, ranksep: 120, marginx: 0, marginy: 0 });
      g.setDefaultEdgeLabel(() => ({}));
      for (const n of spec.nodes) g.setNode(n.id, { width: NODE_W, height: NODE_H });
      for (const e of spec.edges) g.setEdge(e.source, e.target);
      dagre.layout(g);
      for (const id of nodeIds) { const p = g.node(id); out[id] = { x: Math.round(p.x - NODE_W / 2), y: Math.round(p.y - NODE_H / 2) }; }
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
    return { opacity, hl, dim, labels, pulses, positions, viewport: cameraAt(t, camera, shownAt, positionAt, viewportSize) };
  };

  const fitTarget = (ids, padding, at, positionAt, size) => {
    if (ids.length === 0) return null;
    let x0 = Infinity; let y0 = Infinity; let x1 = -Infinity; let y1 = -Infinity;
    for (const id of ids) {
      const p = positionAt(id, at);
      x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y); x1 = Math.max(x1, p.x + NODE_W); y1 = Math.max(y1, p.y + NODE_H);
    }
    const w = x1 - x0; const hgt = y1 - y0;
    const zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, Math.min(size.w / (w * (1 + 2 * padding)), size.h / (hgt * (1 + 2 * padding)))));
    return { x: size.w / 2 - (x0 + w / 2) * zoom, y: size.h / 2 - (y0 + hgt / 2) * zoom, zoom };
  };

  const visibleAt = (shownAt, at) => nodeIds.filter((id) => id in shownAt && shownAt[id] <= at);

  // Folds every camera step up to t: each one tweens from wherever the
  // camera was when it started toward its own target.
  const cameraAt = (t, camera, shownAt, positionAt, size) => {
    let cur = fitTarget(visibleAt(shownAt, 0).length ? visibleAt(shownAt, 0) : nodeIds, 0.2, 0, positionAt, size);
    camera.forEach((s, i) => {
      const next = camera[i + 1];
      const end = next && next.t_ms <= t ? next.t_ms : t;
      let target = null;
      if (s.op === 'fit_view') {
        const ids = s.ids || visibleAt(shownAt, s.t_ms);
        target = fitTarget(ids.length ? ids : nodeIds, s.padding == null ? 0.2 : s.padding, s.t_ms, positionAt, size);
      } else if (s.op === 'zoom_to') {
        const zoom = s.zoom;
        const cx = (size.w / 2 - cur.x) / cur.zoom; const cy = (size.h / 2 - cur.y) / cur.zoom;
        target = { x: size.w / 2 - cx * zoom, y: size.h / 2 - cy * zoom, zoom };
      } else if (s.op === 'focus') {
        const p = positionAt(s.id, s.t_ms);
        const zoom = s.zoom || cur.zoom;
        target = { x: size.w / 2 - (p.x + NODE_W / 2) * zoom, y: size.h / 2 - (p.y + NODE_H / 2) * zoom, zoom };
      }
      if (!target) return;
      const p = progress(end, s.t_ms, s.duration || 0);
      cur = { x: lerp(cur.x, target.x, p), y: lerp(cur.y, target.y, p), zoom: lerp(cur.zoom, target.zoom, p) };
    });
    return cur;
  };

  const CfNode = ({ data }) => h('div', { className: 'cf-node', 'data-role': data.role || 'default' },
    h(Handle, { type: 'target', position: targetPos, isConnectable: false }),
    h('span', { className: 'cf-node-label' }, data.label),
    h(Handle, { type: 'source', position: sourcePos, isConnectable: false }));
  const nodeTypes = { cf: CfNode };

  const toNodes = (positions) => spec.nodes.map((n) => ({
    id: n.id, type: 'cf', position: positions[n.id], width: NODE_W, height: NODE_H,
    data: { label: n.label, role: n.role }, draggable: false, selectable: false, connectable: false
  }));
  const initialEdges = spec.edges.map((e) => ({
    id: e.id, source: e.source, target: e.target, label: e.label, selectable: false, focusable: false,
    markerEnd: { type: MarkerType.ArrowClosed, width: 18, height: 18 }
  }));

  const live = { rf: null, setNodes: null, positions: BASE, container: null };

  const sizeOf = () => ({ w: live.container.clientWidth, h: live.container.clientHeight });

  const samePositions = (a, b) => nodeIds.every((id) => a[id].x === b[id].x && a[id].y === b[id].y);

  const apply = () => {
    if (!live.rf) return;
    const t = performance.now();
    const s = derive(t, sizeOf());
    flushSync(() => {
      if (!samePositions(s.positions, live.positions)) { live.positions = s.positions; live.setNodes(toNodes(s.positions)); }
      live.rf.setViewport(s.viewport, { duration: 0 });
    });
    for (const id of nodeIds) {
      const el = live.container.querySelector(`.react-flow__node[data-id="${CSS.escape(id)}"]`);
      if (!el) continue;
      el.style.opacity = String(s.opacity(id));
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
      if (s.dim.has(id)) o *= 0.35;
      el.style.opacity = String(o);
      const pulse = s.pulses[id];
      const on = pulse && t < pulse.start + pulse.duration;
      el.dataset.cfHl = s.hl.has(id) || on ? '1' : '0';
      const path = el.querySelector('.react-flow__edge-path');
      if (path) path.style.strokeWidth = on ? String(3 + 3 * Math.sin(Math.PI * clamp01((t - pulse.start) / pulse.duration))) : '';
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
    live.setNodes = setNodes;
    return h(ReactFlow, {
      nodes, edges: initialEdges, nodeTypes,
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

  const mount = () => {
    live.container = document.getElementById('cf-diagram-root');
    status('rendering');
    createRoot(live.container).render(h(ReactFlowProvider, null, h(Diagram)));
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount); else mount();
})();
