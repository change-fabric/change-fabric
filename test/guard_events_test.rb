# frozen_string_literal: true

require_relative "test_helpers"
require "time"
require_relative "../scripts/guard_events"

class GuardEventsTest < Minitest::Test
  NOW = Time.utc(2026, 11, 25, 12, 0, 0)
  RULES = {
    "force_push_guard/deny" => { "kind" => "deny" },
    "slop_remind/remind" => { "kind" => "advisory" },
    "skill_review/gate" => { "kind" => "gate" }
  }.freeze

  def setup
    @home = Dir.mktmpdir
    FileUtils.mkdir_p(HookEvent.state_dir(@home))
  end

  def teardown
    FileUtils.remove_entry(@home)
  end

  def log(*events)
    File.write(HookEvent.events_path(@home), events.map { |e| "#{JSON.generate(e)}\n" }.join)
  end

  def ev(type, days_ago, **fields)
    { "ts" => (NOW - (days_ago * 86_400)).iso8601, "type" => type, "session" => "s", "level" => "unset",
      "doctrine_version" => "none" }.merge(fields.transform_keys(&:to_s))
  end

  def reader = GuardEvents.new(home: @home, now: NOW, rules: RULES)

  def test_summary_of_a_missing_log_is_empty_but_well_formed
    result = reader.summary(since_days: 1)
    assert_equal 0, result["events"]
    assert_equal [], result["rules"]
    JSON.parse(JSON.generate(result))
  end

  def test_summary_counts_evaluations_and_interventions_inside_the_window
    log(ev("session_start", 0.1), ev("evaluation", 0.1, rule_id: "force_push_guard/deny"),
        ev("evaluation", 0.2, rule_id: "force_push_guard/deny"),
        ev("intervention", 0.2, rule_id: "force_push_guard/deny", outcome: "deny"),
        ev("evaluation", 5, rule_id: "force_push_guard/deny"))
    result = reader.summary(since_days: 1)
    row = result["rules"].first
    assert_equal 1, result["sessions"]
    assert_equal [ 2, 1, { "deny" => 1 }, "deny" ], [ row["evaluations"], row["interventions"], row["outcomes"], row["kind"] ]
  end

  def test_an_undeclared_rule_is_flagged
    log(ev("evaluation", 0.1, rule_id: "mystery/deny"))
    assert_equal false, reader.summary(since_days: 1)["rules"].first["declared"]
  end

  def test_idle_proposes_an_advisory_rule_with_enough_days_and_sessions
    starts = (1..200).map { |i| ev("session_start", 61 - (i * 0.25)) }
    log(ev("evaluation", 70, rule_id: "slop_remind/remind"), *starts)
    result = reader.idle(days: 60, sessions: 200)
    assert result["enough_history"]
    assert_equal [ "slop_remind/remind" ], result["proposals"].map { |p| p["rule_id"] }
  end

  def test_idle_never_proposes_deny_or_gate_guards
    starts = (1..250).map { |i| ev("session_start", 100 - (i * 0.1)) }
    log(ev("evaluation", 120, rule_id: "force_push_guard/deny"), ev("evaluation", 120, rule_id: "skill_review/gate"), *starts)
    ids = reader.idle(days: 60, sessions: 200)["proposals"].map { |p| p["rule_id"] }
    refute_includes ids, "force_push_guard/deny"
    refute_includes ids, "skill_review/gate"
  end

  def test_a_young_log_proposes_nothing
    starts = (1..300).map { |i| ev("session_start", 10 - (i * 0.03)) }
    log(*starts)
    assert_empty reader.idle(days: 60, sessions: 200)["proposals"]
  end

  def test_a_recent_firing_keeps_a_rule_off_the_list
    starts = (1..250).map { |i| ev("session_start", 100 - (i * 0.1)) }
    log(ev("evaluation", 100, rule_id: "slop_remind/remind"), ev("intervention", 3, rule_id: "slop_remind/remind", outcome: "advise"), *starts)
    assert_empty reader.idle(days: 60, sessions: 200)["proposals"]
  end

  def test_a_surfaced_rubric_idle_long_enough_is_proposed
    starts = (1..250).map { |i| ev("session_start", 100 - (i * 0.1)) }
    log(ev("rubric_surfaced", 100, rule_id: "rubric/ruby"), *starts)
    assert_includes reader.idle(days: 60, sessions: 200)["proposals"].map { |p| p["rule_id"] }, "rubric/ruby"
  end

  def test_the_cli_parses_summary_json
    out, status = Open3.capture2e({ "HOME" => @home, "CF_GUARD_EVENTS_PATH" => nil }, RbConfig.ruby, File.expand_path("../scripts/guard_events.rb", __dir__),
                                  "summary", "--since-days", "1", "--json")
    assert status.success?, out
    assert_equal 0, JSON.parse(out)["events"]
  end
end
