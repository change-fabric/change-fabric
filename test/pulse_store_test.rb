# frozen_string_literal: true

require_relative "pulse_helper"
require_relative "../scripts/pulse_store"

class PulseStoreTest < Minitest::Test
  include PulseHome

  def setup
    super
    @plan = File.join(@home, "plan")
    @other = File.join(@home, "other")
    FileUtils.mkdir_p([ @plan, @other ])
    File.write(File.join(@plan, "goal.md"), "Land phase one with tests.\n")
    File.write(File.join(@plan, "plan.md"), "# Plan\nDecisions settled.\n")
    File.write(File.join(@other, "goal.md"), "Unrelated run goal text.\n")
    @scope = write_scope
    @store = PulseStore.new(@session)
  end

  # Stands in for pulse_scope.rb resolve: the allowed sources, with revisions.
  def write_scope
    sources = [ "goal.md", "plan.md" ].map do |name|
      { "role" => "run_#{name.delete_suffix('.md')}", "source_path" => File.join(@plan, name),
        "revision" => Pulse.sha(File.read(File.join(@plan, name))) }
    end
    { "sources" => sources }.tap { |scope| File.write(File.join(@dir, "pulse_scope.json"), JSON.generate(scope)) }
  end

  def finding(overrides = {})
    run_goal = @scope["sources"].find { |s| s["role"] == "run_goal" }
    { "kind" => "accel", "severity" => "P2", "claim" => "run phases in parallel", "evidence" => "phase 2 and 3 independent", "anchor" => "phases 2 and 3",
      "serves" => { "source_path" => run_goal["source_path"], "revision" => run_goal["revision"],
                    "quote" => "Land phase one", "relevance" => "faster landing" } }.merge(overrides)
  end

  def test_valid_finding_is_stored_and_authorizable
    result = @store.append(finding)
    assert_equal "stored", result["status"]
    assert result["authorizable"]
    assert_equal 1, @store.rows.size
  end

  def test_no_evidence_no_finding
    assert_equal "no evidence", @store.append(finding("evidence" => " "))["reason"]
    assert_equal "no anchor", @store.append(finding("anchor" => nil))["reason"]
    assert_empty @store.rows
  end

  def test_invented_quote_is_parked
    result = @store.append(finding("serves" => finding["serves"].merge("quote" => "Invented sentence")))
    assert_equal "park", result["action_class"]
  end

  def test_quote_from_a_different_runs_goal_is_parked
    other = { "source_path" => File.join(@other, "goal.md"), "revision" => Pulse.sha(File.read(File.join(@other, "goal.md"))),
              "quote" => "Unrelated run goal", "relevance" => "x" }
    assert_equal "park", @store.append(finding("serves" => other))["action_class"]
    wrong_quote = finding["serves"].merge("quote" => "Unrelated run goal")
    assert_equal "park", @store.append(finding("serves" => wrong_quote, "claim" => "other"))["action_class"]
  end

  def test_missing_relevance_is_parked
    serves = finding["serves"].merge("relevance" => "")
    assert_equal "park", @store.append(finding("serves" => serves))["action_class"]
  end

  def test_changed_source_stores_but_blocks_authorization
    f = finding
    File.write(File.join(@plan, "goal.md"), "Land phase one with tests.\nMore.\n")
    write_scope
    result = @store.append(f)
    assert_equal "stored", result["status"]
    refute result["authorizable"]
    assert_equal "report", result["action_class"]
  end

  def test_concurrent_appends_of_one_finding_store_once
    Array.new(6) { Thread.new { PulseStore.new(@session).append(finding) } }.each(&:join)
    assert_equal 1, @store.rows.size
  end

  def test_threads_sharing_one_store_instance_store_once
    Array.new(6) { Thread.new { @store.append(finding) } }.each(&:join)
    assert_equal 1, @store.rows.size
  end

  def test_caller_cannot_claim_system_origin
    result = @store.append(finding("origin" => "system", "serves" => nil, "action_class" => "auto"))
    assert_equal "park", result["action_class"]
  end

  def test_non_string_quote_is_parked
    assert_equal "park", @store.append(finding("serves" => finding["serves"].merge("quote" => 5)))["action_class"]
  end

  def test_duplicate_and_rejected_disposition_memory
    first = @store.append(finding)
    assert_equal "duplicate", @store.append(finding("claim" => "RUN  phases in   parallel", "evidence" => "reworded"))["status"]
    @store.disposition(first["fingerprint"], "rejected")
    assert_equal "suppressed", @store.append(finding)["status"]
  end

  def test_fingerprint_normalizes_subject
    assert_equal PulseStore.fingerprint("accel", "A  b", "x"), PulseStore.fingerprint("accel", "a b", " X ")
    refute_equal PulseStore.fingerprint("accel", "a", "x"), PulseStore.fingerprint("stall", "a", "x")
  end

  def test_cursor_round_trips
    @store.advance_cursor(consumed_events: 3)
    assert_equal 3, @store.cursor["consumed_events"]
  end

  def test_p0_notification_is_queued_once_and_only_for_p0
    p0 = @store.append(finding("severity" => "P0"))
    assert_equal "queued", @store.queue_notify(p0["id"])["status"]
    assert_equal "duplicate", @store.queue_notify(p0["id"])["status"]
    p2 = @store.append(finding("claim" => "other", "anchor" => "other"))
    assert_equal "not P0", @store.queue_notify(p2["id"])["reason"]
    assert_equal "unknown finding", @store.queue_notify("nope")["reason"]
  end

  def test_activation_stays_off
    refute Pulse::ACTIVATED
  end
end
