# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_diagram"
require_relative "../scripts/walkthrough_storyboard"

# Swimlanes in the pinned browserless container, the companion of
# walkthrough_diagram_capture_test.rb: a dark scene with five coloured lanes,
# a pull request token travelling across each in turn on the lane's rail,
# and a result chip per lane carried into its row of the report panel. Bands
# paint their tint and light while their lane runs; the token never passes
# through a checkpoint and never moves right to left; handoffs overlap;
# result cards settle from just above their own slot without touching
# another; checkpoints pulse gently as the token passes; the UX lint is
# clean; and two captures give identical frames.
class WalkthroughDiagramLanesCaptureTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/diagram-swimlanes", __dir__)
  CLOCK = "<script>(() => { let t = 0; performance.now = () => t; window.__cfAdvance = (ms) => (t += ms); })();</script>"
  STEP_MS = 10
  EPS = 0.75

  def test_lanes_paint_and_the_token_travels_deterministically
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{FIXTURE}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      WalkthroughDiagram.write_screens(board, root)
      assert_empty WalkthroughStoryboard.validate(board, root: root)
      scene = board["scenes"].first
      spec = scene["diagram"]
      html = PrototypeCapture.inline_screen(File.join(root, scene.dig("screen", "html")), root: root)
      duration = PrototypeCapture.scene_duration(scene)
      runs = ChangeDocker.with_browserless(network: nil) do |session|
        2.times.map do |n|
          prep = PrototypeCapture.prepare(board, scene, root)
          out = File.join(root, "run-#{n}")
          PrototypeCapture.capture(session: session, html: html, interactions: [], duration_ms: duration, out_dir: out,
                                   state: prep[:state], prng_seed: prep[:prng_seed], viewport: board["viewport"], label: scene["id"])
          { frames: Dir[File.join(out, "*.png")].sort.map { |f| Digest::SHA256.file(f).hexdigest },
            lint: JSON.parse(File.read(File.join(out, PrototypeUxLint::REPORT)))["findings"],
            probe: probe(session, html, board["viewport"], duration) }
        end
      end
      assert_equal PrototypeCapture.frame_count(duration), runs[0][:frames].size
      assert_equal runs[0][:frames], runs[1][:frames], "swimlane frames differ between captures"
      assert_equal runs[0][:probe], runs[1][:probe], "swimlane probe differs between runs"
      runs.each { |r| assert_empty r[:lint] }

      @samples = runs[0][:probe]["samples"]
      @meta = runs[0][:probe]["meta"]
      @lanes = WalkthroughDiagram.lane_colors(spec, root)
      @travels = @meta["travels"]
      assert_equal spec["lanes"].size, @travels.count { |tr| tr["result"] }, "every lane delivers a result"

      check_bands
      check_token_rail_and_direction
      check_handoffs_overlap
      check_results
      check_pulses
      check_finale
    end
  end

  # Three variants of the fixture, each loaded once and probed at one moment:
  # a vertical lane's rail fits the token's full width inside its band; a
  # result with no report panel lands inside the opening frame even when it
  # sits far right of the lanes; and a highlight step on one checkpoint keeps
  # its accent border while its own lane is idle, with its React Flow node
  # and handles as wide as the card.
  def test_vertical_rails_standalone_results_and_node_highlight
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{FIXTURE}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      scene = board["scenes"].first
      base = scene["diagram"]
      vertical = variant(base) do |d|
        d.delete("report")
        d["lane_direction"] = "vertical"
        d["nodes"].find { |n| n["id"] == "pr" }["label"] = "Pull request"
      end
      standalone = variant(base) do |d|
        d.delete("report")
        d["nodes"].find { |n| n["id"] == "f-load" }["position"] = { "x" => 3000, "y" => 0 }
      end
      highlight = variant(base) { |d| d["steps"].insert(1, { "t_ms" => 100, "op" => "highlight", "id" => "check-cases" }) }
      htmls = [ vertical, standalone, highlight ].map do |d|
        scene["diagram"] = d
        assert_empty WalkthroughDiagram.spec_errors(d, 8000)
        WalkthroughDiagram.screen(scene, root: root, board: board)
      end
      v, s, h = ChangeDocker.with_browserless(network: nil) do |session|
        [ [ htmls[0], 650 ], [ htmls[1], 8000 ], [ htmls[2], 400 ] ].map { |html, t| session.run_function(snapshot_js(html, board["viewport"], t)) }
      end

      tok = v["tokens"][0]
      band = v["lanes"]["load"]
      assert_operator tok["left"], :>=, band["left"] - EPS, "the vertical token leaves its band"
      assert_operator tok["right"], :<=, band["right"] + EPS, "the vertical token leaves its band"
      v["checks"].each { |id, c| refute overlap?(tok, c), "the vertical token passes through #{id}" }

      card = s["cards"]["f-load"]
      refute_nil card, "the standalone result shows"
      assert_operator card["left"], :>=, -EPS, "the standalone result lands off screen"
      assert_operator card["right"], :<=, board["viewport"]["w"] + EPS, "the standalone result lands off screen"

      h["checks"].each do |id, c|
        assert_in_delta c["right"], c["wrap"]["right"], 1, "#{id}'s React Flow node is narrower than its card"
        assert_in_delta c["right"], (c["handle"]["left"] + c["handle"]["right"]) / 2, 8, "#{id}'s right handle sits inside its card"
      end
      refute_equal h["border"]["check-ux"], h["border"]["check-cases"], "the highlighted checkpoint loses its accent border"
      refute_equal "none", h["shadow"]["check-cases"], "the highlighted checkpoint loses its halo"
    end
  end

  private

  def variant(diagram) = JSON.parse(JSON.generate(diagram)).tap { |d| yield d }

  # Loads a screen, advances its clock to `t_ms`, and reports the lanes,
  # tokens, cards, and each checkpoint's box and computed border and shadow.
  def snapshot_js(html, viewport, t_ms)
    <<~JS
      export default async function ({ page }) {
        await page.setViewport({ width: #{viewport['w']}, height: #{viewport['h']}, deviceScaleFactor: 1 });
        await page.setContent(#{JSON.generate(html.sub('<head>', "<head>#{CLOCK}"))});
        await page.waitForFunction('window.__cfDiagramReady === true', { timeout: 20000 });
        for (let t = 0; t < #{t_ms}; t += #{STEP_MS}) await page.evaluate((step) => window.__cfAdvance(step), #{STEP_MS});
        const data = await page.evaluate(() => {
          const box = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom }; };
          const vis = (el) => el && el.style.display !== 'none' && Number(el.style.opacity || 1) > 0;
          const lanes = {};
          for (const el of document.querySelectorAll('.cf-lane')) lanes[el.dataset.lane] = box(el);
          const tokens = [...document.querySelectorAll('.cf-lane-front > [data-travel]')].map((el) => (vis(el) ? box(el) : null));
          const cards = {};
          for (const el of document.querySelectorAll('.cf-lane-card')) if (vis(el)) cards[el.dataset.id] = box(el);
          const checks = {}; const border = {}; const shadow = {};
          for (const el of document.querySelectorAll('.react-flow__node')) {
            if (!el.dataset.id.startsWith('check-')) continue;
            const inner = el.querySelector('.cf-node');
            const cs = getComputedStyle(inner);
            checks[el.dataset.id] = box(inner);
            checks[el.dataset.id].wrap = box(el);
            const handle = el.querySelector('.react-flow__handle-right');
            checks[el.dataset.id].handle = handle ? box(handle) : null;
            border[el.dataset.id] = cs.borderTopColor;
            shadow[el.dataset.id] = cs.boxShadow;
          }
          return { lanes, tokens, cards, checks, border, shadow };
        });
        return { data, type: 'application/json' };
      }
    JS
  end

  def at(t) = @samples.min_by { |s| (s["t"] - t).abs }

  def rgb(hex) = "rgb(#{hex.delete('#').scan(/../).map { |c| c.to_i(16) }.join(', ')})"

  def overlap?(a, b) = a["left"] < b["right"] - EPS && b["left"] < a["right"] - EPS && a["top"] < b["bottom"] - EPS && b["top"] < a["bottom"] - EPS

  # At rest every band wears its tint; mid travel only the running lane is lit.
  def check_bands
    @lanes.each { |l| assert_equal rgb(l["tint"]), at(50)["lanes"][l["id"]]["bg"], "#{l['id']} rests" }
    @travels.each do |tr|
      s = at(tr["t0"] + (tr["D"] / 2))
      @lanes.each do |l|
        want = l["id"] == tr["lane"] ? l["tint_hl"] : l["tint"]
        assert_equal rgb(want), s["lanes"][l["id"]]["bg"], "#{l['id']} band while #{tr['lane']} runs"
      end
    end
    @samples.each do |s|
      tops = @lanes.map { |l| s["lanes"][l["id"]]["rect"] }
      tops.each_cons(2) { |a, b| assert_in_delta a["bottom"], b["top"], 0.5 }
    end
  end

  # The token rides below every checkpoint, never moves back, and ends
  # clear of the widest checkpoint by the clearance.
  def check_token_rail_and_direction
    zoom = @meta["zoom"]
    reach = @samples.first["checks"].values.map { |c| c["right"] }.max
    @travels.each_with_index do |tr, i|
      seen = @samples.filter_map { |s| s["tokens"][i] }
      refute_empty seen, "travel #{i} shows its token"
      seen.each_cons(2) { |a, b| assert_operator b["left"], :>=, a["left"] - 1e-6, "travel #{i} moves right to left" }
      band = @samples.first["lanes"][tr["lane"]]["rect"]
      seen.each do |tok|
        assert_operator tok["top"], :>=, band["top"], "travel #{i} leaves its band"
        assert_operator tok["bottom"], :<=, band["bottom"], "travel #{i} leaves its band"
      end
      done = at(tr["t0"] + tr["D"] + 40)["tokens"][i]
      assert_operator done["left"], :>=, reach + (16 * zoom) - EPS, "travel #{i} ends clear of the checkpoints"
    end
    @samples.each do |s|
      s["tokens"].compact.each do |tok|
        s["checks"].each { |id, c| refute overlap?(tok, c), "the token passes through #{id} at #{s['t']} ms" }
      end
    end
  end

  # Each handoff: the outgoing token fades as the next one reveals, with a
  # moment where both show, and the next one enters from its own lane's left.
  def check_handoffs_overlap
    @travels.each_cons(2).with_index do |(_, b), i|
      both = @samples.select { |s| s["tokens"][i] && s["tokens"][i + 1] }
      refute_empty both, "handoff #{i} overlaps"
      both.each { |s| assert_operator s["tokens"][i]["opacity"] + s["tokens"][i + 1]["opacity"], :<=, 1.5 }
      first = @samples.find { |s| s["tokens"][i + 1] }
      assert_operator first["t"], :>=, b["t0"] - 140, "handoff #{i} reveals near its travel"
    end
  end

  # A chip carries each result to its slot; the card then settles from at
  # most 16 px above its own slot and never touches another card.
  def check_results
    zoom = @meta["zoom"]
    @travels.each_with_index do |tr, i|
      chip = @samples.select { |s| s["chips"][i] }
      refute_empty chip, "travel #{i} carries a chip"
      card_first = @samples.find { |s| s["cards"][tr["result"]] }
      assert_operator card_first["t"], :>=, chip.last["t"] - STEP_MS, "#{tr['result']} lands after its chip"
      slot_top = @samples.last["cards"][tr["result"]]["top"]
      @samples.each do |s|
        card = s["cards"][tr["result"]]
        next unless card

        assert_operator card["top"], :>=, slot_top - (16 * zoom) - EPS, "#{tr['result']} starts too high at #{s['t']} ms"
        assert_operator card["top"], :<=, slot_top + EPS, "#{tr['result']} overshoots its slot"
        (s["cards"].keys - [ tr["result"] ]).each { |o| refute overlap?(card, s["cards"][o]), "#{tr['result']} touches #{o} at #{s['t']} ms" }
        %w[left top].each { |k| assert_operator card[k], :>=, s["report"][k] - EPS, "#{tr['result']} leaves the panel" }
        %w[right bottom].each { |k| assert_operator card[k], :<=, s["report"][k] + EPS, "#{tr['result']} leaves the panel" }
      end
    end
  end

  # The panel counts the checks once the last result lands, never before.
  def check_finale
    last = @travels.map { |tr| tr["landAt"] }.max
    assert_nil at(last - 50)["report"]["badge"]
    assert_equal "#{@travels.size}/#{@travels.size} checks", @samples.last["report"]["badge"]
    assert_empty @samples.last["tokens"].compact, "the token leaves after the hold"
    assert @samples.find { |s| s["t"] > last + 100 && s["t"] < last + 700 }["tokens"].compact.any?, "the token holds after the last landing"
  end

  # Each checkpoint swells to at most 1.025 as the token passes, then rests.
  def check_pulses
    @samples.first["checks"].each_key do |id|
      scales = @samples.map { |s| s["scale"][id] }
      assert_operator scales.max, :>, 1.01, "#{id} pulses"
      assert_operator scales.max, :<=, 1.025 + 1e-6
      assert_equal 1.0, @samples.last["scale"][id]
    end
  end

  def probe(session, html, viewport, duration_ms) = session.run_function(probe_js(html, viewport, duration_ms))

  # Samples lanes, tokens, chips, cards, and checkpoints every STEP_MS.
  def probe_js(html, viewport, duration_ms)
    <<~JS
      export default async function ({ page }) {
        await page.setViewport({ width: #{viewport['w']}, height: #{viewport['h']}, deviceScaleFactor: 1 });
        await page.setContent(#{JSON.generate(html.sub('<head>', "<head>#{CLOCK}"))});
        await page.waitForFunction('window.__cfDiagramReady === true', { timeout: 20000 });
        const samples = [];
        for (let t = 0; t <= #{duration_ms}; t += #{STEP_MS}) {
          samples.push(await page.evaluate((step) => {
            if (step) window.__cfAdvance(step);
            const box = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, opacity: Number(el.style.opacity || 1) }; };
            const lanes = {};
            for (const el of document.querySelectorAll('.cf-lane')) lanes[el.dataset.lane] = { bg: getComputedStyle(el).backgroundColor, rect: box(el) };
            const vis = (el) => el && el.style.display !== 'none' && Number(el.style.opacity || 1) > 0;
            const tokens = [...document.querySelectorAll('.cf-lane-front > [data-travel]')].map((el) => (vis(el) ? box(el) : null));
            const chips = [...document.querySelectorAll('.cf-lane-chip')].map((el) => (vis(el) ? box(el) : null));
            const cards = {};
            for (const el of document.querySelectorAll('.cf-lane-card')) if (vis(el)) cards[el.dataset.id] = box(el);
            const checks = {}; const scale = {};
            for (const el of document.querySelectorAll('.react-flow__node')) {
              if (!el.dataset.id.startsWith('check-')) continue;
              const inner = el.querySelector('.cf-node');
              checks[el.dataset.id] = box(inner);
              const m = inner.style.transform.match(/scale\\(([\\d.]+)\\)/);
              scale[el.dataset.id] = m ? Number(m[1]) : 1;
            }
            const report = box(document.querySelector('.cf-lane-panel'));
            const badge = document.querySelector('.cf-lane-badge');
            report.badge = badge.style.display === 'none' ? null : badge.textContent;
            return { t: performance.now(), lanes, tokens, chips, cards, checks, scale, report };
          }, t === 0 ? 0 : #{STEP_MS}));
        }
        const zoom = await page.evaluate(() => Number(document.querySelector('.react-flow__viewport').style.transform.match(/scale\\(([\\d.]+)\\)/)[1]));
        const travels = await page.evaluate(() => window.__cfLanes.travels);
        return { data: { samples, meta: { zoom, travels } }, type: 'application/json' };
      }
    JS
  end
end
