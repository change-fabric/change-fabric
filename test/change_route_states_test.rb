# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_browserless"
require_relative "../scripts/change_route_states"

class ChangeRouteStatesTest < Minitest::Test
  def normalize(raw) = ChangeRouteStates.normalize(raw)

  def state(extra = {}) = { "name" => "menu", "click" => "#menu" }.merge(extra)

  def test_absent_and_empty_states_mean_no_states
    assert_equal [ [], [] ], normalize(nil)
    assert_equal [ [], [] ], normalize([])
  end

  def test_a_non_list_is_one_error
    states, errors = normalize("open")
    assert_empty states
    assert_equal [ "states must be a list" ], errors
  end

  def test_defaults
    states, errors = normalize([ state ])
    assert_empty errors
    assert_equal [ "menu", "#menu", nil, [], 0, 5000 ], states.first.to_a
  end

  def test_a_duplicate_name_is_dropped_and_named
    states, errors = normalize([ state, state("click" => "#other") ])
    assert_equal [ "#menu" ], states.map(&:click)
    assert_match(/states\[1\]: duplicate name menu/, errors.first)
  end

  def test_each_malformed_state_is_reported_and_the_rest_kept
    bad = [ "str", { "name" => "x" }, state("name" => "bad name"), state("name" => "a", "tolerance_px" => -1),
            state("name" => "b", "timeout_ms" => 60_000), state("name" => "c", "watch" => "#a"),
            state("name" => "d", "click" => "text=Open"), state("name" => "e", "extra" => 1),
            state("name" => "f", "watch" => [ "" ]) ]
    states, errors = normalize([ state("name" => "ok") ] + bad.first(7))
    assert_equal [ "ok" ], states.map(&:name)
    assert_equal 7, errors.length
    assert_equal 2, normalize(bad.last(2)).last.length
  end

  def test_states_are_capped
    list = (1..10).map { |i| state("name" => "s#{i}") }
    states, errors = normalize(list)
    assert_equal ChangeRouteStates::MAX_STATES, states.length
    assert_match(/more than 8 states/, errors.first)
  end

  def test_free_text_in_errors_is_redacted
    secret = "sk_#{'live'}_abcdefghijklmnop1234567890"
    _states, errors = normalize([ state("name" => secret) ])
    refute_includes errors.join, secret
  end

  CELL = { "viewport" => "mobile", "width" => 390, "route" => "/" }.freeze

  def grade(declared, result, cell = CELL)
    ChangeRouteStates.grade(declared, result, cell)
  end

  def watched(extra = {})
    normalize([ state({ "watch" => [ "#hero" ] }.merge(extra)) ]).first.first
  end

  RECT = { "x" => 0, "y" => 10, "width" => 100, "height" => 50 }.freeze

  def test_a_stable_state_passes
    result = { "before" => [ RECT ], "after" => [ RECT ], "scrollWidth" => 390 }
    assert_equal "pass", grade(watched, result).first
  end

  def test_a_shift_beyond_tolerance_fails_and_within_passes
    result = { "before" => [ RECT ], "after" => [ RECT.merge("y" => 14) ], "scrollWidth" => 390 }
    status, _sev, detail = grade(watched, result)
    assert_equal "fail", status
    assert_match(/#hero moved or resized by 4.0px/, detail)
    assert_equal "pass", grade(watched("tolerance_px" => 4), result).first
  end

  def test_a_move_plus_resize_is_measured_by_the_edge
    result = { "before" => [ RECT ], "after" => [ RECT.merge("x" => 4, "width" => 104) ], "scrollWidth" => 390 }
    status, _sev, detail = grade(watched("tolerance_px" => 5), result)
    assert_equal "fail", status
    assert_match(/by 8.0px/, detail)
    assert_equal "pass", grade(watched("tolerance_px" => 8), result).first
  end

  def test_a_resize_counts
    result = { "before" => [ RECT ], "after" => [ RECT.merge("height" => 80) ], "scrollWidth" => 390 }
    assert_equal "fail", grade(watched, result).first
  end

  def test_a_missing_watched_element_fails_either_side
    before_gone = { "before" => [ nil ], "after" => [ RECT ], "scrollWidth" => 390 }
    after_gone = { "before" => [ RECT ], "after" => [ nil ], "scrollWidth" => 390 }
    assert_match(/missing or hidden before/, grade(watched, before_gone).last)
    assert_match(/missing or hidden after/, grade(watched, after_gone).last)
    assert_match(/missing or hidden before/, grade(watched, { "scrollWidth" => 390 }).last)
  end

  def test_overflow_in_the_state_fails
    result = { "before" => [ RECT ], "after" => [ RECT ], "scrollWidth" => 500 }
    assert_match(/horizontal overflow/, grade(watched, result).last)
  end

  def test_a_timeout_is_unreachable_not_a_pass
    result = { "error" => "TimeoutError: Waiting for selector `#menu` failed: Waiting failed: 5000ms exceeded" }
    status, severity, detail = grade(watched, result)
    assert_equal [ "fail", "high" ], [ status, severity ]
    assert_match(/could not be reached/, detail)
  end

  def test_an_unreported_state_and_a_failed_route_are_failures
    assert_match(/not reported/, grade(watched, nil).last)
    assert_match(/route did not load/, grade(watched, nil, CELL.merge("error" => "boom")).last)
  end

  def test_findings_name_every_declared_state_and_redact_page_text
    secret = "sk_#{'live'}_abcdefghijklmnop1234567890"
    declared, = normalize([ state, state("name" => "two", "ready" => "#two") ])
    cell = CELL.merge("states" => [ { "name" => "menu", "error" => "failed near #{secret}" } ])
    findings = ChangeRouteStates.findings(cell, declared, target: "https://app.example.org")
    assert_equal [ "mobile state menu", "mobile state two" ], findings.map(&:check)
    assert_equal %w[fail fail], findings.map(&:status)
    refute_includes findings.first.detail, secret
  end

  def test_every_state_starts_from_a_fresh_load_including_the_first
    js = ChangeRouteStates.runtime_js
    assert_match(/await bounded\(\(\) => reload\(/, js)
    refute_match(/if \(i > 0\)/, js)
  end

  def test_selectors_wait_for_visibility
    js = ChangeRouteStates.runtime_js
    assert_match(/waitForSelector\(selector, \{ visible: true/, js)
    assert_match(/waitFor\(st\.click,/, js)
    assert_match(/waitFor\(st\.ready,/, js)
  end

  def test_every_await_has_a_deadline_and_the_run_has_a_budget
    js = ChangeRouteStates.runtime_js
    assert_match(/bounded\(\(\) => statePage\.click\(st\.click\)/, js)
    assert_match(/bounded\(\(\) => statePage\.evaluate\(async \(\) => \{\n\s*if \(document\.fonts/, js)
    assert_match(/STATE_BUDGET_MS = 40000/, js)
    assert_match(/statePage\.on\("dialog"/, js)
  end

  def test_every_await_is_capped_by_the_remaining_route_budget
    js = ChangeRouteStates.runtime_js
    assert_match(/bounded\(\(\) => statePage\.evaluate\(\(\) => document\.documentElement\.scrollWidth\)/, js)
    assert_match(/bounded\(\(\) => readRects\(statePage, selectors\)/, js)
    refute_match(/withDeadline/, js, "no await may bypass the remaining-time cap")
    refute_match(/ms \+ 500/, js)
  end

  def test_the_function_timeout_constant_matches_the_container
    assert_equal ChangeDocker::Browserless::FUNCTION_TIMEOUT_MS, ChangeRouteStates::FUNCTION_TIMEOUT_MS
  end

  # Runs the real in-page runner under node against a page whose every call
  # hangs, and returns [results, elapsed_ms, deadline_ms].
  def run_hung_page(budget_ms, states)
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
    driver = <<~JS
      const never = () => new Promise(() => {});
      const page = { on() {}, off() {}, waitForSelector: never, click: never, evaluate: never };
      const states = #{JSON.generate(states)};
      (async () => {
        const started = Date.now();
        const results = await runStates(page, states, never, started + #{budget_ms});
        console.log(JSON.stringify({ results, elapsed: Date.now() - started }));
      })();
    JS
    out, status = Open3.capture2("node", stdin_data: ChangeRouteStates.runtime_js + driver)
    assert status.success?, out
    JSON.parse(out)
  end

  def test_a_hung_page_cannot_outlive_the_route_deadline
    states = [ { name: "a", click: "#a", watch: [], timeoutMs: 15_000 }, { name: "b", ready: "#b", watch: [], timeoutMs: 15_000 } ]
    out = run_hung_page(400, states)
    assert_operator out["elapsed"], :<, 2_000
    assert_equal %w[a b], out["results"].map { |r| r["name"] }
    assert(out["results"].all? { |r| r["error"] })
  end

  def node(script)
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
    out, status = Open3.capture2("node", stdin_data: ChangeRouteStates.runtime_js + script)
    assert status.success?, out
    JSON.parse(out)
  end

  def test_the_route_deadline_never_passes_the_function_timeout_and_reserves_later_cells
    out = node("const s = Date.now() - 100000; console.log(JSON.stringify([routeDeadline(s, 0, 0) - s, routeDeadline(s, 3, 0) - s, routeDeadline(s, 3, 10000) - s]));")
    limit = ChangeRouteStates::FUNCTION_TIMEOUT_MS - ChangeRouteStates::RESERVE_MS
    assert_operator out[0], :<=, limit
    assert_operator out[1], :<=, limit - (3 * ChangeRouteStates::CELL_RESERVE_MS)
    assert_operator out[2], :<=, limit - 30_000, "slow cells reserve their observed cost"
  end

  def test_a_spent_budget_starts_no_work
    out = node(<<~JS)
      let started = 0;
      (async () => {
        let result;
        try { result = await bounded(() => { started += 1; return Promise.resolve(1); }, 5000, Date.now() + 100, "step"); } catch (err) { result = String(err); }
        console.log(JSON.stringify({ started, result }));
      })();
    JS
    assert_equal 0, out["started"]
    assert_match(/budget used up before step/, out["result"])
  end

  def test_a_hung_state_stops_the_rest_of_the_route
    out = node(<<~JS)
      const never = () => new Promise(() => {});
      const calls = [];
      const page = { on() {}, off() {}, waitForSelector: never, click: never, evaluate: never };
      (async () => {
        const reload = () => { calls.push("reload"); return Promise.resolve(); };
        const states = [ { name: "a", click: "#a", watch: [], timeoutMs: 300 }, { name: "b", ready: "#b", watch: [], timeoutMs: 300 } ];
        const results = await runStates(page, states, reload, Date.now() + 30000);
        console.log(JSON.stringify({ results, calls }));
      })();
    JS
    assert_equal %w[reload], out["calls"]
    assert_match(/took over/, out["results"][0]["error"])
    assert_match(/skipped: an earlier state hung/, out["results"][1]["error"])
    refute(out["results"].any? { |r| r.key?("hung") })
  end

  def test_a_state_with_nothing_to_watch_still_waits_for_the_page_width_to_settle
    out = node(<<~JS)
      const widths = [300, 380, 390, 390];
      const page = { evaluate: async (fn, arg) => (arg ? { pageWidth: widths.shift() || 390, rects: [] } : undefined) };
      (async () => {
        const rects = await settledRects(page, [], 5000, Date.now() + 10000);
        console.log(JSON.stringify({ rects, left: widths.length }));
      })();
    JS
    assert_equal [], out["rects"]
    assert_equal 0, out["left"]
  end

  def test_a_selector_that_never_appears_is_not_a_hang_and_later_states_still_run
    out = node(<<~JS)
      const page = {
        on() {}, off() {},
        waitForSelector: (sel, opts) => new Promise((_, reject) => setTimeout(() => reject(new Error("Waiting for selector " + sel + " failed")), opts.timeout)),
        click: async () => {}, evaluate: async () => ({ pageWidth: 390, rects: [] })
      };
      (async () => {
        const states = [ { name: "a", click: "#missing", watch: [], timeoutMs: 400 }, { name: "b", click: "#missing", watch: [], timeoutMs: 400 } ];
        const results = await runStates(page, states, async () => {}, Date.now() + 30000);
        console.log(JSON.stringify(results));
      })();
    JS
    assert_equal %w[a b], out.map { |r| r["name"] }
    assert(out.all? { |r| r["error"].include?("Waiting for selector") }, out.inspect)
  end

  def test_a_beforeunload_prompt_is_accepted_and_other_dialogs_dismissed
    out = node(<<~JS)
      const handlers = {};
      const page = { on(n, f) { handlers[n] = f; }, off() {} };
      (async () => {
        await runStates(page, [], () => {}, Date.now() + 1000);
        const seen = [];
        handlers.dialog({ type: () => "beforeunload", accept: async () => seen.push("accept"), dismiss: async () => seen.push("dismiss") });
        handlers.dialog({ type: () => "alert", accept: async () => seen.push("accept"), dismiss: async () => seen.push("dismiss") });
        console.log(JSON.stringify(seen));
      })();
    JS
    assert_equal %w[accept dismiss], out
  end

  def test_a_state_is_measured_once_settled_before_and_after
    js = ChangeRouteStates.runtime_js
    assert_equal 2, js.scan("await settledRects(statePage, st.watch").length
  end

  def test_rects_that_never_agree_fail_the_state_instead_of_passing
    js = ChangeRouteStates.runtime_js
    assert_includes js, 'throw new Error("layout did not settle in "'
    refute_match(/if \(next === last\) break;/, js)
  end

  def test_a_hidden_element_and_a_blocked_login_are_named
    zero = RECT.merge("width" => 0, "height" => 0)
    assert_includes ChangeRouteStates.runtime_js, "r.width === 0 && r.height === 0"
    assert_match(/login failed/, grade(watched, nil, CELL.merge("authBlocked" => true)).last)
    assert_match(/missing or hidden before/, grade(watched, { "before" => [ nil ], "after" => [ zero ], "scrollWidth" => 1 }).last)
  end

  def test_an_infinite_or_huge_tolerance_is_rejected
    [ Float::INFINITY, Float::NAN, 10_001 ].each do |value|
      states, errors = normalize([ state("tolerance_px" => value) ])
      assert_empty states, value.to_s
      assert_match(/tolerance_px/, errors.first)
    end
  end

  # --- through the lane ---------------------------------------------------

  Ctx = Struct.new(:network, :target_url, :browserless) do
    def log(_message) = nil
  end

  class Session
    def initialize(states) = @states = states

    attr_reader :code

    def run_function(code)
      @code = code
      routes = JSON.parse(code[/const routeEntries = (\[.*?\]);/, 1])
      routes.each_with_index.map do |route, index|
        { "viewport" => "mobile", "width" => 390, "height" => 844, "route" => route["path"], "routeIndex" => index,
          "httpStatus" => 200, "scrollWidth" => 390, "overflow" => false, "consoleErrors" => 0,
          "states" => @states[route["path"]] }.compact
      end
    end
  end

  def lane_findings(routes, states = {}, session = Session.new(states))
    config = ChangeConfig::LaneConfig.new("browserless", { "routes" => routes, "viewports" => [ { "name" => "mobile", "width" => 390, "height" => 844 } ] }, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org", session)).run
  end

  def test_the_scan_passes_one_route_deadline_into_run_states
    session = Session.new({})
    lane_findings([ { "path" => "/", "states" => [ state ] } ], {}, session)
    assert_includes session.code, "const scanStarted = Date.now();"
    assert_includes session.code, "routeDeadline(scanStarted, totalCells - cellsDone - 1, Math.max(baseCellMs, Date.now() - cellStart))"
    assert_includes session.code, "Math.min(waitFor.timeoutMs, capMs)"
  end

  def test_a_reload_leaves_the_page_before_loading_the_route_so_hash_routes_reload
    session = Session.new({})
    lane_findings([ { "path" => "/#/settings", "states" => [ state ] } ], {}, session)
    assert_match(/goto\("about:blank"[^\n]*\n[^\n]*goto\(baseUrl \+ entry\.path/, session.code)
  end

  def test_a_route_without_states_adds_no_state_findings
    findings = lane_findings([ "/", { "path" => "/a", "states" => [] } ])
    assert_equal [ "mobile 390x844" ] * 2, findings.map(&:check)
  end

  def test_the_lane_sends_states_and_grades_by_route_not_by_path
    routes = [ { "path" => "/", "states" => [ state ] }, { "path" => "/", "states" => [ state("name" => "other", "ready" => "#x") ] } ]
    findings = lane_findings(routes, "/" => [ { "name" => "menu", "scrollWidth" => 390 } ])
    assert_includes findings.map(&:check), "mobile state menu"
    assert_includes findings.map(&:check), "mobile state other"
  end

  def test_config_errors_are_failing_findings_and_valid_states_still_run
    findings = lane_findings([ { "path" => "/", "states" => [ state, { "name" => "menu", "click" => "#b" } ] } ],
                             "/" => [ { "name" => "menu", "scrollWidth" => 390 } ])
    config = findings.find { |f| f.check == "route states config" }
    assert_equal "fail", config.status
    assert_match(/duplicate name menu/, config.detail)
    assert_equal "pass", findings.find { |f| f.check == "mobile state menu" }.status
  end
end
