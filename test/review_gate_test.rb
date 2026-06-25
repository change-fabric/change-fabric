# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../scripts/review_gate"

class ReviewGateTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] }, body: "POODR-PRINCIPLES")
  end

  def teardown
    FileUtils.remove_entry(@skills)
    super
  end

  def gate(command, session: "s1", tool: "Bash")
    io = StringIO.new
    event = { "session_id" => session, "tool_name" => tool, "tool_input" => { "command" => command } }
    ReviewGate.new(event, skills: SkillRegistry.load(@skills)).emit(io)
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

  def test_ack_clears_both_gate_and_stop
    enqueue
    assert_equal "deny", decision(gate("git push")), "gate blocks"
    ReviewQueue.new("s1").ack
    assert_nil gate("git push"), "gate released after ack"
    stop = StringIO.new
    SkillReview.new({ "session_id" => "s1" }, skills: SkillRegistry.load(@skills)).emit(stop)
    assert_empty stop.string, "Stop sees an empty queue after the same ack"
  end
end
