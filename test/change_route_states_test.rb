# frozen_string_literal: true

require "minitest/autorun"
require "json"
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
    assert_match(/missing before/, grade(watched, before_gone).last)
    assert_match(/missing after/, grade(watched, after_gone).last)
    assert_match(/missing before/, grade(watched, { "scrollWidth" => 390 }).last)
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

  # --- through the lane ---------------------------------------------------

  Ctx = Struct.new(:network, :target_url, :browserless) do
    def log(_message) = nil
  end

  class Session
    def initialize(states) = @states = states

    def run_function(code)
      routes = JSON.parse(code[/const routeEntries = (\[.*?\]);/, 1])
      routes.each_with_index.map do |route, index|
        { "viewport" => "mobile", "width" => 390, "height" => 844, "route" => route["path"], "routeIndex" => index,
          "httpStatus" => 200, "scrollWidth" => 390, "overflow" => false, "consoleErrors" => 0,
          "states" => @states[route["path"]] }.compact
      end
    end
  end

  def lane_findings(routes, states = {})
    config = ChangeConfig::LaneConfig.new("browserless", { "routes" => routes, "viewports" => [ { "name" => "mobile", "width" => 390, "height" => 844 } ] }, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org", Session.new(states))).run
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
