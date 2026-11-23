# frozen_string_literal: true

require_relative "pulse_helper"
require "open3"
require_relative "../scripts/pulse_store"
require "rbconfig"

# C5 integration: a zero-row PASS goes through the real C1 coordinator
# sequence (scope resolve, pre-check, integrity, append, notify) by running the
# installed CLIs as subprocesses, with no recorded reviewer output and no model.
class PulseIntegrationTest < Minitest::Test
  include PulseHome

  SCRIPTS = File.expand_path("../scripts", __dir__)

  def cli(script, *args, input: nil)
    out, status = Open3.capture2(RbConfig.ruby, File.join(SCRIPTS, script), *args, stdin_data: input.to_s)
    assert status.success?, "#{script} #{args.first} failed: #{out}"
    JSON.parse(out)
  end

  def run_sequence(session)
    scope = cli("pulse_scope.rb", "resolve", "--session", session, "--project", @home, "--plan-dir", @plan)
    check = cli("pulse_precheck.rb", "--session", session, "--now", t(1).iso8601, "--json")
    return [ scope, check, [], [] ] unless check["due"]

    findings = cli("pulse_integrity.rb", "--session", session, "--json")
    stored = findings.map { |f| cli("pulse_store.rb", "append", "--session", session, input: JSON.generate(f)) }
    queued = stored.zip(findings).select { |_, f| f["severity"] == "P0" }.map { |s, _| cli("pulse_store.rb", "notify", "--session", session, "--finding", s["id"]) }
    [ scope, check, stored, queued ]
  end

  def setup
    super
    @plan = File.join(@home, "plan")
    FileUtils.mkdir_p([ @plan, File.join(@dir, "pulse_results") ])
    FileUtils.cp(File.join(__dir__, "fixtures/pulse/zero_row_pass/goal.md"), File.join(@plan, "goal.md"))
    FileUtils.cp(File.join(__dir__, "fixtures/pulse/zero_row_pass/result.json"), File.join(@dir, "pulse_results", "result.json"))
  end

  def test_zero_row_pass_reaches_the_ledger_as_p0_and_queues_a_notification
    write_events({ "event" => "run_result", "at" => t(0).iso8601 })
    _, check, stored, queued = run_sequence(@session)
    assert_includes check["reasons"], "event:run_result"
    assert_equal [ "stored" ], stored.map { |s| s["status"] }
    row = File.readlines(File.join(@dir, "pulse.jsonl")).map { |l| JSON.parse(l) }.last
    assert_equal [ "P0", "integrity", "vacuous-pass", true ], row.values_at("severity", "kind", "check", "authorizable")
    assert_includes row["claim"], "vacuous pass"
    assert_equal [ "queued" ], queued.map { |q| q["status"] }
    note = JSON.parse(File.readlines(File.join(@dir, "pulse_notifications.jsonl")).last)
    assert_equal [ row["id"], "pending" ], note.values_at("finding", "state")
  end

  def test_integrity_runs_with_the_model_budget_exhausted
    project = File.join(@home, "proj")
    FileUtils.mkdir_p(project)
    Pulse.config["max_passes_per_day"].times { PulseStore.reserve(project) }
    assert PulseStore.reserve(project)["exhausted"]
    write_events({ "event" => "run_result", "at" => t(0).iso8601 })
    _, _, stored, queued = run_sequence(@session)
    assert_equal 1, stored.size
    assert_equal 1, queued.size
  end

  def test_unscoped_p0_goes_through_append_system_and_is_still_delivered
    write_events({ "event" => "run_result", "at" => t(0).iso8601 })
    FileUtils.rm_f(File.join(@plan, "goal.md"))
    cli("pulse_scope.rb", "resolve", "--session", @session, "--project", @home, "--plan-dir", @plan)
    check = cli("pulse_precheck.rb", "--session", @session, "--now", t(1).iso8601, "--json")
    assert check["due"]
    finding = cli("pulse_integrity.rb", "--session", @session, "--json").first
    assert_nil finding["serves"]
    stored = cli("pulse_store.rb", "append-system", "--session", @session, input: JSON.generate(finding))
    assert_equal "stored", stored["status"]
    assert_equal "queued", cli("pulse_store.rb", "notify", "--session", @session, "--finding", stored["id"])["status"]
  end

  def test_a_parked_finding_is_never_notified
    parked = PulseStore.new(@session).append("kind" => "integrity", "severity" => "P0", "claim" => "c", "evidence" => "e", "anchor" => "a")
    assert_equal "parked", PulseStore.new(@session).findings[parked["id"]]["disposition"]
    assert_equal "parked", PulseStore.new(@session).queue_notify(parked["id"])["reason"]
  end

  def test_commit_through_the_cli_makes_the_next_pass_skip_the_result
    findings = cli("pulse_integrity.rb", "--session", @session, "--json")
    cli("pulse_integrity.rb", "--session", @session, "--commit", "true", input: JSON.generate(findings))
    assert_empty cli("pulse_integrity.rb", "--session", @session, "--json")
  end

  def test_commit_result_consumes_only_what_the_check_saw
    write_events({ "event" => "run_result", "at" => t(0).iso8601 })
    seen = cli("pulse_precheck.rb", "--session", @session, "--now", t(1).iso8601, "--json")
    write_events({ "event" => "run_result", "at" => t(0).iso8601 }, { "event" => "gate_verdict", "at" => t(1).iso8601 })
    cli("pulse_precheck.rb", "--session", @session, "--now", t(2).iso8601, "--commit-result", "true", "--json", input: JSON.generate(seen))
    later = cli("pulse_precheck.rb", "--session", @session, "--now", t(2).iso8601, "--json")
    assert_equal [ "event:gate_verdict" ], later["reasons"]
  end

  def test_nothing_due_skips_integrity
    _, check, stored, = run_sequence(@session)
    refute check["due"]
    assert_empty stored
  end
end
