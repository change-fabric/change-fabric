# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_browserless"

# Covers F6 step 1: lightweight per-cell timing instrumentation. #run records
# each cell's navigation/eval/screenshot/total duration (Date.now() deltas set
# in the browserless /function module, exercised only by a live docker+
# browserless run, not a unit test); timing_section renders whatever #run
# captured into the Markdown table the run report reads. Purely additive: it
# never gates, and a run that captured nothing renders nothing.
class ChangeLaneBrowserlessTimingTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def lane(raw = {})
    config = ChangeConfig::LaneConfig.new("browserless", raw, "/repo")
    ChangeLaneBrowserless.new(config, Ctx.new("net", "https://app.example.org"))
  end

  def test_timing_section_is_nil_before_run_ever_populates_it
    assert_nil lane.timing_section
  end

  def test_timing_section_is_nil_when_run_captured_no_cells
    l = lane
    l.instance_variable_set(:@timed_cells, [])
    assert_nil l.timing_section
  end

  def test_timing_section_renders_a_row_per_cell
    l = lane
    l.instance_variable_set(:@timed_cells, [
      { "viewport" => "mobile", "route" => "/", "navMs" => 120, "evalMs" => 5, "shotMs" => 40, "totalMs" => 170 },
      { "viewport" => "desktop", "route" => "/about", "navMs" => 90, "evalMs" => 3, "totalMs" => 95 }
    ])
    section = l.timing_section
    assert_includes section, "### Browserless per-cell timing (ms)"
    assert_includes section, "| mobile | / | 120 | 5 | 40 | 170 |"
    # No screenshot captured for this cell (shotMs absent): renders as a
    # dash, not a blank or a crash on the missing key.
    assert_includes section, "| desktop | /about | 90 | 3 | - | 95 |"
  end
end
