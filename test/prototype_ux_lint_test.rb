# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/prototype_ux_lint"

# The pure halves of the UX lint run everywhere; the browser rules run each
# small HTML fixture through the pinned browserless container, so they skip
# where docker is not available (as color_check_test does).
class PrototypeUxLintTest < Minitest::Test
  def test_browser_js_parses
    skip "node not available" unless system("node", "-e", "0", out: File::NULL, err: File::NULL)
    out = IO.popen([ "node", "-e", "new Function(process.argv[1]); console.log('ok')", PrototypeUxLint::BROWSER_JS ], &:read)
    assert_equal "ok", out.strip
  end

  def test_lint_frames_cover_start_middle_end_steps_and_settle
    plan = PrototypeCapture.schedule([
      { "t_ms" => 0, "op" => "move", "target" => "#a", "duration_ms" => 100 },
      { "t_ms" => 500, "op" => "click", "target" => "#a" }
    ], 60)
    assert_equal [ 0, 2, 15, 30, 59 ], PrototypeUxLint.lint_frames(plan, 60)
  end

  def test_merge_collapses_repeats_and_ignores_coordinates
    raw = [ { "frame" => 4, "rule" => "occlusion", "target" => "#b", "detail" => "covered by #t at 1,2" },
            { "frame" => 9, "rule" => "occlusion", "target" => "#b", "detail" => "covered by #t at 3,4" },
            { "frame" => 1, "rule" => "clipped-text", "target" => "#c", "detail" => "x" } ]
    merged = PrototypeUxLint.merge(raw)
    assert_equal [ [ "clipped-text", 1 ], [ "occlusion", 2 ] ], merged.map { |f| [ f["rule"], f["frames"] ] }
    assert_equal 4, merged.last["frame"]
  end

  def test_gate_blocks_any_finding_unless_allowed
    clean = PrototypeUxLint.scene_report("a", [])
    dirty = PrototypeUxLint.scene_report("b", [ { "frame" => 0, "rule" => "empty-control", "target" => "#t", "detail" => "d" } ])
    assert_nil PrototypeUxLint.gate!([ clean ])
    err = assert_raises(PrototypeUxLint::FindingsError) { PrototypeUxLint.gate!([ clean, dirty ]) }
    assert_includes err.message, "b: empty-control #t (frame 0): d"
    assert_nil PrototypeUxLint.gate!([ dirty ], allow: true)
  end

  def test_read_ignores_reports_from_another_version
    Dir.mktmpdir do |dir|
      PrototypeUxLint.write(dir, PrototypeUxLint.scene_report("a", []).merge("version" => 0))
      assert_nil PrototypeUxLint.read(dir)
      PrototypeUxLint.write(dir, PrototypeUxLint.scene_report("a", []))
      assert_equal "a", PrototypeUxLint.read(dir)["scene"]
    end
  end

  # -- browser rules ---------------------------------------------------------

  STYLE = "<style>body{margin:0;font:16px sans-serif} button{font:16px sans-serif;padding:12px 24px;display:inline-flex;gap:8px;align-items:center}" \
          ".i{display:inline-block;width:20px;height:20px;background:#fff;-webkit-mask-image:linear-gradient(#000,#000);mask-image:linear-gradient(#000,#000)}" \
          ".toast{position:absolute;left:10px;top:10px;width:300px;padding:12px;background:#222;color:#fff;display:flex;gap:8px}</style>"

  FIXTURES = {
    "empty-toast" => [ '<div class="toast" role="status"><span class="i">Saved</span><span></span></div>', %w[empty-control] ],
    "labelled-toast" => [ '<div class="toast" role="status"><span class="i"></span><span>Saved</span></div>', [] ],
    "unnamed-button" => [ '<button id="b" style="width:200px"><svg width="20" height="20"></svg></button>', %w[empty-control] ],
    "icon-button" => [ '<button id="b" aria-label="Send" style="width:40px;height:40px;padding:0"><svg width="20" height="20"></svg></button>', [] ],
    "occluded" => [ '<button id="b" style="position:absolute;left:20px;top:20px">Confirm return</button><div class="toast" role="status">Done</div>',
                    %w[occlusion] ],
    "inert-behind-sheet" => [ '<div inert><button style="position:absolute;left:20px;top:20px">Confirm</button></div>' \
                              '<div class="toast" role="dialog">Approve loan?</div>', [] ],
    "clipped" => [ '<div style="width:60px;overflow:hidden;white-space:nowrap">A very long label here</div>', %w[clipped-text] ],
    "pending-success" => [ '<div data-cf-state="pending"><span data-cf-success>Approved</span></div>', %w[contradictory-state] ],
    "stale-actions" => [ '<div data-cf-state="approved"><span data-cf-success>Approved</span><button data-cf-when="pending">Approve</button></div>',
                         %w[contradictory-state] ],
    "agreed-state" => [ '<div data-cf-state="approved"><span data-cf-success>Approved</span><button data-cf-when="approved">Message</button></div>', [] ]
  }.freeze

  LABEL_BUTTON = '<button id="b" style="position:absolute;left:100px;top:100px"><span class="i"></span><span>Mark returned</span></button>'
  WIDE_BUTTON = '<button id="w" style="position:absolute;left:100px;top:100px;width:400px;height:80px;justify-content:flex-start">Go</button>'

  def html(body) = "<html><head>#{STYLE}</head><body>#{body}</body></html>"

  def lint(session, body, interactions: [])
    Dir.mktmpdir do |dir|
      PrototypeCapture.lint_only(session: session, html: html(body), interactions: interactions, duration_ms: 100,
                                 out_dir: dir, state: {}, prng_seed: 1, viewport: { "w" => 640, "h" => 360, "dpr" => 1 })
    end
  end

  def capture(session, body, target)
    Dir.mktmpdir do |dir|
      PrototypeCapture.capture(session: session, html: html(body), interactions: [ { "t_ms" => 0, "op" => "move", "target" => target, "duration_ms" => 33 } ],
                               duration_ms: 100, out_dir: dir, state: {}, prng_seed: 1, viewport: { "w" => 640, "h" => 360, "dpr" => 1 })
      [ JSON.parse(File.read(File.join(dir, "cursor.json"))).last, JSON.parse(File.read(File.join(dir, PrototypeUxLint::REPORT))) ]
    end
  end

  def test_browser_rules_against_fixtures
    skip "docker not available" unless ChangeDocker.available?
    ChangeDocker.with_browserless(network: nil) do |session|
      FIXTURES.each do |name, (body, rules)|
        assert_equal rules, lint(session, body)["findings"].map { |f| f["rule"] }.uniq, name
      end
      move = [ { "t_ms" => 0, "op" => "move", "target" => "#b", "duration_ms" => 33 } ]
      assert_equal %w[cursor-over-label], lint(session, LABEL_BUTTON, interactions: move)["findings"].map { |f| f["rule"] }

      point, report = capture(session, LABEL_BUTTON, "#b")
      assert_empty report["findings"], "safe aim clears the label"
      assert_operator point["x"], :>, 200, "aimed at the label's end padding, right of the text"

      point, = capture(session, WIDE_BUTTON, "#w")
      assert_equal [ 300.0, 140.0 ], [ point["x"], point["y"] ], "a clear centre keeps the old aim, so clean frames do not change"
    end
  end
end
