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

# A React Flow diagram screen renders deterministically under the controlled
# clock: two captures in the pinned browserless container give identical
# frames, the page throws nothing, nothing leaves the page, the UX lint is
# clean, and the scripted steps actually change the picture.
class WalkthroughDiagramCaptureTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/diagram", __dir__)
  RUNTIME = File.expand_path("../scripts/vendor/xyflow/cf_diagram_runtime.js", __dir__)
  DURATION_MS = 2000
  VIEWPORT = { "w" => 1280, "h" => 720, "dpr" => 1 }.freeze

  # Passes run_function through and keeps every raw result, so the test sees
  # pageErrors and blockedRequests that capture itself does not return.
  class Recorder
    attr_reader :results

    def initialize(session)
      @session = session
      @results = []
    end

    def run_function(code, **opts)
      @session.run_function(code, **opts).tap { |r| @results << r }
    end

    def alive? = @session.alive?
  end

  def test_two_captures_produce_identical_frames
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      html = screen
      ChangeDocker.with_browserless(network: nil) do |session|
        runs = 2.times.map { |n| capture(Recorder.new(session), html, File.join(root, "run-#{n}")) }
        a, b = runs.map { |r| r[:hashes] }
        assert_equal PrototypeCapture.frame_count(DURATION_MS), a.size
        assert_equal a, b, "diagram frames differ between captures"
        refute_equal a.first, a.last, "the scripted steps change the picture"
        runs.each do |run|
          assert_empty run[:errors], "page errors: #{run[:errors].inspect}"
          assert_empty run[:blocked], "blocked requests: #{run[:blocked].inspect}"
          assert_empty run[:findings], "UX lint findings: #{run[:findings].inspect}"
        end
      end
    end
  end

  # The whole path an author takes: a storyboard diagram block, the
  # generator, the storyboard's frames prep, inline_screen, and a capture.
  def test_storyboard_diagram_scene_generates_and_captures
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{File.expand_path('fixtures/walkthrough/architecture', __dir__)}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      WalkthroughDiagram.write_screens(board, root)
      assert_empty WalkthroughStoryboard.validate(board, root: root)
      scene = board["scenes"].first
      prep = PrototypeCapture.prepare(board, scene, root)
      ChangeDocker.with_browserless(network: nil) do |session|
        recorder = Recorder.new(session)
        PrototypeCapture.capture(session: recorder, html: PrototypeCapture.inline_screen(prep[:html_path], root: root),
                                 interactions: [], duration_ms: PrototypeCapture.scene_duration(scene), out_dir: prep[:out_dir],
                                 state: prep[:state], prng_seed: prep[:prng_seed], viewport: board["viewport"], label: scene["id"])
        frames = Dir[File.join(prep[:out_dir], "*.png")].sort
        assert_equal PrototypeCapture.frame_count(PrototypeCapture.scene_duration(scene)), frames.size
        refute_equal Digest::SHA256.file(frames.first).hexdigest, Digest::SHA256.file(frames.last).hexdigest
        assert_empty recorder.results.flat_map { |r| Array(r["pageErrors"]) }
        assert_empty recorder.results.flat_map { |r| Array(r["blockedRequests"]) }
        assert_empty JSON.parse(File.read(File.join(prep[:out_dir], PrototypeUxLint::REPORT)))["findings"]
      end
    end
  end

  # An LR dagre layout under a virtual clock: ranks run left to right, a node
  # never moves once shown (add_node does not reflow), and whenever the
  # camera rests on a fit or a focus its targets sit above the caption band.
  def test_lr_dagre_layout_holds_still_and_clears_the_caption_band
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{File.expand_path('fixtures/walkthrough/diagram-lr', __dir__)}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      WalkthroughDiagram.write_screens(board, root)
      assert_empty WalkthroughStoryboard.validate(board, root: root)
      scene = board["scenes"].first
      html = PrototypeCapture.inline_screen(File.join(root, scene.dig("screen", "html")), root: root)
      samples = ChangeDocker.with_browserless(network: nil) { |session| probe(session, html, board["viewport"], PrototypeCapture.scene_duration(scene)) }
      band_top = board.dig("viewport", "h") * (1 - PrototypeUxLint::CAPTION_BAND)
      at = ->(t) { samples.min_by { |s| (s["t"] - t).abs } }

      flow = at.(0)["nodes"].to_h { |n| [ n["id"], n["flow"] ] }
      samples.each do |s|
        s["nodes"].each { |n| assert_equal flow[n["id"]], n["flow"], "#{n['id']} moved at #{s['t']} ms" }
      end
      x = ->(id) { flow[id][0] }
      assert_operator x.("client"), :<, x.("gateway")
      assert_operator x.("gateway"), :<, x.("orders")
      assert_operator x.("orders"), :<, x.("db")
      assert_equal x.("auth"), x.("orders"), "auth and orders share a rank"

      [ 0, 1500, 1790 ].each do |t|
        at.(t)["nodes"].select { |n| n["opacity"].positive? }.each do |n|
          assert_operator n["bottom"], :<=, band_top, "#{n['id']} reaches the caption band at #{t} ms"
          assert_operator n["top"], :>=, 0, "#{n['id']} is cut off at the top at #{t} ms"
        end
      end
      db = at.(2500)["nodes"].find { |n| n["id"] == "db" }
      assert_operator db["bottom"], :<=, band_top, "the focused node reaches the caption band"
    end
  end

  # flow dots under the virtual clock: none before the step or after the
  # last run, eased progress that only moves forward along the edge, each dot
  # on the edge's own path even while a node moves, and the same placement
  # on a second run.
  def test_flow_dots_glide_along_their_edge_deterministically
    skip "docker not available" unless ChangeDocker.available?

    Dir.mktmpdir do |root|
      FileUtils.cp_r("#{File.expand_path('fixtures/walkthrough/diagram-flow', __dir__)}/.", root)
      board = WalkthroughStoryboard.load(File.join(root, "storyboard.json"))
      WalkthroughDiagram.write_screens(board, root)
      assert_empty WalkthroughStoryboard.validate(board, root: root)
      scene = board["scenes"].first
      html = PrototypeCapture.inline_screen(File.join(root, scene.dig("screen", "html")), root: root)
      duration = PrototypeCapture.scene_duration(scene)
      runs = ChangeDocker.with_browserless(network: nil) do |session|
        2.times.map { probe(session, html, board["viewport"], duration, flow: true) }
      end
      # The probe samples without waiting on a painted frame, so React Flow
      # can be mid re-render of its edge layer on a sample right after a
      # move settles; compare the samples where both runs have their edges.
      assert_equal runs[0], runs[1], "flow dots differ between runs"
      samples = runs[0]
      at = ->(t) { samples.min_by { |s| (s["t"] - t).abs } }
      dots = ->(t, edge) { at.(t)["flows"].fetch(edge, []) }

      assert_empty dots.(150, "e1"), "no dot before the step"
      assert_equal 3, dots.(800, "e1").size, "three staggered dots mid-flow"
      assert_empty dots.(1800, "e1"), "dots gone after the run"
      # The lead dot advances along the edge, eased: slow, fast, slow.
      lead = (200..1190).step(10).map { |t| dots.(t, "e1").first }.compact.map { |d| d["frac"] }
      assert lead.each_cons(2).all? { |a, b| b >= a - 1e-6 }, "progress only moves forward"
      assert_operator lead.first, :<, 0.05
      assert_operator lead.last, :>, 0.95
      # Two runs of two dots on e2, the second batch after the first.
      assert_operator dots.(2300, "e2").size, :>, 0, "second repeat runs"
      assert_empty dots.(3200, "e2"), "repeat 2 ends"
      # While db moves, every e2 dot sits on the path as drawn that frame.
      assert_operator dots.(1700, "e2").size, :>, 0, "dots stay on screen while a node moves"
      (1400..2000).step(10).each do |t|
        dots.(t, "e2").each { |d| assert_operator d["off"], :<, 0.5, "dot left its edge at #{t} ms" }
      end
    end
  end

  def test_a_screen_that_never_gets_ready_fails_loudly
    skip "docker not available" unless ChangeDocker.available?

    html = "<html><head></head><body><script>window.__cfDiagramReady = false;</script></body></html>"
    stub_const(:DIAGRAM_READY_TIMEOUT_MS, 500) do
      Dir.mktmpdir do |root|
        ChangeDocker.with_browserless(network: nil) do |session|
          err = assert_raises(PrototypeCapture::UnsupportedContentError) do
            PrototypeCapture.capture(session: session, html: html, interactions: [], duration_ms: 100, out_dir: root,
                                     state: nil, prng_seed: 1, viewport: VIEWPORT, label: "stuck")
          end
          assert_match(/never set __cfDiagramReady/, err.message)
        end
      end
    end
  end

  private

  def stub_const(name, value)
    old = PrototypeCapture.const_get(name)
    PrototypeCapture.send(:remove_const, name)
    PrototypeCapture.const_set(name, value)
    yield
  ensure
    PrototypeCapture.send(:remove_const, name)
    PrototypeCapture.const_set(name, old)
  end

  # Inlines the bundle and runtime by hand, as the Phase 3 generator will.
  # inline_screen is not used: it scans inlined script text for src/srcset
  # attributes and trips on string literals inside the React DOM bundle.
  def screen
    html = File.read(File.join(FIXTURE, "screen.html"))
    { "xyflow.js" => WalkthroughDiagram::XYFLOW_BUNDLE, "runtime.js" => RUNTIME }.each do |src, file|
      body = File.read(file).gsub("</script", "<\\/script")
      html = html.sub(%(<script src="#{src}"></script>)) { "<script>#{body}</script>" }
    end
    html
  end

  # A virtual clock the runtime drives itself from, so each sample is the
  # state at an exact time without a full frame capture.
  CLOCK = "<script>(() => { let t = 0; performance.now = () => t; window.__cfAdvance = (ms) => (t += ms); })();</script>"
  STEP_MS = 10

  # Node rects (viewport px), flow-space centres, and opacity every STEP_MS.
  FLOW_PROBE = <<~JS
    const flows = {};
    for (const edge of document.querySelectorAll('.react-flow__edge')) {
      const path = edge.querySelector('.react-flow__edge-path');
      const len = path.getTotalLength();
      flows[edge.dataset.id] = [...edge.querySelectorAll('g.cf-flow > g')].map((dot) => {
        const m = dot.getAttribute('transform').match(/translate\\(([-\\d.]+) ([-\\d.]+)\\)/);
        const x = Number(m[1]); const y = Number(m[2]);
        let best = { off: Infinity, frac: 0 };
        for (let i = 0; i <= 400; i += 1) {
          const p = path.getPointAtLength((len * i) / 400);
          const off = Math.hypot(p.x - x, p.y - y);
          if (off < best.off) best = { off, frac: i / 400 };
        }
        return { frac: best.frac, off: Math.min(best.off, 99), alpha: Number(dot.getAttribute('opacity')) };
      });
    }
    out.flows = flows;
  JS

  def probe(session, html, viewport, duration_ms, flow: false)
    code = <<~JS
      export default async function ({ page }) {
        await page.setViewport({ width: #{viewport['w']}, height: #{viewport['h']}, deviceScaleFactor: 1 });
        await page.setContent(#{JSON.generate(html.sub('<head>', "<head>#{CLOCK}"))});
        await page.waitForFunction('window.__cfDiagramReady === true', { timeout: 20000 });
        const samples = [];
        for (let t = 0; t <= #{duration_ms}; t += #{STEP_MS}) {
          // A flow probe waits two painted frames after each advance, as the
          // capture does, so React Flow has redrawn edges a move reshaped.
          if (#{flow} && t > 0) {
            await page.evaluate((step) => window.__cfAdvance(step), #{STEP_MS});
            await page.evaluate(() => new Promise((r) => (window.__cfRealRaf || requestAnimationFrame)(() => (window.__cfRealRaf || requestAnimationFrame)(r))));
          }
          samples.push(await page.evaluate((step) => {
            if (step) window.__cfAdvance(step);
            const nodes = [...document.querySelectorAll('.react-flow__node')].map((el) => {
              const r = el.getBoundingClientRect();
              const m = el.style.transform.match(/translate\\(([-\\d.]+)px, ([-\\d.]+)px\\)/);
              return { id: el.dataset.id, opacity: Number(el.style.opacity || 0), top: r.top, bottom: r.bottom, flow: m ? [Number(m[1]) + el.offsetWidth / 2, Number(m[2]) + el.offsetHeight / 2] : null };
            });
            const out = { t: performance.now(), nodes };
            #{FLOW_PROBE if flow}
            return out;
          }, t === 0 || #{flow} ? 0 : #{STEP_MS}));
        }
        return { data: samples, type: 'application/json' };
      }
    JS
    session.run_function(code)
  end

  def capture(recorder, html, out)
    PrototypeCapture.capture(session: recorder, html: html, interactions: [], duration_ms: DURATION_MS, out_dir: out,
                             state: nil, prng_seed: 1, viewport: VIEWPORT, label: "diagram")
    report = JSON.parse(File.read(File.join(out, PrototypeUxLint::REPORT)))
    { hashes: Dir[File.join(out, "*.png")].sort.map { |f| Digest::SHA256.file(f).hexdigest },
      errors: recorder.results.flat_map { |r| Array(r["pageErrors"]) },
      blocked: recorder.results.flat_map { |r| Array(r["blockedRequests"]) },
      findings: report["findings"] }
  end
end
