# frozen_string_literal: true

require_relative "test_helpers"

# Core loading and matching: extensions, basenames, detect markers, the
# all_code/all_files scope flags, and the shipped skills' intended scope.
# Path, exclude, require, and dep gating live in sibling files.
class SkillRegistryTest < Minitest::Test
  include SkillRegistryHelpers

  def test_loads_only_skills_with_an_auto_block
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    plain_skill("cf")
    assert_equal [ "ruby" ], load.map(&:name)
  end

  def test_matches_by_extension_case_insensitively
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    skill = load.first
    assert skill.matches?("/proj/lib/foo.RB")
    refute skill.matches?("/proj/README.md")
  end

  def test_matches_by_basename
    skill_dir("ruby", auto: { "extensions" => [ "rb" ], "basenames" => [ "Rakefile" ] })
    assert load.first.matches?("/proj/Rakefile")
  end

  def test_detected_by_marker_file
    skill_dir("ruby", auto: { "detect" => [ "Gemfile", "*.gemspec" ] })
    proj = Dir.mktmpdir
    refute load.first.detected?(proj)
    FileUtils.touch(File.join(proj, "Gemfile"))
    assert load.first.detected?(proj)
  ensure
    FileUtils.remove_entry(proj)
  end

  def test_all_code_matches_code_but_not_prose
    skill_dir("refactoring", auto: { "all_code" => true })
    skill = load.first
    assert skill.matches?("/proj/main.go")
    assert skill.matches?("/proj/app.py")
    refute skill.matches?("/proj/README.md")
    refute skill.matches?("/proj/data.json")
  end

  def test_all_files_matches_every_type
    skill_dir("ai-slop", auto: { "all_files" => true })
    skill = load.first
    assert skill.matches?("/proj/notes.md")
    assert skill.matches?("/proj/app.py")
    assert skill.matches?("/proj/Dockerfile")
    assert skill.matches?("/proj/lib/foo.rb")
  end

  def test_all_code_and_all_files_are_always_detected
    skill_dir("refactoring", auto: { "all_code" => true })
    skill_dir("ai-slop", auto: { "all_files" => true })
    by_name = load.to_h { |s| [ s.name, s ] }
    assert by_name["refactoring"].detected?(Dir.mktmpdir)
    assert by_name["ai-slop"].detected?(Dir.mktmpdir)
  end

  def test_scope_flags_do_not_leak_to_extension_skills
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    refute load.first.matches?("/proj/README.md")
  end

  def test_malformed_skill_is_skipped_not_fatal
    dir = File.join(@skills, "broken")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), "---\n: : not yaml :\n---\nbody")
    assert_equal [], load
  end

  def test_shipped_skills_declare_intended_scope
    by_name = SkillRegistry.load(REPO_SKILLS).to_h { |s| [ s.name, s ] }
    assert by_name["cf:ruby"].matches?("app/models/user.rb")
    assert by_name["cf:refactoring"].all_code?
    assert by_name["cf:refactoring"].matches?("src/main.go")
    refute by_name["cf:refactoring"].matches?("docs/notes.md")
    assert by_name["cf:ai-slop"].all_files?
    assert by_name["cf:ai-slop"].matches?("docs/notes.md")
    assert by_name["cf:ai-slop"].matches?("app/models/user.rb")
  end
end
