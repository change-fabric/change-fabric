# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require_relative "../scripts/approval_console/preview_capture"
require_relative "../scripts/approval_console/preview_a11y"

# preview_capture.rb and preview_a11y.rb, with the browser faked for the unit
# cases and real (skipping without Docker) for the end-to-end ones.
class ApprovalConsolePreviewScriptsTest < Minitest::Test
  Capture = ApprovalConsole::PreviewCapture
  A11y = ApprovalConsole::PreviewA11y
  PNG = Base64.strict_encode64("\x89PNG fake")

  class FakeSession
    attr_reader :modules

    def initialize(&answer)
      @answer = answer
      @modules = []
    end

    attr_reader :launch_args

    def run_function(code, launch_args: nil, **)
      @launch_args = launch_args
      @modules << code
      @answer.call(code)
    end
  end

  def entries(first_load: nil)
    Capture.targets.map do |route, state|
      entry = { "route" => route, "state" => state, "shot" => PNG }
      entry["first_load"] = first_load if first_load && route == Capture::FIRST_LOAD_ROUTE && !state
      entry["observed"] = OBSERVED.fetch(state) if state
      entry
    end
  end

  OBSERVED = {
    "success" => { "result_kind" => "ok" }, "locked" => { "msg" => "Too many failed tries. Locked until 4:10 PM." },
    "code-refused" => { "msg" => "That code did not match. Wait." }, "in-app" => { "hint_hidden" => false }
  }.freeze

  GOOD = { "changes" => { "top" => 300, "bottom" => 380 }, "bar" => { "top" => 700, "bottom" => 844 }, "inner_height" => 844, "scroll_y" => 0 }.freeze

  # ----- preview_capture -------------------------------------------------

  def test_targets_cover_every_server_route_and_the_client_stills
    targets = Capture.targets
    assert_equal ApprovalConsole::PreviewHost.routes.size + Capture::CLIENT_STILLS.size, targets.size
    assert_equal 31, ApprovalConsole::PreviewHost.routes.size
    assert_includes targets, [ "/type/carve-out/state/pending", "in-app" ]
    assert_equal targets.size, targets.map { |t| Capture::Still.new(route: t[0], state: t[1], viewport: "v", scheme: "s").filename }.uniq.size, "filenames are unique"
  end

  def test_the_capture_module_sets_viewport_scheme_and_the_preview_url
    code = Capture.capture_module("http://host.docker.internal:4242", [ [ "/x", nil ] ], "1280x800", "dark")
    assert_includes code, "width: 1280, height: 800"
    assert_includes code, '"prefers-color-scheme", value: "dark"'
    assert_includes code, '"http://host.docker.internal:4242"'
  end

  def test_run_writes_a_png_per_target_viewport_and_scheme
    Dir.mktmpdir do |dir|
      session = FakeSession.new { entries(first_load: GOOD) }
      result = Capture.new(out_dir: dir, session: session, url: "http://p").run
      expected = Capture.targets.size * Capture::VIEWPORTS.size * Capture::SCHEMES.size
      assert_equal expected, result[:stills].size
      assert_equal expected, Dir[File.join(dir, "*.png")].size
      assert_empty result[:problems]
      assert_equal 4, session.modules.size
      assert_equal "\x89PNG fake".b, File.binread(File.join(dir, "type-carve-out-pending-390x844-light.png"))
    end
  end

  def test_a_failed_still_is_reported_and_writes_nothing
    Dir.mktmpdir do |dir|
      session = FakeSession.new { entries(first_load: GOOD).each_with_index.map { |e, i| i.zero? ? e.merge("shot" => nil, "error" => "boom") : e } }
      result = Capture.new(out_dir: dir, session: session, url: "http://p").run
      assert(result[:problems].any? { |p| p.include?("boom") })
      refute File.exist?(File.join(dir, Capture::Still.new(route: Capture.targets[0][0], state: nil, viewport: "390x844", scheme: "light").filename))
    end
  end

  def test_the_first_load_check
    assert_nil Capture.first_load_problem({ "first_load" => GOOD }, "390x844")
    assert_nil Capture.first_load_problem({ "first_load" => GOOD.merge("changes" => { "bottom" => 9000 }) }, "1280x800"), "only the phone viewport is checked"
    assert_nil Capture.first_load_problem({}, "390x844")
    assert_match(/below the first viewport/, Capture.first_load_problem({ "first_load" => GOOD.merge("changes" => { "top" => 800, "bottom" => 900 }) }, "390x844"))
    assert_match(/did not open at the top/, Capture.first_load_problem({ "first_load" => GOOD.merge("scroll_y" => 40) }, "390x844"))
    assert_match(/action bar is missing/, Capture.first_load_problem({ "first_load" => GOOD.merge("bar" => nil) }, "390x844"))
    assert_match(/action bar is outside/, Capture.first_load_problem({ "first_load" => GOOD.merge("bar" => { "top" => 900, "bottom" => 1000 }) }, "390x844"))
    assert_match(/what-changes line is missing/, Capture.first_load_problem({ "first_load" => GOOD.merge("changes" => nil) }, "390x844"))
  end

  def test_a_client_state_that_never_formed_is_a_problem
    stuck = { "route" => "/r", "state" => "success", "observed" => { "result_kind" => "info", "msg" => "This browser cannot use passkeys." } }
    assert_match(/expected result_kind "ok", saw "info"/, Capture.state_problem(stuck))
    assert_nil Capture.state_problem(stuck.merge("observed" => OBSERVED["success"]))
    assert_nil Capture.state_problem({ "route" => "/r", "state" => nil })
    assert_match(/expected msg/, Capture.state_problem({ "route" => "/r", "state" => "locked", "observed" => {} }))
    assert_match(/expected hint_hidden false, saw true/, Capture.state_problem({ "route" => "/r", "state" => "in-app", "observed" => { "hint_hidden" => true } }))
  end

  def test_the_browser_treats_the_preview_origin_as_secure
    assert_equal [ "--unsafely-treat-insecure-origin-as-secure=http://host.docker.internal:9" ], ApprovalConsole::PreviewHost.launch_args("http://host.docker.internal:9")
    seen = nil
    session = Object.new
    session.define_singleton_method(:run_function) { |_code, **opts| seen = opts[:launch_args]; [] }
    Dir.mktmpdir { |dir| Capture.new(out_dir: dir, session: session, url: "http://p:1").run }
    assert_equal ApprovalConsole::PreviewHost.launch_args("http://p:1"), seen
  end

  def test_run_surfaces_a_first_load_failure
    Dir.mktmpdir do |dir|
      session = FakeSession.new { entries(first_load: GOOD.merge("changes" => { "bottom" => 2000 })) }
      result = Capture.new(out_dir: dir, session: session, url: "http://p").run
      assert_equal 2, result[:problems].size
      assert(result[:problems].all? { |p| p.start_with?("390x844") })
    end
  end

  # ----- preview_a11y ----------------------------------------------------

  def test_the_a11y_config_scans_every_route_in_both_schemes_with_the_csp_bypass
    config = A11y.lane_config("dark", [ "/a" ])
    assert_equal [ "/a" ], config["routes"]
    assert_equal "serious", config["threshold"]
    assert_equal true, config["bypass_csp"]
    assert_equal "dark", config["color_scheme"]
  end

  def test_scan_runs_the_lane_once_per_scheme_and_failures_are_collected
    modules = []
    session = FakeSession.new do |code|
      modules << code
      [ { "route" => "/a", "finalUrl" => "http://p/a", "httpStatus" => 200, "violations" => [ { "id" => "color-contrast", "impact" => "serious", "help" => "h", "helpUrl" => "u", "nodes" => [ "p" ] } ] },
        { "route" => "/b", "finalUrl" => "http://p/b", "httpStatus" => 200, "violations" => [] } ]
    end
    results = A11y.scan(session, "http://p", routes: [ "/a", "/b" ])
    assert_equal %w[light dark], results.keys
    assert_equal [ "--unsafely-treat-insecure-origin-as-secure=http://p" ], session.launch_args
    assert_includes modules[0], '"light"'
    assert_includes modules[1], '"dark"'
    assert(modules.all? { |m| m.include?("setBypassCSP(true)") })
    failing = A11y.failures(results)
    assert_equal 2, failing.size
    assert_equal "color-contrast", failing.first.last.check
    assert_match(/FAIL dark color-contrast/, A11y.report(results).join("\n"))
    assert_match(/2 failing\z/, A11y.report(results).last)
  end

  def test_a_clean_scan_reports_no_failures
    session = FakeSession.new { [ { "route" => "/a", "finalUrl" => "http://p/a", "httpStatus" => 200, "violations" => [] } ] }
    results = A11y.scan(session, "http://p", routes: [ "/a" ])
    assert_empty A11y.failures(results)
    assert_equal "2 schemes, 2 findings, 0 failing", A11y.report(results).last
  end

  def test_a_route_that_did_not_load_fails
    session = FakeSession.new { [ { "route" => "/a", "error" => "net::ERR", "violations" => [] } ] }
    assert_equal 2, A11y.failures(A11y.scan(session, "http://p", routes: [ "/a" ])).size
  end

  def test_the_lane_options_are_absent_unless_asked_for
    lane = lambda do |raw|
      session = FakeSession.new { [] }
      ChangeLaneA11y.new(ChangeConfig::LaneConfig.new("a11y", raw, "/r"), A11y::Context.new(nil, "http://p", session)).run
      session.modules.first
    end
    plain = lane.call({})
    refute_includes plain, "setBypassCSP"
    refute_includes plain, "emulateMediaFeatures"
    refute_includes lane.call({ "color_scheme" => "sepia" }), "emulateMediaFeatures"
    assert_includes lane.call({ "color_scheme" => "dark" }), "emulateMediaFeatures"
  end

  # ----- end to end (Docker) ---------------------------------------------

  def test_the_real_a11y_scan_of_the_preview_has_no_serious_failures
    skip "docker not available" unless ChangeDocker.available?
    results = ApprovalConsole::PreviewHost.with_session { |session, url| A11y.scan(session, url) }
    assert_equal [], A11y.report(results)[0...-1]
    assert_operator results.values.sum(&:size), :>=, 44
  end
end
