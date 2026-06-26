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

  def test_shipped_drizzle_fires_on_drizzle_files_only
    by_name = SkillRegistry.load(REPO_SKILLS).to_h { |s| [ s.name, s ] }
    drizzle = by_name["pst:drizzle"]
    assert drizzle.matches?("src/db/schema.ts")
    assert drizzle.matches?("drizzle.config.ts")
    refute drizzle.matches?("src/components/Button.tsx")
  end

  def test_shipped_drizzle_suppressed_in_prisma_project
    drizzle = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:drizzle" }
    prisma = project_with("prisma/schema.prisma", "src/db/schema.ts")
    real = project_with("drizzle.config.ts", "src/db/schema.ts")
    refute drizzle.matches?(File.join(prisma, "src/db/schema.ts"), root: prisma)
    assert drizzle.matches?(File.join(real, "src/db/schema.ts"), root: real)
  ensure
    FileUtils.remove_entry(prisma) if prisma
    FileUtils.remove_entry(real) if real
  end

  def test_shipped_github_actions_fires_on_workflows_only
    gha = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:github-actions" }
    assert gha.matches?(".github/workflows/ci.yml")
    refute gha.matches?("docker-compose.yml")
    refute gha.matches?("config/app.yaml")
  end
end
