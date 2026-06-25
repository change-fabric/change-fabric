# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../scripts/review_prompt"

class ReviewPromptTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def setup
    super
    @skills = Dir.mktmpdir
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] }, body: "POODR-PRINCIPLES")
    skill_dir("ai-slop", auto: { "all_files" => true }, body: "SLOP-PRINCIPLES")
    @registry = SkillRegistry.load(@skills)
  end

  def teardown
    FileUtils.remove_entry(@skills)
    super
  end

  def build(entries, session: "s1")
    ReviewPrompt.build(entries, @registry, session)
  end

  def test_build_embeds_files_and_principles
    text = build([ { skill: "ruby", path: "/p/user.rb", hash: "h1" } ])
    assert_includes text, "/p/user.rb"
    assert_includes text, "POODR-PRINCIPLES"
    assert_includes text, "run_in_background: false", "review must be synchronous, not backgrounded"
  end

  def test_build_embeds_the_ack_command_with_session
    text = build([ { skill: "ruby", path: "/p/user.rb", hash: "h1" } ], session: "sess-42")
    assert_includes text, "review_ack.rb"
    assert_includes text, "sess-42"
  end

  def test_all_files_skill_tells_reviewer_to_include_prose
    text = build([ { skill: "ai-slop", path: "/p/README.md", hash: "h1" } ])
    assert_includes text, "prose and documentation"
  end

  def test_extension_skill_has_no_code_taxonomy_note
    text = build([ { skill: "ruby", path: "/p/user.rb", hash: "h1" } ])
    refute_includes text, "genuinely code"
  end

  def test_cap_notice_names_the_cap
    assert_includes ReviewPrompt.cap_notice(3), "Round cap (#{ReviewQueue::CAP})"
    assert_includes ReviewPrompt.cap_notice(3), "3 file(s)"
  end
end
