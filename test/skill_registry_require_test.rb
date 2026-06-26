# frozen_string_literal: true

require_relative "test_helpers"

# The glob form of the `require` gate: a match only stands when a required
# marker file exists in the project root. Inert without a root, gates detect
# too. Includes the shipped turbo-workspaces and docker scope scenarios.
# Content-based `require: [{dep: ...}]` gating lives in the dep file.
class SkillRegistryRequireTest < Minitest::Test
  include SkillRegistryHelpers

  def test_require_gates_match_on_project_marker
    skill_dir("drizzle", auto: { "paths" => [ "**/schema.js" ], "require" => [ "**/drizzle.config.*" ] })
    skill = load.first
    drz = project_with("drizzle.config.ts", "src/db/schema.js")
    plain = project_with("src/db/schema.js")
    assert skill.matches?(File.join(drz, "src/db/schema.js"), root: drz)
    refute skill.matches?(File.join(plain, "src/db/schema.js"), root: plain)
  ensure
    FileUtils.remove_entry(drz) if drz
    FileUtils.remove_entry(plain) if plain
  end

  def test_require_is_inert_without_root
    skill_dir("drizzle", auto: { "paths" => [ "**/schema.js" ], "require" => [ "**/drizzle.config.*" ] })
    assert load.first.matches?("/p/src/db/schema.js")
  end

  def test_require_gates_detection
    skill_dir("drizzle", auto: { "detect" => [ "**/schema.js" ], "require" => [ "**/drizzle.config.*" ] })
    skill = load.first
    drz = project_with("drizzle.config.ts", "src/db/schema.js")
    plain = project_with("src/db/schema.js")
    assert skill.detected?(drz)
    refute skill.detected?(plain)
  ensure
    FileUtils.remove_entry(drz) if drz
    FileUtils.remove_entry(plain) if plain
  end

  def test_empty_require_is_backward_compatible
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    skill = load.first
    proj = project_with("app.rb")
    assert skill.matches?(File.join(proj, "app.rb"), root: proj)
  ensure
    FileUtils.remove_entry(proj) if proj
  end

  def test_shipped_drizzle_fires_on_js_schema_in_drizzle_project
    drizzle = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:drizzle" }
    drz = project_with("drizzle.config.js", "src/db/schema.js")
    plain = project_with("src/db/schema.js")
    assert drizzle.matches?(File.join(drz, "src/db/schema.js"), root: drz),
           "fires on a plain-JS Drizzle schema in a Drizzle project"
    refute drizzle.matches?(File.join(plain, "src/db/schema.js"), root: plain),
           "stays off a schema.js in a project with no Drizzle marker"
  ensure
    FileUtils.remove_entry(drz) if drz
    FileUtils.remove_entry(plain) if plain
  end

  def test_shipped_turbo_workspaces_requires_a_turbo_json
    turbo = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:turbo-workspaces" }
    mono = project_with_files("turbo.json" => "{}", "package.json" => "{}", "apps/web/package.json" => "{}")
    plain = project_with_files("package.json" => "{}")
    assert turbo.matches?(File.join(mono, "apps/web/package.json"), root: mono)
    refute turbo.matches?(File.join(plain, "package.json"), root: plain),
           "a plain npm project (no turbo.json) must not attach turbo-workspaces"
  ensure
    [ mono, plain ].each { |d| FileUtils.remove_entry(d) if d }
  end

  def test_shipped_docker_matches_provisioning_files_only
    docker = SkillRegistry.load(REPO_SKILLS).find { |s| s.name == "pst:docker" }
    assert docker.matches?("Dockerfile")
    assert docker.matches?("apps/api/Dockerfile")
    assert docker.matches?("docker-compose.yml")
    assert docker.matches?("Brewfile")
    refute docker.matches?("README.md")
    refute docker.matches?("src/app.js")
  end
end
