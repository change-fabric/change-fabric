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
    assert_includes out["reason"], "run_in_background: true"
  end

  def test_all_code_section_includes_taxonomy_note
    enqueue("refactoring", "/p/main.go", "h1")
    assert_includes review["reason"], "genuinely code"
  end

  def test_extension_section_has_no_taxonomy_note
    enqueue("ruby", "/p/user.rb", "h1")
    refute_includes review["reason"], "genuinely code"
  end

  def test_fires_once_per_batch
    enqueue("ruby", "/p/user.rb", "h1")
    assert review, "first stop should block for review"
    assert_nil review, "queue drained, second stop should not block"
  end

  def test_respects_stop_hook_active_guard
    enqueue("ruby", "/p/user.rb", "h1")
    assert_nil review(stop_active: true), "must not block while already continuing"
  end

  def test_converges_then_retriggers_on_new_content
    enqueue("ruby", "/p/user.rb", "h1")
    assert_equal "block", review["decision"], "round 1: find"
    ReviewQueue.new("s1").add("ruby", "/p/user.rb", "h1")
    assert_nil review, "identical content must not start another round"
    ReviewQueue.new("s1").add("ruby", "/p/user.rb", "h2")
    assert_equal "block", review["decision"], "new content re-triggers a review"
  end

  def test_round_cap_surfaces_a_visible_notice_instead_of_blocking
    ReviewQueue::CAP.times do |i|
      enqueue("ruby", "/p/f#{i}.rb", "h#{i}")
      assert_equal "block", review["decision"], "round #{i + 1} should block"
    end
    enqueue("ruby", "/p/extra.rb", "hx")
    out = review
    assert_nil out["decision"], "must not block once capped"
    assert_includes out["systemMessage"], "Round cap"
  end
end
