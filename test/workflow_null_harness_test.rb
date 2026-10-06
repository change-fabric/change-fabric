#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "json"

# Guards the four Workflow scripts cf:resolve-threads, cf:drive, cf:sweep and
# cf:code-review against the class of bug plan.md's audit table names: an
# agent() call that returns null, or a result missing a field, and the
# workflow either throws (relying on a TypeError to stop it) or silently
# produces an unattended-unsafe answer. test/support/workflow_harness.mjs
# runs each workflow.js for real, with agent() stubbed from a fixture, and
# this test drives null and partial injection over every call-site key a
# happy run makes.
class WorkflowNullHarnessTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  HARNESS = File.join(__dir__, "support", "workflow_harness.mjs")
  FIXTURE_DIR = File.join(__dir__, "fixtures", "workflow_harness")

  WORKFLOWS = {
    "resolve-threads" => File.join(ROOT, "skills/resolve-threads/reference/workflow.js"),
    "drive" => File.join(ROOT, "skills/drive/reference/workflow.js"),
    "sweep" => File.join(ROOT, "skills/sweep/reference/workflow.js"),
    "code-review" => File.join(ROOT, "skills/code-review/reference/workflow.js")
  }.freeze

  def node_available?
    system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def fixture_path(skill)
    File.join(FIXTURE_DIR, "#{skill}.json")
  end

  def run_harness(skill, null: nil, partial: nil, partial_field: nil)
    args = [ "node", HARNESS, WORKFLOWS.fetch(skill), "--fixture", fixture_path(skill) ]
    args.push("--null", null) if null
    if partial
      args.push("--partial", partial)
      args.push("--partial-field", partial_field) if partial_field
    end
    out, status = Open3.capture2(*args)
    assert status.success?, "harness process failed for #{skill} (null=#{null.inspect} partial=#{partial.inspect}): #{out}"
    JSON.parse(out)
  end

  # Enumerates every call-site key a happy run makes, in call order, so the
  # injection loops below cover exactly the calls each workflow actually
  # performs rather than a hardcoded guess that drifts from the source.
  def happy_keys(skill)
    run_harness(skill).fetch("calls")
  end

  def each_field_of(skill, key)
    fixture = JSON.parse(File.read(fixture_path(skill)))
    value = fixture.fetch("results").fetch(key)
    value.is_a?(Hash) ? value.keys : []
  end

  # Decision 9 (CrashOK): every agent() result is null-checked into a named
  # fail-closed branch; no case may rely on a thrown TypeError. This is the
  # one invariant that already holds for every call site that is reachable
  # with the minimal fixtures below. A key that still throws names the exact
  # line plan.md's later phase must fix; it is never loosened here.
  NO_THROW_TODO = {
    "resolve-threads" => [], # already null-safe at every reachable call site
    "drive" => [], # relevance is null-checked at every lane now
    "sweep" => [], # infra and order agent nulls are handled now (Phase 4)
    "code-review" => []
  }.freeze

  # Same idea as NO_THROW_TODO, but for a result that comes back non-null
  # with one field missing (the Root cause map present but empty of
  # clusters): `{ skill => { key => [field, ...] } }`.
  NO_THROW_PARTIAL_TODO = {}.freeze

  def test_no_case_throws
    skip "node not installed" unless node_available?
    WORKFLOWS.each_key do |skill|
      todo = NO_THROW_TODO.fetch(skill)
      happy_keys(skill).each do |key|
        result = run_harness(skill, null: key)
        if todo.include?(key)
          assert result.key?("threw"), "#{skill} #{key}: expected still to throw (skip stale, remove from NO_THROW_TODO)"
        else
          refute result.key?("threw"), "#{skill} #{key} (null): threw #{result['threw']}"
        end

        partial_todo = NO_THROW_PARTIAL_TODO.dig(skill, key) || []
        each_field_of(skill, key).each do |field|
          partial = run_harness(skill, partial: key, partial_field: field)
          next if todo.include?(key) || partial_todo.include?(field)

          refute partial.key?("threw"), "#{skill} #{key} missing #{field}: threw #{partial['threw']}"
        end
      end
    end
  end

  def test_resolve_threads_recurrence_fails_closed
    happy_keys("resolve-threads").each do |key|
      result = run_harness("resolve-threads", null: key).fetch("result")
      fixed_ids = result.fetch("fixed").map { |t| t["threadId"] }
      refute_includes fixed_ids, "t1", "#{key}: a recurring candidate landed in fixed unattended"

      all_ids = %w[t1 t2]
      bucketed = result.values_at("fixed", "wontFix", "needsHuman", "conflicts").flatten
                       .filter_map { |t| t["threadId"] }
      bucketed += result.fetch("clusters").flat_map { |c| c.fetch("threads").map { |t| t["threadId"] } }
      bucketed += result.fetch("planClusters").flat_map { |c| c.fetch("threads").map { |t| t["threadId"] } }
      all_ids.each do |id|
        assert_equal 1, bucketed.count(id), "#{key}: thread #{id} must appear in exactly one bucket"
      end
    end
  end

  def test_drive_fails_closed_on_any_null_input
    happy_keys("drive").each do |key|
      result = run_harness("drive", null: key).fetch("result")
      converged = result["converged"]
      ci_green = result.dig("ciPrediction", "green")
      assert(converged == false || ci_green == false,
             "#{key}: expected converged false or ciPrediction.green false, got converged=#{converged} ciGreen=#{ci_green}")
    end
  end

  def test_sweep_merge_queue_holds_only_safe_prs
    happy_keys("sweep").each do |key|
      result = run_harness("sweep", null: key).fetch("result")
      queue = result.fetch("autoMergeQueue")
      by_number = result.fetch("facts").to_h { |f| [ f["number"], f ] }
      queue.each do |number|
        fact = by_number[number]
        refute_nil fact, "#{key}: PR ##{number} in queue has no gathered facts"
      end

      all_numbers = result.fetch("facts").map { |f| f["number"] }
      held_numbers = result.fetch("holds").map { |h| h["number"] }
      all_numbers.each do |number|
        assert(queue.include?(number) || held_numbers.include?(number),
               "#{key}: PR ##{number} is neither queued nor held")
      end

      conflicted_numbers = result.fetch("conflicts").select { |c| c["conflicts"] }
                                  .flat_map { |c| [ c["a"], c["b"] ] }
      stacked_numbers = result.fetch("facts").select { |f| f["stackedOn"] }.map { |f| f["number"] }
      (conflicted_numbers + stacked_numbers).each do |number|
        refute_includes queue, number, "#{key}: PR ##{number} with a conflict or stacked dependency is in the queue"
      end
    end
  end

  def test_code_review_marks_incomplete_shards_instead_of_posting_silently
    happy_keys("code-review").each do |key|
      result = run_harness("code-review", null: key).fetch("result")
      assert result.key?("incomplete"), "#{key}: result does not carry an incomplete flag at all"
    end
  end

  # Every Find lens and every Verify verdict on the shard actually reviewed
  # gates coverage: a null at any of them must surface as incomplete.
  def test_code_review_null_find_or_verify_marks_shard_incomplete
    %w[core:rubric#1 core:general#1 a.js:10#1 b.js:20#1].each do |key|
      result = run_harness("code-review", null: key).fetch("result")
      assert_equal true, result["incomplete"], "#{key}: null result still reported full coverage"
      assert_includes result["incompleteShards"], "core", "#{key}: core shard not named incomplete"
    end
    assert_equal false, run_harness("code-review").fetch("result")["incomplete"], "happy path reported incomplete"
  end
end
