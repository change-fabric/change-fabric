# frozen_string_literal: true

require "json"
require_relative "../../scripts/diagram_text_fit"

# The swimlane invariants every laned screen must hold, shared by the
# fixture capture tests and the generated ones: run `probe_js` in a
# browserless session, then `assert_lane_invariants` on what it returns.
# At each sampled moment:
# - no text runs outside its box: every node, token, lane name, report row,
#   and the report heading holds its text (measured as rendered);
# - every laned node lies inside its band, every row inside the panel;
# - each React Flow node, its handles, and each card match the layout
#   record's box within 1 unit;
# - everything on screen lies inside the viewport;
# - an authored highlight keeps the runtime's highlight ring;
# - the layout record's lines and widths agree with DiagramTextFit;
# - no authored id is a reserved `__cf_` id.
module LaneInvariants
  CLOCK = "<script>(() => { let t = 0; performance.now = () => t; window.__cfAdvance = (ms) => (t += ms); })();</script>"
  EPS = 0.75

  module_function

  # Loads `html` once and reports the scene at each time in `times` (ms,
  # rising), advancing the clock straight to each.
  def probe_js(html, viewport, times)
    <<~JS
      export default async function ({ page }) {
        await page.setViewport({ width: #{viewport['w']}, height: #{viewport['h']}, deviceScaleFactor: 1 });
        await page.setContent(#{JSON.generate(html.sub('<head>', "<head>#{CLOCK}"))});
        await page.waitForFunction('window.__cfDiagramReady === true', { timeout: 20000 });
        const samples = [];
        let now = 0;
        for (const t of #{JSON.generate(times)}) {
          samples.push(await page.evaluate((step) => {
            if (step > 0) window.__cfAdvance(step);
            const rect = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }; };
            const textRect = (el) => {
              if (!el || !el.textContent.trim()) return null;
              const range = document.createRange(); range.selectNodeContents(el); return rect(range);
            };
            const shown = (el) => el && el.style.display !== 'none' && Number(el.style.opacity || 1) > 0;
            const m = document.querySelector('.react-flow__viewport').style.transform.match(/translate\\(([-\\d.e]+)px,\\s*([-\\d.e]+)px\\)\\s*scale\\(([-\\d.e]+)\\)/);
            const vp = { x: Number(m[1]), y: Number(m[2]), zoom: Number(m[3]) };
            const nodes = {};
            for (const el of document.querySelectorAll('.react-flow__node')) {
              const id = el.dataset.id;
              if (id.startsWith('__cf_') || Number(getComputedStyle(el).opacity) === 0) continue;
              const inner = el.querySelector('.cf-node');
              const handle = el.querySelector('.react-flow__handle-right');
              const cs = getComputedStyle(inner);
              nodes[id] = { wrap: rect(el), box: rect(inner), w: inner.offsetWidth, h: inner.offsetHeight, text: textRect(inner.querySelector('.cf-node-label')),
                handle: handle ? rect(handle) : null, hl: el.dataset.cfHl === '1', shadow: cs.boxShadow };
            }
            const front = (sel) => [...document.querySelectorAll(sel)].filter(shown).map((el) => ({ id: el.dataset.id || el.dataset.travel, box: rect(el),
              text: textRect(el.classList.contains('cf-node') ? el.querySelector('.cf-node-label') : el), w: el.offsetWidth, h: el.offsetHeight }));
            const labels = [...document.querySelectorAll('.cf-lane-label')].filter((el) => Number(el.style.opacity || 1) > 0)
              .map((el) => ({ box: rect(el), text: textRect(el) }));
            const bands = {};
            for (const el of document.querySelectorAll('.cf-lane')) bands[el.dataset.lane] = rect(el);
            const panelEl = document.querySelector('.cf-lane-panel');
            const headEl = document.querySelector('.cf-lane-panel-head');
            return { t: performance.now(), vp, nodes, bands, labels, tokens: front('.cf-lane-token'), cards: front('.cf-lane-card'),
              panel: panelEl ? rect(panelEl) : null, head: headEl ? { box: rect(headEl), text: textRect(headEl) } : null };
          }, t - now));
          now = t;
        }
        const layout = await page.evaluate(() => window.__cfLanes.layout);
        return { data: { samples, layout }, type: 'application/json' };
      }
    JS
  end

  def inside?(inner, outer, eps = EPS)
    inner["left"] >= outer["left"] - eps && inner["right"] <= outer["right"] + eps &&
      inner["top"] >= outer["top"] - eps && inner["bottom"] <= outer["bottom"] + eps
  end

  def show(r) = r && format("[%.1f %.1f %.1f %.1f]", r["left"], r["top"], r["right"], r["bottom"])

  # `tag` starts every failure message: the seed and spec for a generated
  # case, so the failure reproduces with it alone.
  def assert_lane_invariants(test, probe, spec, viewport, tag:)
    layout = probe["layout"]
    horizontal = spec["lane_direction"] != "vertical"
    frame = { "left" => 0, "top" => 0, "right" => viewport["w"], "bottom" => viewport["h"] }
    authored = spec["nodes"].map { |n| n["id"] } + spec["lanes"].map { |l| l["id"] }
    test.assert(authored.none? { |id| id.start_with?("__cf_") }, "#{tag}: an authored id is reserved")
    check_record(test, layout, spec, horizontal, tag)
    probe["samples"].each do |s|
      at = "#{tag} t=#{s['t']}"
      check_text(test, s, at)
      check_nodes(test, s, layout, spec, horizontal, at)
      check_panel(test, s, at)
      check_frame(test, s, frame, at)
      check_highlight(test, s, spec, at)
    end
  end

  def check_text(test, s, at)
    boxes = s["nodes"].map { |id, n| [ "node #{id}", n["text"], n["box"] ] } +
            s["tokens"].map { |t| [ "token #{t['id']}", t["text"], t["box"] ] } +
            s["cards"].map { |c| [ "card #{c['id']}", c["text"], c["box"] ] } +
            s["labels"].map { |l| [ "lane name", l["text"], l["box"] ] } +
            [ s["head"] && [ "report heading", s["head"]["text"], s["head"]["box"] ] ].compact
    boxes.each do |what, text, box|
      next unless text

      test.assert(inside?(text, box), "#{at}: #{what} text #{show(text)} overflows its box #{show(box)}")
    end
  end

  def check_nodes(test, s, layout, spec, horizontal, at)
    vp = s["vp"]
    z = vp["zoom"]
    lanes = spec["nodes"].to_h { |n| [ n["id"], n["lane"] ] }
    s["nodes"].each do |id, n|
      b = layout["boxes"][id] or next
      flow = { "x" => (n["wrap"]["left"] - vp["x"]) / z, "y" => (n["wrap"]["top"] - vp["y"]) / z,
               "w" => (n["wrap"]["right"] - n["wrap"]["left"]) / z, "h" => (n["wrap"]["bottom"] - n["wrap"]["top"]) / z }
      %w[x y w h].each { |k| test.assert_in_delta(b[k], flow[k], 1, "#{at}: #{id} React Flow #{k} drifts from its layout box") }
      test.assert_in_delta(b["w"], n["w"], 1, "#{at}: #{id} card width drifts from its layout box")
      test.assert_in_delta(b["h"], n["h"], 1, "#{at}: #{id} card height drifts from its layout box")
      if n["handle"]
        mid = (n["handle"]["left"] + n["handle"]["right"]) / 2
        test.assert_in_delta(n["wrap"]["right"], mid, 8, "#{at}: #{id}'s right handle sits off its card")
      end
      band = lanes[id] && s["bands"][lanes[id]]
      next unless band

      keys = horizontal ? %w[top bottom] : %w[left right]
      test.assert_operator(n["wrap"][keys[0]], :>=, band[keys[0]] - EPS, "#{at}: #{id} leaves its band")
      test.assert_operator(n["wrap"][keys[1]], :<=, band[keys[1]] + EPS, "#{at}: #{id} leaves its band")
    end
  end

  def check_panel(test, s, at)
    return unless s["panel"]

    s["cards"].each { |c| test.assert(inside?(c["box"], s["panel"]), "#{at}: row #{c['id']} #{show(c['box'])} leaves the panel #{show(s['panel'])}") }
  end

  def check_frame(test, s, frame, at)
    things = s["nodes"].map { |id, n| [ "node #{id}", n["wrap"] ] } + s["labels"].map { |l| [ "lane name", l["box"] ] } +
             s["tokens"].map { |t| [ "token", t["box"] ] } + s["cards"].map { |c| [ "card #{c['id']}", c["box"] ] } +
             [ s["panel"] && [ "panel", s["panel"] ] ].compact
    things.each { |what, box| test.assert(inside?(box, frame), "#{at}: #{what} #{show(box)} is outside the frame") }
  end

  def check_highlight(test, s, spec, at)
    hl = spec["steps"].find { |st| st["op"] == "highlight" && st["id"] && spec["nodes"].any? { |n| n["id"] == st["id"] } }
    return unless hl && s["t"] >= hl["t_ms"] + 300 && s["nodes"][hl["id"]]

    n = s["nodes"][hl["id"]]
    test.assert(n["hl"], "#{at}: #{hl['id']} lost its highlight state")
    test.assert_match(/0px 0px 0px 4px/, n["shadow"], "#{at}: #{hl['id']} lost the runtime's highlight ring")
  end

  # The record in the browser agrees with the Ruby estimate: checkpoint
  # lines, token widths, and lane name widths.
  def check_record(test, layout, spec, horizontal, tag)
    fc = DiagramTextFit::FIT["checkpoint"]
    spec["nodes"].each do |n|
      next unless horizontal && n["lane"]

      want = DiagramTextFit.lines(n["label"], fc["font"], DiagramTextFit.room("checkpoint", icon: n["icon"])).size
      test.assert_equal([ want, 1 ].max, layout["boxes"][n["id"]]["lines"], "#{tag}: #{n['id']} lines disagree with DiagramTextFit")
    end
    tok = spec["steps"].find { |s| s["op"] == "travel" && s["id"] }
    if tok
      n = spec["nodes"].find { |x| x["id"] == tok["id"] }
      f = DiagramTextFit::FIT["token"]
      want = ((DiagramTextFit.width(n["label"], f["font"]) + 28 + (n["icon"] ? f["icon"] : 0)) / 2.0).round * 2
      test.assert_equal(want, layout["tokens"][n["id"]]["w"], "#{tag}: token width disagrees with DiagramTextFit")
    end
    spec["lanes"].each_with_index do |l, i|
      f = DiagramTextFit::FIT["lane_label"]
      want = ((16 + (l["icon"] ? f["icon"] : 0) + DiagramTextFit.width(l["label"], f["font"])) / 2.0).round * 2
      test.assert_equal(want, layout["bands"][i]["label"]["w"], "#{tag}: lane #{l['id']} name width disagrees with DiagramTextFit")
    end
  end
end
