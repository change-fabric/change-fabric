# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../scripts/review_gate"
require_relative "support/autopilot_stub"

class ReviewGateTest < Minitest::Test
  include SkillTempHome
  include SkillFactory
  include AutopilotStub

  def setup
    super
    @skills = Dir.mktmpdir
    write_skill("ruby", "---\nname: ruby\ndescription: x\nreview: true\nauto:\n  extensions: [rb]\n---\n\nPOODR-PRINCIPLES\n")
  end

  def teardown
    FileUtils.remove_entry(@skills)
    super
  end

  def gate(command, session: "s1", tool: "Bash", cwd: nil, stage1: ->(_root) { nil })
    io = StringIO.new
    event = { "session_id" => session, "tool_name" => tool, "tool_input" => { "command" => command } }
    event["cwd"] = cwd if cwd
    ReviewGate.new(event, skills: SkillRegistry.load(@skills), stage1: stage1).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string)
  end

  def enqueue(session: "s1", path: "/p/user.rb", hash: "h1")
    ReviewQueue.new(session).add("ruby", path, hash)
  end

  def decision(out)
    out&.dig("hookSpecificOutput", "permissionDecision")
  end

  def test_denies_push_when_batch_unreviewed
    enqueue
    out = gate("git push -u origin feat/x")
    assert_equal "deny", decision(out)
    reason = out.dig("hookSpecificOutput", "permissionDecisionReason")
    assert_includes reason, "/p/user.rb"
    assert_includes reason, "POODR-PRINCIPLES"
  end

  def test_denies_pr_create_when_batch_unreviewed
    enqueue
    assert_equal "deny", decision(gate("gh pr create --fill"))
  end

  # Agent edits now live in their own keys; until the gate is scoped to the
  # pushed branch diff it must still see them, so nothing escapes unreviewed.
  def test_agent_key_rows_still_deny_and_the_ack_names_each_key
    ReviewQueue.new("s1:a1").add("ruby", "/w/agent.rb", "h1")
    enqueue
    out = gate("git push -u origin feat/x")
    reason = out.dig("hookSpecificOutput", "permissionDecisionReason")
    assert_equal "deny", decision(out)
    assert_includes reason, "/w/agent.rb"
    assert_includes reason, "review_ack.rb s1 s1_a1"
  end

  def test_allows_when_queue_empty
    assert_nil gate("git push")
  end

  def test_allows_non_trigger_command
    enqueue
    assert_nil gate("git status")
    assert_nil gate("git commit -m x")
  end

  def test_allows_non_bash_tool
    enqueue
    assert_nil gate("git push", tool: "Edit")
  end

  def test_allows_commit_mentioning_pr_create_in_message
    enqueue
    assert_nil gate('git commit -m "prepares for gh pr create later"')
  end

  def test_stays_denied_until_acked
    enqueue
    assert_equal "deny", decision(gate("git push")), "blocks while unreviewed"
    assert_equal "deny", decision(gate("git push")), "still blocks - the gate never clears itself"
    ReviewQueue.new("s1").ack
    assert_nil gate("git push"), "ack records the verdict and releases the gate"
  end

  def test_new_edit_after_ack_rearms_the_gate
    enqueue(hash: "h1")
    assert_equal "deny", decision(gate("git push"))
    ReviewQueue.new("s1").ack
    assert_nil gate("git push"), "released after review"
    enqueue(hash: "h2")
    assert_equal "deny", decision(gate("git push")), "a new content hash re-arms the gate"
  end

  def test_capped_surfaces_notice_instead_of_denying
    enqueue
    ReviewQueue::CAP.times do |i|
      assert_equal "deny", decision(gate("git push")), "round #{i + 1} blocks"
    end
    out = gate("git push")
    assert_nil decision(out), "must not deny once capped"
    assert_includes out["systemMessage"], "Round cap"
  end

  def test_a_new_file_after_the_cap_denies_again
    enqueue
    ReviewQueue::CAP.times { gate("git push") }
    enqueue(path: "/p/other.rb")
    assert_equal "deny", decision(gate("git push")), "a new file resumes the gate"
  end

  def test_ack_clears_both_gate_and_stop
    enqueue
    assert_equal "deny", decision(gate("git push")), "gate blocks"
    ReviewQueue.new("s1").ack
    assert_nil gate("git push"), "gate released after ack"
    stop = StringIO.new
    SkillReview.new({ "session_id" => "s1" }, skills: SkillRegistry.load(@skills)).emit(stop)
    assert_empty stop.string, "Stop sees an empty queue after the same ack"
  end

  def test_an_autopilot_naming_review_allows_the_push_and_keeps_the_queue
    enqueue
    with_autopilot do |calls|
      assert_nil gate("git push -u origin feat/x")
      assert_equal "review", calls.first.first
    end
    refute_empty ReviewQueue.new("s1").pending
    assert_equal "deny", decision(gate("git push -u origin feat/x")), "without the autopilot the gate is back"
  end

  def report(*statuses)
    results = statuses.each_with_index.map do |status, i|
      ReviewStage1::Result.new(id: "check#{i}", status: status, detail: "detail#{i}", command: nil, findings: [ "f.rb:#{i + 1}: bad" ])
    end
    ReviewStage1::Report.new(results)
  end

  def test_a_blocking_stage1_denies_with_findings_and_never_builds_the_model_prompt
    enqueue
    out = gate("git push", cwd: Dir.pwd, stage1: ->(_root) { report("failed") })
    reason = out.dig("hookSpecificOutput", "permissionDecisionReason")
    assert_equal "deny", decision(out)
    assert_includes reason, "Stage 1 blocked"
    assert_includes reason, "f.rb:1: bad"
    refute_includes reason, "Launch the review now"
  end

  def test_stage1_blocks_even_with_an_empty_review_queue
    assert_equal "deny", decision(gate("git push", cwd: Dir.pwd, stage1: ->(_root) { report("timed_out") }))
  end

  def test_stage1_unavailable_blocks
    assert_equal "deny", decision(gate("git push", cwd: Dir.pwd, stage1: ->(_root) { report("unavailable") }))
  end

  def test_an_all_clear_stage1_hands_back_the_stage2_prompt_for_the_worker_role
    enqueue
    out = gate("git push", cwd: Dir.pwd, stage1: ->(_root) { report("passed", "not_applicable") })
    reason = out.dig("hookSpecificOutput", "permissionDecisionReason")
    assert_equal "deny", decision(out)
    assert_includes reason, "Stage 1"
    assert_includes reason, "Judge only these items"
    assert_includes reason, "second_caller"
    assert_includes reason, 'model: "sonnet"', "stage 2 runs on the worker role"
    assert_includes reason, "review_findings.rb s1"
    assert_includes reason, "POODR-PRINCIPLES", "a review: true rubric matching the diff rides along"
  end

  def test_all_clear_with_nothing_queued_allows
    assert_nil gate("git push", cwd: Dir.pwd, stage1: ->(_root) { report("passed") })
  end

  def test_stage1_is_not_run_without_a_repo_root
    called = false
    assert_nil gate("git push", stage1: ->(_root) { called = true })
    refute called
  end

  def test_stage1_is_not_run_for_a_non_trigger_command
    called = false
    gate("git status", cwd: Dir.pwd, stage1: ->(_root) { called = true })
    refute called
  end

  def test_a_rubric_without_review_true_is_not_embedded_in_stage2
    write_skill("plain-ruby", "---\nname: plain-ruby\ndescription: x\nauto:\n  extensions: [rb]\n---\n\nSHOULD-NOT-APPEAR\n")
    ReviewQueue.new("s1").add("plain-ruby", "/p/a.rb", "h1")
    reason = gate("git push", cwd: Dir.pwd, stage1: ->(_root) { report("passed") }).dig("hookSpecificOutput", "permissionDecisionReason")
    refute_includes reason, "SHOULD-NOT-APPEAR"
  end

  def test_stage1_runs_in_the_directory_a_leading_cd_names
    other = File.realpath(Dir.mktmpdir)
    system("git", "-C", other, "init", "-q", out: File::NULL)
    seen = nil
    gate("cd #{other} && git push", cwd: Dir.pwd, stage1: ->(root) { seen = root; nil })
    assert_equal other, seen
    seen = nil
    gate("cd /no/such/dir && git push", cwd: Dir.pwd, stage1: ->(root) { seen = root; nil })
    assert_equal ReviewScope.repo_root(Dir.pwd), seen, "an unusable cd target falls back to the cwd"
  ensure
    FileUtils.remove_entry(other)
  end
end
