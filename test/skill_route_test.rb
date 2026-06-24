# frozen_string_literal: true

require_relative "test_helpers"

class SkillRouteTest < Minitest::Test
  include SkillFactory

  def setup
    @skills = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@skills)
  end

  def route(paths)
    SkillRoute.new(paths, skills: SkillRegistry.load(@skills))
  end

  def ruby_skill = skill_dir("ruby", auto: { "extensions" => [ "rb" ] })

  def test_groups_files_under_every_skill_that_matches
    ruby_skill
    skill_dir("ai-slop", auto: { "all_files" => true })
    grouped = route(%w[app/user.rb README.md]).by_skill
    assert_equal %w[app/user.rb], grouped["ruby"]
    assert_equal %w[README.md app/user.rb], grouped["ai-slop"]
  end

  def test_skill_matching_nothing_is_absent
    ruby_skill
    assert_equal({}, route(%w[README.md]).by_skill)
  end

  def test_render_lists_each_skill_with_its_files
    ruby_skill
    output = route(%w[a.rb b.rb]).render
    assert_equal "ruby (2):\n  a.rb\n  b.rb", output
  end

  def test_render_reports_no_match
    ruby_skill
    assert_equal "No pst skills match the given files.", route(%w[README.md]).render
  end

  def test_from_reads_paths_from_stdin_when_argv_empty
    skill_dir("ai-slop", auto: { "all_files" => true })
    skills = SkillRegistry.load(@skills)
    router = SkillRoute.from([], input: StringIO.new("a.rb\n\nb.md\n"), skills: skills)
    assert_equal({ "ai-slop" => %w[a.rb b.md] }, router.by_skill)
  end

  def test_shipped_skills_route_a_mixed_changeset
    skills = SkillRegistry.load(REPO_SKILLS)
    grouped = SkillRoute.new(%w[app/user.rb src/app.tsx README.md], skills: skills).by_skill
    assert_equal %w[README.md app/user.rb src/app.tsx], grouped["pst:ai-slop"]
    assert_equal %w[app/user.rb src/app.tsx], grouped["pst:refactoring"]
    assert_equal %w[app/user.rb], grouped["pst:ruby"]
    assert_equal %w[src/app.tsx], grouped["pst:react"]
    refute grouped.key?("pst:vite")
  end
end
