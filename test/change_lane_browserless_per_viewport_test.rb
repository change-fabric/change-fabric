# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_browserless"

# The scan runs one browserless call per viewport, so each viewport gets its
# own function timeout instead of the whole route/viewport matrix sharing one.
class ChangeLaneBrowserlessPerViewportTest < Minitest::Test
  # Answers each call with one passing cell for the viewport its module
  # names, and raises for any viewport listed in `fail_on`.
  class FakeSession
    attr_reader :viewports_seen

    def initialize(fail_on: [])
      @fail_on = fail_on
      @viewports_seen = []
    end

    def run_function(code)
      viewports = JSON.parse(code[/const viewports = (\[.*?\]);/, 1])
      @viewports_seen << viewports.map { |vp| vp["name"] }
      name = viewports.first["name"]
      raise "browserless /function failed: 408 Request has timed out" if @fail_on.include?(name)

      [ { "viewport" => name, "width" => viewports.first["width"], "route" => "/", "httpStatus" => 200,
          "scrollWidth" => 10, "overflow" => false, "consoleErrors" => 0 } ]
    end
  end

  Ctx = Struct.new(:network, :target_url, :browserless) do
    def log(_message) = nil
  end

  VIEWPORTS = [ { "name" => "mobile", "width" => 390, "height" => 844 },
                { "name" => "desktop", "width" => 1440, "height" => 900 } ].freeze

  def run_lane(session)
    config = ChangeConfig::LaneConfig.new("browserless", { "routes" => [ "/" ], "viewports" => VIEWPORTS }, "/repo")
    lane = ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org", session))
    [ lane.run, lane ]
  end

  def test_each_viewport_gets_its_own_call_and_the_cells_merge
    session = FakeSession.new
    _findings, lane = run_lane(session)
    assert_equal [ [ "mobile" ], [ "desktop" ] ], session.viewports_seen
    assert_equal %w[mobile desktop], lane.instance_variable_get(:@timed_cells).map { |cell| cell["viewport"] }
  end

  def test_a_failed_viewport_is_its_own_finding_and_keeps_the_others
    findings, lane = run_lane(FakeSession.new(fail_on: [ "mobile" ]))
    scan_errors = findings.select { |f| f.check == "viewport scan" }
    assert_equal 1, scan_errors.size
    assert_equal "mobile", scan_errors.first.location
    assert_match(/408/, scan_errors.first.detail)
    assert_equal %w[desktop], lane.instance_variable_get(:@timed_cells).map { |cell| cell["viewport"] }
  end
end
