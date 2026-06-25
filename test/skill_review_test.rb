# frozen_string_literal: true

require_relative "test_helpers"

class SkillReviewTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] }, body: "POODR-PRINCIPLES")
    skill_dir("refactoring", auto: { "all_code" => true }, body: "FOWLER-PRINCIPLES")
    skill_dir("ai-slop", auto: { "all_files" => true }, body: "SLOP-PRINCIPLES")
  end

  def teardown
    FileUtils.remove_entry(@skills)
    super
  end

  def review(session: "s1", stop_active: false)
    io = StringIO.new
    event = { "session_id" => session, "stop_hook_active" => stop_active }
    SkillReview.new(event, skills: SkillRegistry.load(@skills)).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string)
  end

  def enqueue(skill, path, hash)
    ReviewQueue.new("s1").add(skill, path, hash)
  end

  def test_no_block_when_queue_empty
    assert_nil review
  end

  def test_blocks_with_fixed_prompt_embedding_files_and_principles
    enqueue("ruby", "/p/user.rb", "h1")
    out = review
    assert_equal "block", out["decision"]
    assert_includes out["reason"], "/p/user.rb"
    assert_includes out["reason"], "POODR-PRINCIPLES"
    assert_includes out["reason"], "run_in_background: false"
    assert_includes out["reason"], "review_ack.rb"
  end

  def test_all_code_section_includes_taxonomy_note
    enqueue("refactoring", "/p/main.go", "h1")
    assert_includes review["reason"], "genuinely code"
  end

  def test_extension_section_has_no_taxonomy_note
    enqueue("ruby", "/p/user.rb", "h1")
    refute_includes review["reason"], "genuinely code"
  end

  def test_all_files_section_tells_reviewer_to_include_prose
    enqueue("ai-slop", "/p/README.md", "h1")
    reason = review["reason"]
    assert_includes reason, "prose and documentation"
    refute_includes reason, "mark anything that is not code as clean"
  end

  def test_blocks_until_acked
    enqueue("ruby", "/p/user.rb", "h1")
    assert review, "blocks while the batch is unreviewed"
    ReviewQueue.new("s1").ack
    assert_nil review, "ack records the verdict; no further block"
  end

  def test_respects_stop_hook_active_guard
    enqueue("ruby", "/p/user.rb", "h1")
    assert_nil review(stop_active: true), "must not block while already continuing"
  end

  def test_converges_then_retriggers_on_new_content
    enqueue("ruby", "/p/user.rb", "h1")
    assert_equal "block", review["decision"], "round 1: find"
    ReviewQueue.new("s1").ack
    ReviewQueue.new("s1").add("ruby", "/p/user.rb", "h1")
    assert_nil review, "identical content stays reviewed, no new round"
    ReviewQueue.new("s1").add("ruby", "/p/user.rb", "h2")
    assert_equal "block", review["decision"], "new content re-triggers a review"
  end

  def test_round_cap_surfaces_a_visible_notice_instead_of_blocking
    enqueue("ruby", "/p/user.rb", "h1")
    ReviewQueue::CAP.times do |i|
      assert_equal "block", review["decision"], "round #{i + 1} should block"
    end
    out = review
    assert_nil out["decision"], "must not block once capped"
    assert_includes out["systemMessage"], "Round cap"
  end
end
