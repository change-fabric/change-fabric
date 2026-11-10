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
# walkthrough_diagram_capture_test.rb: a dark scene with five coloured lanes
# and a pull request token travelling across each in turn while findings
# drop into a report column. Each band paints its tint (its highlight tint
# while its lane is highlighted), the token sits where the eased travel puts
# it at each sample time, the UX lint is clean, and two captures match.
class WalkthroughDiagramLanesCaptureTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/diagram-swimlanes", __dir__)
  CLOCK = "<script>(() => { let t = 0; performance.now = () => t; window.__cfAdvance = (ms) => (t += ms); })();</script>"
  SAMPLES = [ 100, 200, 650, 1100, 1650, 2100, 4650, 5900 ].freeze

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
            probe: probe(session, html, board["viewport"]) }
        end
      end
      assert_equal PrototypeCapture.frame_count(duration), runs[0][:frames].size
      assert_equal runs[0][:frames], runs[1][:frames], "swimlane frames differ between captures"
      assert_equal runs[0][:probe], runs[1][:probe], "swimlane probe differs between runs"
      runs.each { |r| assert_empty r[:lint] }

      samples = runs[0][:probe]
      lanes = WalkthroughDiagram.lane_colors(spec, root)
      rgb = ->(hex) { "rgb(#{hex.delete('#').scan(/../).map { |c| c.to_i(16) }.join(', ')})" }
      bands = samples.first["bands"]
      span = samples.first["span"]
      travels = spec["steps"].select { |s| s["op"] == "travel" }
      samples.each do |s|
        t = s["t"]
        live = travels.reverse.find { |st| st["t_ms"] <= t }
        lanes.each do |lane|
          hl = spec["steps"].select { |st| st["t_ms"] <= t && Array(st["ids"] || st["id"]).include?(lane["id"]) }.last
          want = hl && hl["op"] == "highlight" ? lane["tint_hl"] : lane["tint"]
          assert_equal rgb.(want), s["lanes"][lane["id"]]["bg"], "#{lane['id']} band at #{t} ms"
          assert_equal "1", s["lanes"][lane["id"]]["opacity"], "#{lane['id']} shows at #{t} ms"
        end
        # Bands stack top to bottom in spec order with no gaps.
        tops = lanes.map { |l| s["lanes"][l["id"]]["rect"] }
        tops.each_cons(2) { |a, b| assert_in_delta a["bottom"], b["top"], 0.5 }
        next assert_equal 0, s["pr"]["opacity"], "the token is hidden before it starts" unless live

        band = bands[live["lane"]]
        p = [ (t - live["t_ms"]).fdiv(live["duration"]), 1 ].min
        eased = p < 0.5 ? 4 * p**3 : 1 - ((-2 * p) + 2)**3 / 2
        x = span[0] + (span[1] - s["pr"]["w"] - span[0]) * eased
        assert_in_delta x, s["pr"]["x"], 0.6, "token x at #{t} ms"
        assert_in_delta band["start"] + (band["extent"] / 2.0), s["pr"]["y"] + 28, 0.6, "token rides the #{live['lane']} lane at #{t} ms"
      end
      # Findings drop into the report column, outside every lane's travel.
      last = samples.last
      %w[f-load f-a11y f-security f-cases].each do |id|
        assert_operator last["nodes"][id]["x"], :>, span[1], "#{id} sits in the report column"
        assert_equal 1, last["nodes"][id]["opacity"]
      end
    end
  end

  private

  def probe(session, html, viewport)
    code = <<~JS
      export default async function ({ page }) {
        await page.setViewport({ width: #{viewport['w']}, height: #{viewport['h']}, deviceScaleFactor: 1 });
        await page.setContent(#{JSON.generate(html.sub('<head>', "<head>#{CLOCK}"))});
        await page.waitForFunction('window.__cfDiagramReady === true', { timeout: 20000 });
        const out = [];
        let at = 0;
        for (const t of #{JSON.generate(SAMPLES)}) {
          await page.evaluate((step) => window.__cfAdvance(step), t - at);
          at = t;
          await page.evaluate(() => new Promise((r) => (window.__cfRealRaf || requestAnimationFrame)(() => (window.__cfRealRaf || requestAnimationFrame)(r))));
          out.push(await page.evaluate(() => {
            const lanes = {};
            for (const el of document.querySelectorAll('.cf-lane')) {
              const r = el.getBoundingClientRect();
              lanes[el.dataset.lane] = { bg: getComputedStyle(el).backgroundColor, opacity: el.style.opacity, rect: { top: r.top, bottom: r.bottom } };
            }
            const nodes = {};
            for (const el of document.querySelectorAll('.react-flow__node')) {
              const m = el.style.transform.match(/translate\\(([-\\d.]+)px, ([-\\d.]+)px\\)/);
              nodes[el.dataset.id] = { x: Number(m[1]), y: Number(m[2]), w: el.offsetWidth, opacity: Number(el.style.opacity || 0) };
            }
            return { t: performance.now(), lanes, nodes, pr: nodes.pr, bands: window.__cfLanes.bands, span: window.__cfLanes.span };
          }));
        }
        return { data: out, type: 'application/json' };
      }
    JS
    session.run_function(code)
  end
end
