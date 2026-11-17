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
    assert_includes err.message, "empty-control #t in b (frame 0): d"
    assert_includes err.message, "1 finding(s) across 1 scene(s)"
    assert_nil PrototypeUxLint.gate!([ dirty ], allow: true)
  end

  def test_summary_dedupes_across_scenes_and_labels_findings
    nav = { "frame" => 3, "rule" => "clipped-text", "target" => "body > div > nav > a:nth-of-type(7)",
            "label" => "link \"Settings\"", "detail" => "text cut off" }
    reports = %w[one two three].map { |id| PrototypeUxLint.scene_report(id, [ nav ]) }
    lines = PrototypeUxLint.summary_lines(reports)
    assert_equal [ "clipped-text link \"Settings\" in one, two, three (frame 3): text cut off [body > div > nav > a:nth-of-type(7)]" ], lines
    assert_equal "1 finding(s) across 3 scene(s)", PrototypeUxLint.summary(reports)
    assert_equal "PASS (2 scene(s))", PrototypeUxLint.summary([ PrototypeUxLint.scene_report("a", []), PrototypeUxLint.scene_report("b", []) ])
  end

  def test_caption_safe_and_occlusion_are_advisory_on_live_scenes
    raw = %w[caption-safe occlusion].map { |rule| { "frame" => 0, "rule" => rule, "target" => "#row", "detail" => "d" } }
    live = PrototypeUxLint.scene_report("app", raw)
    assert_nil PrototypeUxLint.gate!([ live ], live: [ "app" ])
    assert_raises(PrototypeUxLint::FindingsError) { PrototypeUxLint.gate!([ live ]) }
    clipped = PrototypeUxLint.scene_report("app", raw + [ { "frame" => 0, "rule" => "clipped-text", "target" => "#t", "detail" => "d" } ])
    err = assert_raises(PrototypeUxLint::FindingsError) { PrototypeUxLint.gate!([ clipped ], live: [ "app" ]) }
    assert_includes err.message, "1 finding(s) across 1 scene(s)"
  end

  def test_read_ignores_reports_from_another_version
    Dir.mktmpdir do |dir|
      PrototypeUxLint.write(dir, PrototypeUxLint.scene_report("a", []).merge("version" => 0))
      assert_nil PrototypeUxLint.read(dir)
      PrototypeUxLint.write(dir, PrototypeUxLint.scene_report("a", []))
      assert_equal "a", PrototypeUxLint.read(dir)["scene"]
    end
  end

  def dev(frame, w, h, lw: 390, lh: 844) = { "frame" => frame, "target" => ".phone", "w" => w, "h" => h, "lw" => lw, "lh" => lh }

  def device_rules(samples_by_scene, zoom: {})
    reports = samples_by_scene.map { |id, d| PrototypeUxLint.scene_report(id, [], devices: d) }
    PrototypeUxLint.device_findings(reports, zoom: zoom).transform_values { |f| f.map { |x| x["detail"][/\A\w+/] } }
  end

  def test_device_frame_keeps_shape_and_size_across_scenes
    same = { "a" => [ dev(0, 405.6, 877.8) ], "b" => [ dev(0, 405.6, 877.8), dev(9, 405.6, 877.8) ] }
    assert_equal({ "a" => [], "b" => [] }, device_rules(same))
    assert_equal [ "layout" ], device_rules({ "a" => [ dev(0, 405.6, 877.8) ], "b" => [ dev(0, 643.5, 924, lw: 390, lh: 560) ] })["b"]
    assert_equal [ "aspect" ], device_rules({ "a" => [ dev(0, 400, 866) ], "b" => [ dev(0, 600, 866) ] })["b"]
    grown = { "a" => [ dev(0, 400, 866) ], "b" => [ dev(0, 480, 1039.2) ] }
    assert_equal [ "rendered" ], device_rules(grown)["b"]
    assert_equal [], device_rules(grown, zoom: { "b" => 1.2 })["b"], "a declared camera zoom may resize uniformly"
    assert_equal [ "rendered" ], device_rules(grown, zoom: { "b" => 1.1 })["b"]
  end

  def test_prior_aim_follows_a_stale_report
    Dir.mktmpdir do |dir|
      assert_equal "centre", PrototypeUxLint.prior_aim(dir)
      PrototypeUxLint.write(dir, PrototypeUxLint.scene_report("a", []).merge("version" => 1, "aim" => "safe"))
      assert_equal "safe", PrototypeUxLint.prior_aim(dir)
    end
  end

  # -- browser rules ---------------------------------------------------------

  STYLE = "<style>body{margin:0;font:16px sans-serif} button{font:16px sans-serif;padding:12px 24px;display:inline-flex;gap:8px;align-items:center}" \
          ".i{display:inline-block;width:20px;height:20px;background:#fff;-webkit-mask-image:linear-gradient(#000,#000);mask-image:linear-gradient(#000,#000)}" \
          ".toast{position:absolute;left:10px;top:10px;width:300px;padding:12px;background:#222;color:#fff;display:flex;gap:8px}</style>"

  FIXTURES = {
    "empty-toast" => [ '<div class="toast" role="status"><span class="i">Saved</span><span></span></div>', %w[empty-control] ],
    "idle-status-line" => [ '<div class="cfm-status" role="status" style="padding:0 16px 8px"></div>', [] ],
    "idle-inline-status" => [ '<span class="status" role="status" style="display:inline-block;padding:0 16px 10px"></span>', [] ],
    "idle-alert" => [ '<div role="alert" style="padding:8px"></div>', [] ],
    "idle-aria-live" => [ '<div aria-live="polite" role="status" style="padding:8px"></div>', [] ],
    "empty-toast-surface" => [ '<div class="toast" role="status" style="padding:8px"></div>', %w[empty-control] ],
    "filled-status-line" => [ '<div class="cfm-status" role="status" style="padding:0 16px 8px">Delivered</div>', [] ],
    "labelled-toast" => [ '<div class="toast" role="status"><span class="i"></span><span>Saved</span></div>', [] ],
    "unnamed-button" => [ '<button id="b" style="width:200px"><svg width="20" height="20"></svg></button>', %w[empty-control] ],
    "input-submit" => [ '<input type="submit" value="Save">', [] ],
    "input-button" => [ '<input type="button" value="Save">', [] ],
    "input-submit-default" => [ '<input type="submit">', [] ],
    "input-reset-default" => [ '<input type="reset">', [] ],
    "input-button-empty" => [ '<input type="button" value="">', %w[empty-control] ],
    "input-button-invisible-label" => [ '<input type="button" value="Save" style="color:transparent;width:200px">', %w[empty-control] ],
    "icon-button" => [ '<button id="b" aria-label="Send" style="width:40px;height:40px;padding:0"><svg width="20" height="20"></svg></button>', [] ],
    "occluded" => [ '<button id="b" style="position:absolute;left:20px;top:20px">Confirm return</button><div class="toast" role="status">Done</div>',
                    %w[occlusion] ],
    "inert-behind-sheet" => [ '<div inert><button style="position:absolute;left:20px;top:20px">Confirm</button></div>' \
                              '<div class="toast" role="dialog">Approve loan?</div>', [] ],
    "clipped" => [ '<div style="width:60px;overflow:hidden;white-space:nowrap">A very long label here</div>', %w[clipped-text] ],
    "inside-scrollable-nav" => [ '<nav style="position:absolute;top:20px;width:200px;height:60px;overflow:auto">' \
                                 '<a href="#a">One</a><br><a href="#b">Two</a><br><a href="#c">Three</a><br><a href="#d">Four</a></nav>', [] ],
    "scroll-box-cut-by-outer-frame" => [ '<div style="position:absolute;top:20px;width:200px;height:40px;overflow:hidden">' \
                                         '<div style="height:200px;overflow:auto"><button style="margin-top:20px">Ask Dana</button></div></div>',
                                         %w[clipped-text] ],
    "svg-link-with-label" => [ '<svg width="200" height="100"><a href="#r" aria-label="North region"><rect width="200" height="100"/></a></svg>', [] ],
    "svg-link-with-title" => [ '<svg width="200" height="100"><a href="#r"><title>South region</title><rect width="200" height="100"/></a></svg>', [] ],
    "svg-link-unnamed" => [ '<svg width="200" height="100"><a href="#r"><rect width="200" height="100"/></a></svg>', %w[empty-control] ],
    "scrollable-own-text" => [ '<div style="width:60px;overflow-x:auto;white-space:nowrap">A very long label here</div>', [] ],
    "cut-by-ancestor" => [ '<div style="position:absolute;top:20px;width:200px;height:40px;overflow:hidden"><button style="margin-top:20px">Ask Dana</button></div>',
                           %w[clipped-text] ],
    "inside-scaled-ancestor" => [ '<div style="position:absolute;top:60px;left:60px;width:200px;height:80px;overflow:hidden;border:10px solid #000;transform:scale(1.2)">' \
                                  '<button style="margin-top:10px">Ask Dana</button></div>', [] ],
    "hidden-by-inner-clip" => [ '<div style="position:absolute;top:20px;width:300px;height:200px;overflow:hidden"><div style="height:40px;overflow:hidden">' \
                                '<p style="margin-top:60px">Below the fold</p></div></div>', [] ],
    "inside-ancestor" => [ '<div style="position:absolute;top:20px;width:200px;height:80px;overflow:hidden"><button>Ask Dana</button></div>', [] ],
    "control-in-caption-band" => [ '<button style="position:absolute;left:20px;bottom:10px">Send</button>', %w[caption-safe] ],
    "device-in-caption-band" => [ '<div class="phone" style="position:absolute;left:20px;top:20px;width:100px;height:330px"></div>', %w[caption-safe] ],
    "device-clear-of-band" => [ '<div class="phone" style="position:absolute;left:20px;top:20px;width:100px;height:280px"></div>', [] ],
    "pending-success" => [ '<div data-cf-state="pending"><span data-cf-success>Approved</span></div>', %w[contradictory-state] ],
    "stale-actions" => [ '<div data-cf-state="approved"><span data-cf-success>Approved</span><button data-cf-when="pending">Approve</button></div>',
                         %w[contradictory-state] ],
    "unplayable-video" => [ '<video controls style="width:200px;height:100px" src="data:video/mp4;base64,AAAAAA=="></video>', %w[unplayable-media] ],
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
      phone = lint(session, FIXTURES["device-clear-of-band"].first)["devices"].first
      assert_equal [ 100, 280, 100.0, 280.0 ], phone.values_at("lw", "lh", "w", "h")

      point, report = capture(session, LABEL_BUTTON, "#b")
      assert_empty report["findings"], "safe aim clears the label"
      assert_operator point["x"], :>, 200, "aimed at the label's end padding, right of the text"

      point, = capture(session, WIDE_BUTTON, "#w")
      assert_equal [ 300.0, 140.0 ], [ point["x"], point["y"] ], "a clear centre keeps the old aim, so clean frames do not change"
    end
  end
end
