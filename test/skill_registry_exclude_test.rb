# frozen_string_literal: true

require_relative "test_helpers"

# The `exclude` suppression gate: a marker file present in the project root
# turns a structural match off. Inert without a root, and honored by detect.
# Includes the shipped drizzle/github-actions suppression scenarios.
class SkillRegistryExcludeTest < Minitest::Test
  include SkillRegistryHelpers

  def test_exclude_suppresses_match_when_root_given
    skill_dir("drizzle", auto: { "paths" => [ "**/schema.ts" ], "exclude" => [ "**/schema.prisma" ] })
    skill = load.first
    proj = project_with("prisma/schema.prisma", "src/schema.ts")
    refute skill.matches?(File.join(proj, "src/schema.ts"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_exclude_is_inert_without_root
    skill_dir("drizzle", auto: { "paths" => [ "**/schema.ts" ], "exclude" => [ "**/schema.prisma" ] })
    assert load.first.matches?("/p/src/schema.ts")
  end

  def test_exclude_does_not_suppress_when_marker_absent
    skill_dir("drizzle", auto: { "paths" => [ "**/schema.ts" ], "exclude" => [ "**/schema.prisma" ] })
    skill = load.first
    proj = project_with("src/schema.ts")
    assert skill.matches?(File.join(proj, "src/schema.ts"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_detected_honors_exclude
    skill_dir("drizzle", auto: { "detect" => [ "drizzle.config.ts" ], "exclude" => [ "**/schema.prisma" ] })
    skill = load.first
    conflict = project_with("drizzle.config.ts", "prisma/schema.prisma")
    clean = project_with("drizzle.config.ts")
    refute skill.detected?(conflict)
    assert skill.detected?(clean)
  ensure
    FileUtils.remove_entry(conflict) if conflict
    FileUtils.remove_entry(clean) if clean
  end

  def test_empty_exclude_leaves_detect_unchanged
    skill_dir("ruby", auto: { "detect" => [ "Gemfile" ] })
    skill = load.first
    proj = project_with("Gemfile")
    assert skill.detected?(proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end
end
