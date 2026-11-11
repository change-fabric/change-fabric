// cf:walkthrough diagram swimlanes. A classic script the generator inlines
// only into a screen whose spec declares `lanes`, between the xyflow bundle
// and cf_diagram_runtime.js, so a screen without lanes keeps its bytes and
// the runtime itself never learns about lanes.
//
// It works in two halves:
// - prepare (runs at load, before the runtime parses the spec): computes one
//   layout record (computeLayout: every node box, band, lane name, rail,
//   token, report row, and the camera bounds), places each laned node inside
//   its band (above the band's travel rail when anything travels), and pins
//   every node to its box, size included. Everything drawn later reads the
//   record; nothing sizes itself at draw time.
//   A node a `travel` carries (its token) or delivers (its `result`) is owned
//   by this layer: the runtime keeps it hidden, and each travel step becomes
//   an empty add_node in place, so step indices (which key flow colours)
//   hold and the runtime's camera fold never sees an op it does not aim.
// - attach (called by a one-line script after the runtime): draws the bands,
//   labels and separators behind the diagram, and the tokens, result chips,
//   and result cards in front of it, and pulses each checkpoint the token
//   passes, all as a pure function of the capture clock after every
//   __cfAdvance the runtime has already wrapped. No CSS or SMIL animation.
//
// One travel, anchored on its t_ms (t0) and duration D:
//   t0 - ENTER_MS .. t0     the token reveals at the lane's entry, sliding
//                           ENTER_SHIFT right as it fades in; the lane lights.
//   t0 .. t0 + D            it rides the rail under the checkpoints with the
//                           step's easing; each checkpoint pulses as it passes.
//   t0 + D - CHIP_IN_MS     a result chip appears at the token's exit,
//   t0 + D + TAIL_MS        and transfers to its report slot over TRANSFER_MS;
//   landing                 the result card drops DROP_SHIFT into its slot and
//                           the lane's light fades over HL_OUT_MS.
//   next entrance           the token fades out drifting EXIT_SHIFT right,
//                           starting EXIT_LEAD before the next lane's reveal,
//                           so the two overlap and nothing slides back.
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
  const colorsEl = document.getElementById('cf-diagram-colors');
  const COLORS = colorsEl ? JSON.parse(colorsEl.textContent) : { nodes: {} };
  // An own-property read: an authored id such as `constructor` must not
  // find Object.prototype.
  const colorOf = (id) => (Object.hasOwn(COLORS.nodes, id) ? COLORS.nodes[id] : null);

  const NODE_H = 56;
  const NODE_MIN_W = 140;
  const NODE_MAX_W = 260;
  const CHAR_W = 11;
  const NODE_PAD_W = 40;
  const ICON_PX = 20;
  const ICON_GAP = 8;
  const NODE_SEP = 60;
  // A node's horizontal padding plus border, and its border, as the
  // runtime's .cf-node draws them.
  const NODE_PAD_X = 28;
  const NODE_BORDER = 2;
  // Invisible camera anchors are this many units square.
  const ANCHOR_PX = 2;
  const RANK_SEP = 120;
  const FADE_MS = 300;
  const DIM_OPACITY = 0.35;
  const LANE_PAD = 12;
  const ROW_GAP = 24;
  const LANE_MIN = 120;
  // A travel rides a rail RAIL_GAP under its band's checkpoints.
  const RAIL_GAP = 8;
  const CLEAR = 16;
  // Sized to stay legible when a 1280 wide frame plays on a phone.
  const TOKEN_H = 32;
  const TOKEN_CHAR_W = 9.6;
  const TOKEN_PAD_W = 28;
  const TOKEN_ICON = 16;
  // Horizontal lanes: every checkpoint takes one width, so a column of them
  // reads as a column, and lane names sit in a column of their own.
  const CHECK_W = 224;
  const LABEL_COL = 280;
  // A lane name: its left padding and colour bar, its line box, and (on a
  // vertical lane) its gap above the first checkpoint.
  const LABEL_PAD_L = 12;
  const LABEL_BAR = 4;
  const LABEL_H = 28;
  const LABEL_GAP = 16;
  // The report panel, right of the lanes; result rows stack inside it.
  const PANEL_GAP = 48;
  const PANEL_W = 440;
  const PANEL_PAD = 24;
  const PANEL_HEAD = 44;
  const RESULT_H = 48;
  // Wider than DROP_SHIFT, so a settling row never touches the one above.
  const RESULT_GAP = 18;
  const HOLD_MS = 800;
  const FINAL_FADE_MS = 120;
  const PANEL_PULSE_MS = 180;
  const TRAVEL_MS = 700;
  const ENTER_MS = 130;
  const ENTER_SHIFT = 12;
  const EXIT_MS = 90;
  const EXIT_LEAD = 60;
  const EXIT_SHIFT = 16;
  const TAIL_MS = 100;
  const CHIP_IN_MS = 100;
  const CHIP_R = 6;
  const CHIP_OUT_MS = 60;
  const TRANSFER_MS = 260;
  const DROP_MS = 220;
  const DROP_FADE_MS = 100;
  const DROP_SHIFT = 14;
  const HL_IN_MS = 120;
  const HL_OUT_MS = 180;
  const PULSE_MS = 180;
  const PULSE_SCALE = 0.025;
  const MARKER_R = 7;
  const MARKER_HALO_R = 15;

  // Text fitting, mirrored from scripts/diagram_text_fit.rb (a unit test
  // holds the two together): one width estimate at the font each box is
  // drawn in (an em share per glyph class, see EM there), and one rule per
  // box. The validator rejects a spec whose text breaks a rule, so nothing
  // here ever cuts text off.
  const EM = {"narrow":{"chars":" 'ijlIJ|/.,;:f-!()[]tr_`","em":0.5},"caps":{"chars":"BRXAVKUGDNHQO^>=<+~#&","em":0.88},"wide":{"chars":"wMm@%W","em":1.11},"default":0.74,"cjk":1.0};
  const CJK = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
  const FIT = {"checkpoint":{"font":19,"width":196,"icon":28,"lines":2,"line_h":23,"pad_y":6},"token":{"font":17,"width":196,"icon":22,"lines":1},"lane_label":{"font":22,"width":248,"icon":30,"lines":1},"report_row":{"font":18,"width":328,"icon":0,"lines":1,"aside_font":15,"aside_pad":0},"report_head":{"font":22,"width":390,"icon":0,"lines":1,"aside_font":16,"aside_pad":32}};
  const emOf = (c) => {
    if (CJK.test(c)) return EM.cjk;
    const k = ['narrow', 'caps', 'wide'].find((name) => EM[name].chars.includes(c));
    return k ? EM[k].em : EM.default;
  };
  const textWidth = (text, fontPx) => [...String(text || '')].reduce((sum, c) => sum + emOf(c), 0) * fontPx;
  // Greedy at spaces; a word wider than a line breaks between characters,
  // as the browser does under overflow-wrap: anywhere.
  const wrapLines = (text, fontPx, maxW) => {
    const out = [];
    let cur = '';
    for (const word of String(text || '').split(/\s+/).filter(Boolean)) {
      const trial = cur ? `${cur} ${word}` : word;
      if (textWidth(trial, fontPx) <= maxW) { cur = trial; continue; }
      if (cur) out.push(cur);
      cur = '';
      for (const c of word) {
        if (cur && textWidth(cur + c, fontPx) > maxW) { out.push(cur); cur = ''; }
        cur += c;
      }
    }
    if (cur) out.push(cur);
    return out;
  };

  const horizontal = LANES.direction !== 'vertical';
  const along = horizontal ? 'x' : 'y';
  const cross = horizontal ? 'y' : 'x';
  const steps = spec.steps || [];
  const nodeIds = spec.nodes.map((n) => n.id);
  const nodeById = Object.fromEntries(spec.nodes.map((n) => [n.id, n]));
  const laneIds = LANES.lanes.map((l) => l.id);
  const laneById = Object.fromEntries(LANES.lanes.map((l) => [l.id, l]));

  const WIDTH = Object.fromEntries(spec.nodes.map((n) => {
    const texts = [n.label || ''].concat(steps.filter((s) => s.op === 'label' && s.id === n.id).map((s) => s.text || ''));
    const chars = Math.max(...texts.map((x) => x.length));
    const icon = iconOf(n) ? ICON_PX + ICON_GAP : 0;
    const w = Math.min(NODE_MAX_W + icon, Math.max(NODE_MIN_W, chars * CHAR_W + NODE_PAD_W + icon));
    return [n.id, Math.round(w / 2) * 2];
  }));
  const checkpoint = (id) => horizontal && !!nodeById[id].lane;
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const clamp01 = (v) => clamp(v, 0, 1);

  // -- easing --------------------------------------------------------------

  // The u in 0..1 where a rising fn(u) reaches p, by fixed-count bisection.
  const bisect = (fn, p) => {
    let lo = 0; let hi = 1;
    for (let i = 0; i < 40; i += 1) { const mid = (lo + hi) / 2; if (fn(mid) < p) lo = mid; else hi = mid; }
    return (lo + hi) / 2;
  };
  // A CSS cubic-bezier, solved for x by bisection so every frame lands on
  // the same value whatever the engine.
  const bezier = (x1, y1, x2, y2) => {
    const at = (a, b, u) => 3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u;
    return (p) => {
      if (p <= 0) return 0;
      if (p >= 1) return 1;
      return at(y1, y2, bisect((u) => at(x1, x2, u), p));
    };
  };
  const cubic = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
  const EASINGS = {
    linear: (p) => clamp01(p), 'ease-in-out': (p) => cubic(clamp01(p)),
    standard: bezier(0.4, 0, 0.2, 1), decelerate: bezier(0, 0, 0.2, 1), accelerate: bezier(0.4, 0, 1, 1),
    emphasized: bezier(0.22, 1, 0.36, 1), settle: bezier(0.16, 1, 0.3, 1)
  };
  const easing = (name) => {
    if (!name) return EASINGS.standard;
    if (EASINGS[name]) return EASINGS[name];
    const m = String(name).match(/^cubic-bezier\(([^)]*)\)$/);
    const v = m ? m[1].split(',').map(Number) : [];
    return v.length === 4 && v.every(Number.isFinite) ? bezier(...v) : EASINGS.standard;
  };

  // -- prepare -----------------------------------------------------------

  const travelSteps = steps.filter((s) => s.op === 'travel');
  const owned = new Set(travelSteps.flatMap((s) => [s.id, s.result].filter(Boolean)));
  const rails = travelSteps.length > 0;
  const report = horizontal && LANES.report ? LANES.report : null;
  const laned = spec.nodes.filter((n) => n.lane).map((n) => n.id);
  const even = (v) => Math.round(v / 2) * 2;
  const textsOf = (n) => [n.label || ''].concat(steps.filter((s) => s.op === 'label' && s.id === n.id).map((s) => s.text || ''));
  const ext = (box, axis) => (axis === 'x' ? box.w : box.h);
  const union = (boxes) => boxes.reduce((b, r) => ({
    x0: Math.min(b.x0, r.x), y0: Math.min(b.y0, r.y), x1: Math.max(b.x1, r.x + r.w), y1: Math.max(b.y1, r.y + r.h)
  }), { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity });
  // A box from along/cross coordinates and extents.
  const flowBox = (a, c, alongExt, crossExt) => (horizontal ? { x: a, y: c, w: alongExt, h: crossExt } : { x: c, y: a, w: crossExt, h: alongExt });

  // The layout record: every node box, band, label, rail, token, report
  // row, and the camera bounds, computed once here from the spec before the
  // runtime boots. The runtime takes each node's size from it (cf_width,
  // cf_height), and every draw reads it; nothing sizes itself at draw time.
  const computeLayout = () => {
    const fc = FIT.checkpoint;
    // A checkpoint is CHECK_W wide; any other node keeps the runtime's
    // width. Either wraps its text at FIT's checkpoint font and line height
    // and grows to fit, never under NODE_H.
    const size = Object.fromEntries(spec.nodes.map((n) => {
      const w = checkpoint(n.id) ? CHECK_W : WIDTH[n.id];
      const room = checkpoint(n.id) ? fc.width - (iconOf(n) ? fc.icon : 0) : w - NODE_PAD_X - (iconOf(n) ? ICON_PX + ICON_GAP : 0);
      const lines = Math.max(1, ...textsOf(n).map((t) => wrapLines(t, fc.font, room).length));
      return [n.id, { w, h: Math.max(NODE_H, even(lines * fc.line_h + 2 * fc.pad_y + 2 * NODE_BORDER)), lines }];
    }));
    // Keyed by authored id, which may be a prototype name like `constructor`.
    const tokens = Object.create(null);
    for (const s of travelSteps) {
      if (!s.id || tokens[s.id]) continue;
      const n = nodeById[s.id];
      tokens[s.id] = { w: even(textWidth(n.label, FIT.token.font) + TOKEN_PAD_W + (iconOf(n) ? FIT.token.icon : 0)), h: TOKEN_H };
    }
    const marker = { w: 2 * MARKER_HALO_R, h: 2 * MARKER_HALO_R };
    const rider = (s) => (s.id ? tokens[s.id] : marker);

    const direction = (spec.layout && spec.layout.direction) || 'LR';
    const pos = {};
    if (((spec.layout && spec.layout.engine) || 'dagre') === 'dagre') {
      const g = new dagre.graphlib.Graph();
      g.setGraph({ rankdir: direction, nodesep: NODE_SEP, ranksep: RANK_SEP, marginx: 0, marginy: 0 });
      g.setDefaultEdgeLabel(() => ({}));
      for (const n of spec.nodes) g.setNode(n.id, { width: size[n.id].w, height: size[n.id].h });
      for (const e of spec.edges) g.setEdge(e.source, e.target);
      dagre.layout(g);
      for (const id of nodeIds) { const p = g.node(id); pos[id] = { x: Math.round(p.x - size[id].w / 2), y: Math.round(p.y - size[id].h / 2) }; }
    }
    const pinned = new Set();
    for (const n of spec.nodes) if (n.position) { pos[n.id] = { x: n.position.x, y: n.position.y }; pinned.add(n.id); }
    for (const id of nodeIds) if (!pos[id]) pos[id] = { x: 0, y: 0 };

    // Bands stack along the cross axis in spec order. Inside a band, nodes
    // keep their along coordinate and take rows greedily, so two nodes that
    // would overlap sit one row apart; the band grows to fit its rows, plus
    // its rail when anything travels, and a vertical band to fit its name.
    // A pinned node keeps only its along coordinate: the band owns the
    // other. A rail reserves the cross-axis extent of whatever rides it.
    const labelW = (lane) => even(LABEL_PAD_L + LABEL_BAR + (lane.icon && ICONS[lane.icon] ? FIT.lane_label.icon : 0) + textWidth(lane.label, FIT.lane_label.font));
    const bands = [];
    let edge = 0;
    for (const lane of LANES.lanes) {
      const members = spec.nodes.filter((n) => n.lane === lane.id).map((n) => n.id)
        .sort((a, b) => pos[a][along] - pos[b][along] || nodeIds.indexOf(a) - nodeIds.indexOf(b));
      const rows = [];
      const rowOf = {};
      for (const id of members) {
        let r = rows.findIndex((row) => row.end + ROW_GAP <= pos[id][along]);
        if (r < 0) { rows.push({ end: -Infinity, size: 0 }); r = rows.length - 1; }
        rows[r].end = pos[id][along] + ext(size[id], along);
        rows[r].size = Math.max(rows[r].size, ext(size[id], cross));
        rowOf[id] = r;
      }
      const content = rows.reduce((sum, row) => sum + row.size, 0) + ROW_GAP * Math.max(0, rows.length - 1);
      const rail = Math.max(TOKEN_H, ...travelSteps.filter((s) => s.lane === lane.id).map((s) => ext(rider(s), cross)));
      const tail = rails ? RAIL_GAP + rail + LANE_PAD : LANE_PAD;
      const least = horizontal ? LANE_MIN : Math.max(LANE_MIN, labelW(lane) + 2 * LANE_PAD);
      const extent = Math.max(least, content + LANE_PAD + tail);
      let at = edge + LANE_PAD + (extent - LANE_PAD - tail - content) / 2;
      const rowStart = rows.map((row) => { const s = at; at += row.size + ROW_GAP; return s; });
      for (const id of members) pos[id][cross] = Math.round(rowStart[rowOf[id]] + (rows[rowOf[id]].size - ext(size[id], cross)) / 2);
      bands.push({ id: lane.id, start: edge, extent, rail: edge + extent - LANE_PAD - rail / 2, railSize: rail, mid: edge + LANE_PAD + (extent - LANE_PAD - tail) / 2, members });
      edge += extent;
    }

    // A laid-out node outside every lane keeps its place relative to the
    // other such nodes, centred on the stack of bands.
    const free = nodeIds.filter((id) => !nodeById[id].lane && !pinned.has(id) && !owned.has(id));
    if (free.length && !(spec.layout && spec.layout.engine === 'manual')) {
      const lo = Math.min(...free.map((id) => pos[id][cross]));
      const hi = Math.max(...free.map((id) => pos[id][cross] + ext(size[id], cross)));
      const shift = Math.round(edge / 2 - (lo + hi) / 2);
      for (const id of free) pos[id][cross] += shift;
    }

    // Every travel spans the same stretch: from the first checkpoint's start
    // to CLEAR past the widest reach of the last, so a token crossing each
    // lane in turn reads as one short route under its checkpoints.
    const span = laned.length
      ? [Math.min(...laned.map((id) => pos[id][along])), Math.max(...laned.map((id) => pos[id][along] + ext(size[id], along))) + CLEAR]
      : [0, 600];
    for (const b of bands) {
      const w = labelW(laneById[b.id]);
      b.label = horizontal
        ? { x: span[0] - LABEL_COL, y: Math.round(b.mid - LABEL_H / 2), w, h: LABEL_H }
        : { x: b.start + LANE_PAD, y: span[0] - LABEL_GAP - LABEL_H, w, h: LABEL_H };
    }
    const railList = bands.map((b) => ({ lane: b.id, axis: along, from: span[0], to: span[1], at: b.rail, size: b.railSize }));
    const reach = Math.max(span[1], ...travelSteps.map((s) => span[1] + ext(rider(s), along)));
    const delivered = travelSteps.filter((s) => s.result);
    const panel = report && {
      x: reach + PANEL_GAP, y: 0, w: PANEL_W, h: Math.max(edge, PANEL_PAD * 2 + PANEL_HEAD + delivered.length * (RESULT_H + RESULT_GAP))
    };
    const rows = panel ? delivered.map((s, k) => ({
      id: s.result, x: panel.x + PANEL_PAD, y: panel.y + PANEL_PAD + PANEL_HEAD + k * (RESULT_H + RESULT_GAP), w: PANEL_W - 2 * PANEL_PAD, h: RESULT_H
    })) : [];
    for (const r of rows) pos[r.id] = { x: r.x, y: r.y };
    const boxes = {};
    for (const id of nodeIds) boxes[id] = { x: pos[id].x, y: pos[id].y, w: size[id].w, h: size[id].h, lines: size[id].lines };
    for (const r of rows) boxes[r.id] = { x: r.x, y: r.y, w: r.w, h: r.h, lines: 1 };
    // With a panel, the band fills run from the name column to just short
    // of it.
    if (panel) for (const b of bands) b.fill = { from: b.label.x - PANEL_GAP / 2, to: panel.x - PANEL_GAP / 2 };
    // What the runtime needs to size each node as its box: a width or
    // height only where the box differs from the runtime's own.
    const runtime = Object.fromEntries(nodeIds.map((id) => [id, {
      ...(size[id].w !== WIDTH[id] ? { cf_width: size[id].w } : {}), ...(size[id].h !== NODE_H ? { cf_height: size[id].h } : {})
    }]));

    // The camera frames every visible box: nodes, lane names, the bands
    // over the travel stretch, each rider from its entrance to its exit
    // with its chip, the panel, and each standalone result from where its
    // drop starts.
    const shown = nodeIds.filter((id) => !owned.has(id)).map((id) => boxes[id]);
    const results = panel ? [panel] : delivered.map((s) => ({ ...boxes[s.result], y: boxes[s.result].y - DROP_SHIFT, h: boxes[s.result].h + DROP_SHIFT }));
    const travel = travelSteps.map((s) => {
      const b = bands.find((x) => x.id === s.lane);
      return flowBox(span[0] - ENTER_SHIFT - ext(rider(s), along), b.rail - b.railSize / 2,
        span[1] - span[0] + 2 * ext(rider(s), along) + ENTER_SHIFT + EXIT_SHIFT + 2 * CHIP_R + 4, b.railSize);
    });
    const laneBox = bands.length ? [flowBox(span[0], 0, span[1] - span[0], edge)] : [];
    const bounds = union([...shown, ...bands.map((b) => b.label), ...results, ...travel, ...laneBox]);
    return { boxes, bands, rails: railList, tokens, marker, panel, rows, span, reach, bounds, pos, runtime };
  };
  const LAYOUT = computeLayout();
  const pos = LAYOUT.pos;
  const span = LAYOUT.span;
  const panel = LAYOUT.panel;
  const bands = Object.fromEntries(LAYOUT.bands.map((b) => [b.id, b]));

  // The timeline of every travel, in step order.
  const travels = travelSteps.map((s) => {
    const D = s.duration == null ? TRAVEL_MS : s.duration;
    const box = s.id ? LAYOUT.tokens[s.id] : LAYOUT.marker;
    const w = ext(box, along);
    const fn = easing(s.easing);
    const tr = {
      t0: s.t_ms, D, lane: s.lane, id: s.id || null, result: s.result || null, w, box, fn,
      startA: s.id ? span[0] : span[0] - w / 2, endA: s.id ? span[1] : span[1] - w / 2, rail: bands[s.lane].rail,
      enterAt: s.t_ms - ENTER_MS, chipAt: s.t_ms + D - CHIP_IN_MS, transferAt: s.t_ms + D + TAIL_MS
    };
    tr.landAt = tr.transferAt + TRANSFER_MS;
    tr.releaseAt = tr.result ? tr.landAt : tr.transferAt;
    // When the token's centre passes each checkpoint's centre.
    tr.pulses = bands[s.lane].members.filter((id) => !owned.has(id)).flatMap((id) => {
      const b = LAYOUT.boxes[id];
      const p = (b[along] + ext(b, along) / 2 - tr.startA - w / 2) / (tr.endA - tr.startA);
      return p >= 0 && p <= 1 ? [{ id, at: s.t_ms + bisect(fn, p) * D }] : [];
    });
    return tr;
  });
  // A token leaves its lane as the next travel of the same token arrives; a
  // marker, or a token's last travel, leaves only if it is a marker.
  const delivered = travels.filter((tr) => tr.result);
  const lastLand = delivered.length ? Math.max(...delivered.map((tr) => tr.landAt)) : Infinity;
  travels.forEach((tr, i) => {
    const next = tr.id && travels.slice(i + 1).find((o) => o.id === tr.id);
    tr.exitShift = EXIT_SHIFT;
    tr.exitMs = EXIT_MS;
    if (next) tr.exitAt = next.enterAt - EXIT_LEAD;
    else if (!tr.id) tr.exitAt = tr.transferAt;
    // The closing fade waits for the last landing and for this travel's own end.
    else if (report && delivered.length) Object.assign(tr, { exitAt: Math.max(lastLand, tr.transferAt) + HOLD_MS, exitShift: 0, exitMs: FINAL_FADE_MS });
    else tr.exitAt = Infinity;
  });
  const slots = Object.fromEntries(delivered.map((tr) => [tr.result, tr]));

  // Two invisible corner nodes span LAYOUT.bounds, so the runtime's fits
  // frame the whole composition. Internal ids start `__cf_`, which no
  // authored id may, so they never collide.
  const ANCHORS = ['__cf_lane_anchor_a', '__cf_lane_anchor_b'];
  const B = LAYOUT.bounds;
  spec.nodes.push({ id: ANCHORS[0], label: ' ', cf_width: ANCHOR_PX, cf_height: ANCHOR_PX, position: { x: Math.floor(B.x0), y: Math.floor(B.y0) } },
    { id: ANCHORS[1], label: ' ', cf_width: ANCHOR_PX, cf_height: ANCHOR_PX, position: { x: Math.ceil(B.x1) - ANCHOR_PX, y: Math.ceil(B.y1) - ANCHOR_PX } });
  spec.initial = (spec.initial || []).concat(ANCHORS);

  // Every node takes its place and size from the record; the runtime
  // reads both, so its node, handles, and edges match each box.
  for (const n of spec.nodes) {
    const b = LAYOUT.boxes[n.id];
    if (!b) continue;
    n.position = { x: Math.round(b.x), y: Math.round(b.y) };
    Object.assign(n, LAYOUT.runtime[n.id]);
  }
  spec.initial = (spec.initial || []).filter((id) => !owned.has(id));
  steps.forEach((s, i) => {
    if (s.op === 'travel') steps[i] = { t_ms: s.t_ms, op: 'add_node', ids: [] };
  });
  spec.steps = steps;
  specEl.textContent = JSON.stringify(spec);

  // -- state ---------------------------------------------------------------

  const ordered = steps.map((s, i) => [s, i]).sort((a, b) => a[0].t_ms - b[0].t_ms || a[1] - b[1]).map(([s]) => s);
  const named = (spec.initial || []).filter((id) => laneIds.includes(id));
  // The steps that name a lane (prepare rewrote only travel steps, which
  // name a lane by `lane`, never by id).
  const laneSteps = ordered.filter((s) => (s.ids || (s.id ? [s.id] : [])).some((id) => laneIds.includes(id)));
  const highlightSpans = Object.fromEntries(laneIds.map((id) => [id, []]));
  {
    const open = {};
    for (const s of laneSteps) {
      for (const id of (s.ids || [s.id]).filter((x) => laneIds.includes(x))) {
        if (s.op === 'highlight' && !(id in open)) open[id] = s.t_ms;
        else if ((s.op === 'unhighlight' || s.op === 'dim' || s.op === 'remove') && id in open) {
          highlightSpans[id].push([open[id], s.t_ms, HL_OUT_MS]); delete open[id];
        }
      }
    }
    for (const [id, at] of Object.entries(open)) highlightSpans[id].push([at, Infinity, HL_OUT_MS]);
    for (const tr of travels) highlightSpans[tr.lane].push([tr.enterAt, tr.releaseAt, HL_OUT_MS]);
  }
  const ramp = (t, [on, off, out]) => (t < on ? 0 : Math.min(clamp01((t - on) / HL_IN_MS), 1 - clamp01((t - off) / out)));

  const laneState = (t) => {
    const shownAt = {};
    for (const id of named.length ? named : laneIds) shownAt[id] = -Infinity;
    const removedAt = {};
    const dim = new Set();
    for (const s of laneSteps) {
      if (s.t_ms > t) break;
      for (const id of (s.ids || [s.id]).filter((x) => laneIds.includes(x))) {
        if (s.op === 'add_node') { shownAt[id] = s.t_ms; delete removedAt[id]; }
        else if (s.op === 'remove') removedAt[id] = s.t_ms;
        else if (s.op === 'dim') dim.add(id);
        else if (s.op === 'highlight' || s.op === 'unhighlight') dim.delete(id);
      }
    }
    return Object.fromEntries(laneIds.map((id) => {
      let o = id in shownAt ? clamp01((t - shownAt[id]) / FADE_MS) : 0;
      if (id in removedAt) o = Math.min(o, 1 - clamp01((t - removedAt[id]) / FADE_MS));
      const level = Math.max(0, ...highlightSpans[id].map((span) => ramp(t, span)));
      return [id, { opacity: o * (dim.has(id) ? DIM_OPACITY : 1), level }];
    }));
  };

  // A travel's token at t: along (left edge) and cross (centre) in flow
  // units, and opacity; null while it is not on screen.
  const tokenAt = (tr, t) => {
    if (t < tr.enterAt || t >= tr.exitAt + tr.exitMs) return null;
    let a; let o = 1;
    if (t < tr.t0) {
      const q = clamp01((t - tr.enterAt) / ENTER_MS);
      a = tr.startA - ENTER_SHIFT * (1 - EASINGS.decelerate(q));
      o = q;
    } else {
      a = tr.startA + (tr.endA - tr.startA) * tr.fn(clamp01((t - tr.t0) / tr.D));
    }
    if (t >= tr.exitAt) {
      const q = clamp01((t - tr.exitAt) / tr.exitMs);
      a += tr.exitShift * EASINGS.decelerate(q);
      o = Math.min(o, 1 - q);
    }
    return { a, c: tr.rail, opacity: o };
  };

  // The result chip: born at the token's exit, carried to its slot.
  const chipAt = (tr, t) => {
    if (!tr.result || t < tr.chipAt || t >= tr.landAt) return null;
    const tok = tokenAt(tr, Math.min(t, tr.transferAt));
    const from = { a: (tok ? tok.a : tr.endA) + tr.w + CHIP_R + 4, c: tr.rail };
    const slot = pos[tr.result];
    const box = LAYOUT.boxes[tr.result];
    const to = { a: slot[along] + (panel ? 18 : CHIP_R), c: slot[cross] + (horizontal ? box.h : box.w) / 2 };
    if (t < tr.transferAt) return { a: from.a, c: from.c, opacity: clamp01((t - tr.chipAt) / CHIP_IN_MS), scale: 0.6 + 0.4 * clamp01((t - tr.chipAt) / CHIP_IN_MS) };
    const p = EASINGS.emphasized((t - tr.transferAt) / TRANSFER_MS);
    return { a: from.a + (to.a - from.a) * p, c: from.c + (to.c - from.c) * p, opacity: 1 - clamp01((t - (tr.landAt - CHIP_OUT_MS)) / CHIP_OUT_MS), scale: 1 };
  };

  // A result card: hidden until its chip lands, then it settles into its
  // reserved slot from DROP_SHIFT above, fading in over DROP_FADE_MS.
  const cardAt = (id, t) => {
    const tr = slots[id];
    if (t < tr.landAt) return null;
    const q = (t - tr.landAt) / DROP_MS;
    return { x: pos[id].x, y: pos[id].y - DROP_SHIFT * (1 - EASINGS.settle(q)), opacity: clamp01((t - tr.landAt) / DROP_FADE_MS) };
  };

  const pulseAt = (id, t) => {
    let s = 1;
    for (const tr of travels) for (const p of tr.pulses) {
      if (p.id === id && t >= p.at && t < p.at + PULSE_MS) s = Math.max(s, 1 + PULSE_SCALE * Math.sin(Math.PI * (t - p.at) / PULSE_MS));
    }
    return s;
  };

  // The panel's closing beat: the count appears as the last result lands,
  // and the border swells once as the token leaves.
  const finale = (t) => ({
    badge: clamp01((t - lastLand) / FINAL_FADE_MS),
    border: t >= lastLand + HOLD_MS && t < lastLand + HOLD_MS + PANEL_PULSE_MS ? Math.sin(Math.PI * (t - lastLand - HOLD_MS) / PANEL_PULSE_MS) : 0
  });

  // -- draw --------------------------------------------------------------

  const dark = LANES.theme === 'dark';
  const DIVIDER = dark ? 'rgba(255, 255, 255, 0.08)' : 'rgba(15, 23, 42, 0.08)';
  const PANEL_FILL = dark ? '#111c2d' : 'var(--cf-node, #f8fafc)';
  const hexRgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const rgba = (hex, a) => `rgba(${hexRgb(hex).join(', ')}, ${a})`;
  // A laned node takes its lane's colour while the lane runs and a quiet
  // border otherwise; the runtime's own highlight (data-cf-hl) and an idle
  // node's own colour win over both, by selector, not by per-frame writes.
  const QUIET = `1px solid ${dark ? 'rgba(255, 255, 255, 0.16)' : 'rgba(15, 23, 42, 0.16)'}`;
  const laneRules = laned.map((id) => {
    const lane = laneById[nodeById[id].lane];
    const node = `.react-flow__node[data-id="${CSS.escape(id)}"]:not([data-cf-hl="1"]) .cf-node`;
    return `#cf-diagram-root:not([data-cf-lanes-on~="${lane.id}"]) ${node}:not([data-color]) { border: ${QUIET}; }\n` +
      `#cf-diagram-root[data-cf-lanes-on~="${lane.id}"] ${node} { border: 1.5px solid ${lane.color}; box-shadow: 0 0 16px ${rgba(lane.color, 0.12)}; }`;
  }).join('\n');
  const css = document.createElement('style');
  css.textContent = `
body { background: var(--cf-surface, #ffffff); }
#cf-diagram-root { position: relative; z-index: 1; }
#cf-diagram-root .react-flow { background: transparent; --xy-background-color: transparent; }
.cf-lanes, .cf-lane-front { position: fixed; inset: 0; pointer-events: none; overflow: visible; }
.cf-lanes { z-index: 0; }
.cf-lane-front { z-index: 2; }
.cf-lane { position: absolute; box-sizing: border-box; border: 0 solid ${DIVIDER}; }
.cf-lanes[data-dir="horizontal"] .cf-lane { left: 0; right: 0; border-top-width: 1px; border-bottom-width: 1px; }
.cf-lanes[data-dir="vertical"] .cf-lane { top: 0; bottom: 0; border-left-width: 1px; border-right-width: 1px; }
.cf-lane-label { position: absolute; left: 0; top: 0; transform-origin: 0 0; box-sizing: border-box; white-space: nowrap;
  padding: 0 0 0 ${LABEL_PAD_L}px; border-left: ${LABEL_BAR}px solid; color: var(--cf-text, #0f172a);
  font: 600 ${FIT.lane_label.font}px/${LABEL_H}px system-ui, sans-serif; }
.cf-lane-label svg { width: 22px; height: 22px; margin-right: 8px; vertical-align: -4px; }
${ANCHORS.map((id) => `.react-flow__node[data-id="${id}"] .cf-node`).join(', ')} { visibility: hidden; }
#cf-diagram-root .cf-node, .cf-lane-front .cf-node { font-size: ${FIT.checkpoint.font}px; line-height: ${FIT.checkpoint.line_h}px; overflow-wrap: anywhere; }
${laneRules}
.cf-lane-panel { box-sizing: border-box; border: 1px solid; border-radius: 14px; padding: ${PANEL_PAD}px; }
.cf-lane-panel-head { height: ${PANEL_HEAD}px; color: var(--cf-text, #0f172a); font: 600 22px/28px system-ui, sans-serif; white-space: nowrap; }
.cf-lane-badge { margin-left: 10px; padding: 2px 10px; border-radius: 999px; font: 600 16px/22px system-ui, sans-serif;
  color: var(--cf-text, #0f172a); background: ${DIVIDER}; border: 1px solid ${DIVIDER}; }
.cf-lane-row { box-sizing: border-box; display: flex; align-items: center; gap: 12px; padding: 0 14px;
  border: 1px solid ${DIVIDER}; border-radius: 10px; white-space: nowrap; font: 600 18px/1 system-ui, sans-serif; color: var(--cf-text, #0f172a); }
.cf-lane-row i { flex: none; width: 10px; height: 10px; border-radius: 50%; }
.cf-lane-row small { margin-left: auto; font: 500 15px/1 system-ui, sans-serif; color: var(--cf-muted, #475569); }
.cf-lane-front > * { position: absolute; left: 0; top: 0; transform-origin: 0 0; }
.cf-lane-token { box-sizing: border-box; display: flex; align-items: center; justify-content: center; white-space: nowrap;
  border: 2px solid var(--cf-accent, #2563eb); border-radius: ${TOKEN_H / 2}px; background: var(--cf-accent-tint, #dbeafe);
  color: var(--cf-text, #0f172a); font: 600 17px/1 system-ui, sans-serif; }
.cf-lane-token svg { width: ${TOKEN_ICON}px; height: ${TOKEN_ICON}px; margin-right: 6px; fill: currentColor; flex: none; }
.cf-lane-chip { box-sizing: border-box; width: ${2 * CHIP_R}px; height: ${2 * CHIP_R}px; border-radius: 50%; }
.cf-lane-marker { border-radius: 50%; box-sizing: border-box; }
`;
  document.head.appendChild(css);

  const SVG_NS = 'http://www.w3.org/2000/svg';
  const iconEl = (paths, cls, fill) => {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 256 256');
    svg.setAttribute('aria-hidden', 'true');
    if (cls) svg.setAttribute('class', cls);
    if (fill) svg.style.fill = fill;
    for (const [d, opacity] of paths) {
      const path = document.createElementNS(SVG_NS, 'path');
      path.setAttribute('d', d);
      if (opacity != null) path.setAttribute('opacity', String(opacity));
      svg.appendChild(path);
    }
    return svg;
  };
  const layer = (cls) => { const el = document.createElement('div'); el.className = cls; el.setAttribute('aria-hidden', 'true'); return el; };
  const back = layer('cf-lanes');
  back.dataset.dir = horizontal ? 'horizontal' : 'vertical';
  const front = layer('cf-lane-front');
  const laneEls = {};
  const labelEls = {};
  for (const lane of LANES.lanes) {
    const el = document.createElement('div');
    el.className = 'cf-lane';
    el.dataset.lane = lane.id;
    const label = document.createElement('div');
    label.className = 'cf-lane-label';
    label.style.borderLeftColor = lane.color;
    if (lane.icon && ICONS[lane.icon]) label.appendChild(iconEl(ICONS[lane.icon], null, lane.color));
    label.appendChild(document.createTextNode(lane.label));
    Object.assign(label.style, { width: `${bands[lane.id].label.w}px`, height: `${bands[lane.id].label.h}px` });
    back.appendChild(label);
    back.prepend(el);
    laneEls[lane.id] = el;
    labelEls[lane.id] = label;
  }
  // Result cards wear the runtime's own node classes, so they match the
  // diagram's nodes exactly.
  const panelEl = panel && document.createElement('div');
  const headEl = panel && document.createElement('div');
  const badgeEl = panel && document.createElement('span');
  if (panel) {
    panelEl.className = 'cf-lane-panel';
    Object.assign(panelEl.style, { width: `${panel.w}px`, height: `${panel.h}px`, background: PANEL_FILL });
    headEl.className = 'cf-lane-panel-head';
    headEl.textContent = report.label;
    badgeEl.className = 'cf-lane-badge';
    badgeEl.textContent = `${delivered.length}/${delivered.length} ${report.unit || 'checks'}`;
    headEl.appendChild(badgeEl);
    panelEl.appendChild(headEl);
    front.appendChild(panelEl);
  }
  const rowEl = (tr) => {
    const el = document.createElement('div');
    el.className = 'cf-lane-row cf-lane-card';
    el.dataset.id = tr.result;
    const row = LAYOUT.rows.find((r) => r.id === tr.result);
    Object.assign(el.style, { width: `${row.w}px`, height: `${row.h}px` });
    el.style.background = PANEL_FILL;
    const mark = document.createElement('i');
    mark.style.background = laneById[tr.lane].color;
    const lane = document.createElement('small');
    lane.textContent = laneById[tr.lane].label;
    el.append(mark, document.createTextNode(nodeById[tr.result].label), lane);
    front.appendChild(el);
    return el;
  };
  const cardEls = Object.fromEntries(Object.keys(slots).map((id) => {
    if (panel) return [id, rowEl(slots[id])];
    const n = nodeById[id];
    const c = colorOf(id);
    const el = document.createElement('div');
    el.className = 'cf-node cf-lane-card';
    el.dataset.id = id;
    el.dataset.role = n.role || 'default';
    if (c) {
      el.dataset.color = '1';
      for (const [k, v] of [['--cf-item', c.color], ['--cf-item-tint', c.tint], ['--cf-item-ring', c.ring]]) el.style.setProperty(k, v);
    }
    Object.assign(el.style, { width: `${LAYOUT.boxes[id].w}px`, height: `${LAYOUT.boxes[id].h}px` });
    if (iconOf(n)) el.appendChild(iconEl(iconOf(n), 'cf-node-icon'));
    const span = document.createElement('span');
    span.className = 'cf-node-label';
    span.textContent = n.label;
    el.appendChild(span);
    front.appendChild(el);
    return [id, el];
  }));
  const tokenEls = travels.map((tr, i) => {
    const el = document.createElement('div');
    el.dataset.travel = String(i);
    if (tr.id) {
      const n = nodeById[tr.id];
      const c = colorOf(tr.id);
      el.className = 'cf-lane-token';
      Object.assign(el.style, { width: `${tr.box.w}px`, height: `${tr.box.h}px` });
      if (c) { el.style.borderColor = c.color; el.style.background = c.tint; }
      if (iconOf(n)) el.appendChild(iconEl(iconOf(n), null, c ? c.color : null));
      el.appendChild(document.createTextNode(n.label));
    } else {
      const lane = laneById[tr.lane];
      el.className = 'cf-lane-marker';
      Object.assign(el.style, { width: `${2 * MARKER_HALO_R}px`, height: `${2 * MARKER_HALO_R}px`, background: lane.tint_hl, border: `1px solid ${lane.color}` });
      const core = document.createElement('div');
      Object.assign(core.style, { position: 'absolute', borderRadius: '50%', width: `${2 * MARKER_R}px`, height: `${2 * MARKER_R}px`, background: lane.color, left: `${MARKER_HALO_R - MARKER_R - 1}px`, top: `${MARKER_HALO_R - MARKER_R - 1}px` });
      el.appendChild(core);
    }
    front.appendChild(el);
    return el;
  });
  const chipEls = travels.map((tr) => {
    if (!tr.result) return null;
    const lane = laneById[tr.lane];
    const el = document.createElement('div');
    el.className = 'cf-lane-chip';
    Object.assign(el.style, { background: lane.color, boxShadow: `0 0 0 3px ${lane.tint_hl}` });
    front.appendChild(el);
    return el;
  });

  // The camera the runtime set this frame, read back from React Flow.
  const viewport = () => {
    const el = document.querySelector('.react-flow__viewport');
    const m = el && el.style.transform.match(/translate\(([-\d.e]+)px,\s*([-\d.e]+)px\)\s*scale\(([-\d.e]+)\)/);
    return m ? { x: Number(m[1]), y: Number(m[2]), zoom: Number(m[3]) } : null;
  };
  const set = (el, key, value) => { if (el.style[key] !== value) el.style[key] = value; };
  const px = (v) => `${v.toFixed(2)}px`;
  const mixHex = (a, b, p) => { const x = hexRgb(a); const y = hexRgb(b); return `rgb(${x.map((v, i) => Math.round(v + (y[i] - v) * p)).join(', ')})`; };
  // Places a front element at flow point (fx, fy), scaled with the camera.
  const place = (el, vp, fx, fy, opacity, scale = 1) => {
    const on = opacity > 0;
    set(el, 'display', on ? '' : 'none');
    if (!on) return;
    set(el, 'transform', `translate(${px(fx * vp.zoom + vp.x)}, ${px(fy * vp.zoom + vp.y)}) scale(${(vp.zoom * scale).toFixed(4)})`);
    set(el, 'opacity', opacity.toFixed(3));
  };
  const flowXY = (a, c) => (horizontal ? [a, c] : [c, a]);

  const draw = () => {
    const vp = viewport();
    if (!vp) return;
    const t = performance.now();
    const lanes = laneState(t);
    const off = horizontal ? vp.y : vp.x;
    const sx = (x) => x * vp.zoom + vp.x;
    const sy = (y) => y * vp.zoom + vp.y;
    for (const lane of LANES.lanes) {
      const el = laneEls[lane.id];
      const band = bands[lane.id];
      const s = lanes[lane.id];
      set(el, horizontal ? 'top' : 'left', px(band.start * vp.zoom + off));
      set(el, horizontal ? 'height' : 'width', px(band.extent * vp.zoom));
      // With a panel, the fills stop short of it.
      if (band.fill) {
        set(el, 'left', px(sx(band.fill.from)));
        set(el, 'width', px((band.fill.to - band.fill.from) * vp.zoom));
      }
      set(el, 'background', mixHex(lane.tint, lane.tint_hl, s.level));
      set(el, 'opacity', String(s.opacity));
      el.dataset.cfHl = s.level >= 0.5 ? '1' : '0';
      const label = labelEls[lane.id];
      set(label, 'transform', `translate(${px(sx(band.label.x))}, ${px(sy(band.label.y))}) scale(${vp.zoom.toFixed(4)})`);
      set(label, 'opacity', String(s.opacity));
    }
    travels.forEach((tr, i) => {
      const tok = tokenAt(tr, t);
      const el = tokenEls[i];
      if (!tok) { set(el, 'display', 'none'); return; }
      const [fx, fy] = horizontal ? [tok.a, tok.c - tr.box.h / 2] : [tok.c - tr.box.w / 2, tok.a];
      place(el, vp, fx, fy, tok.opacity);
    });
    travels.forEach((tr, i) => {
      const el = chipEls[i];
      const chip = el && chipAt(tr, t);
      if (!el) return;
      if (!chip) { set(el, 'display', 'none'); return; }
      const [cx, cy] = flowXY(chip.a, chip.c);
      place(el, vp, cx - CHIP_R * chip.scale, cy - CHIP_R * chip.scale, chip.opacity, chip.scale);
    });
    if (panel) {
      const f = finale(t);
      place(panelEl, vp, panel.x, panel.y, 1);
      set(panelEl, 'borderColor', dark ? `rgba(255, 255, 255, ${(0.08 + 0.27 * f.border).toFixed(3)})` : `rgba(15, 23, 42, ${(0.08 + 0.27 * f.border).toFixed(3)})`);
      set(badgeEl, 'display', f.badge > 0 ? '' : 'none');
      set(badgeEl, 'opacity', f.badge.toFixed(3));
    }
    for (const [id, el] of Object.entries(cardEls)) {
      const card = cardAt(id, t);
      if (!card) { set(el, 'display', 'none'); continue; }
      place(el, vp, card.x, card.y, card.opacity);
    }
    // Which lanes run, for the lane stylesheet; highlight styling itself
    // is all CSS keyed on the runtime's data-cf-hl, so it is never
    // overwritten here.
    const root = document.getElementById('cf-diagram-root');
    if (root) {
      const on = laneIds.filter((id) => lanes[id].level >= 0.5).join(' ');
      if (root.getAttribute('data-cf-lanes-on') !== on) root.setAttribute('data-cf-lanes-on', on);
    }
    for (const id of laned) {
      const el = document.querySelector(`.react-flow__node[data-id="${CSS.escape(id)}"] .cf-node`);
      if (!el) continue;
      const s = pulseAt(id, t);
      set(el, 'transform', s === 1 ? '' : `scale(${s.toFixed(4)})`);
    }
  };

  window.__cfLanes = {
    layout: LAYOUT, bands, span, travels: travels.map(({ fn, ...rest }) => rest), slots: Object.fromEntries(Object.keys(slots).map((id) => [id, pos[id]])),
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
