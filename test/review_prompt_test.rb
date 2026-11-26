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
    refute_includes text, "run_in_background", "Agent calls return asynchronously; never ask to block on one"
    refute_includes text, "WAIT"
    assert_includes text, "When its result arrives"
    assert_includes text, "gate stays closed until this ack runs"
  end

  def test_reviewer_line_is_the_one_other_hosts_rewrite
    text = build([ { skill: "ruby", path: "/p/user.rb", hash: "h1" } ])
    assert_includes text, ReviewPrompt::REVIEWER, "cf_host_hook substitutes this exact text"
  end

  def test_build_names_every_key_in_one_ack_command
    text = build([ { skill: "ruby", path: "/p/user.rb", hash: "h1" } ], session: %w[s1 s1_a1])
    assert_match(/review_ack\.rb s1 s1_a1$/, text)
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

  # Stage 2 keeps only opted-in rubrics, so the judgment rubrics that no stage 1
  # linter replaces must carry `review: true` in the shipped registry.
  def test_shipped_judgment_rubrics_opt_in_to_the_review
    shipped = SkillRegistry.load(File.expand_path("../skills", __dir__)).to_h { |skill| [ skill.name, skill ] }
    %w[cf:oauth-jwt cf:terraform cf:postgres-sql cf:docker cf:nextjs].each do |name|
      assert_predicate shipped.fetch(name), :review?, "#{name} must opt in to the stage 2 review"
    end
  end
end
