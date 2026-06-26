# frozen_string_literal: true

require_relative "test_helpers"

# The per-file `paths` glob: nested basenames, recursive directory globs,
# directory anchoring, extglob braces, and how paths compose with extensions.
class SkillRegistryPathsTest < Minitest::Test
  include SkillRegistryHelpers

  def test_paths_glob_matches_nested_basename
    skill_dir("drizzle", auto: { "paths" => [ "**/schema.ts" ] })
    skill = load.first
    assert skill.matches?("/p/src/db/schema.ts")
    refute skill.matches?("/p/src/db/schema.prisma")
    refute skill.matches?("/p/schemas.ts")
  end

  def test_paths_glob_directory_recursive
    skill_dir("drizzle", auto: { "paths" => [ "drizzle/**" ] })
    skill = load.first
    assert skill.matches?("/p/drizzle/0000.sql")
    assert skill.matches?("/p/drizzle/meta/snap.json")
    refute skill.matches?("/p/src/x.sql")
  end

  def test_paths_glob_anchored_to_directory
    skill_dir("gha", auto: { "paths" => [ ".github/workflows/*.yml" ] })
    skill = load.first
    assert skill.matches?("/p/.github/workflows/ci.yml")
    assert skill.matches?("/p/pkg/.github/workflows/ci.yml")
    refute skill.matches?("/p/docker-compose.yml")
    refute skill.matches?("/p/.github/workflows/sub/ci.yml")
  end

  def test_paths_glob_extglob_brace
    skill_dir("gha", auto: { "paths" => [ ".github/workflows/*.{yml,yaml}" ] })
    skill = load.first
    assert skill.matches?("/p/.github/workflows/ci.yaml")
    assert skill.matches?("/p/.github/workflows/ci.yml")
  end

  def test_paths_glob_matches_relative_path
    skill_dir("drizzle", auto: { "paths" => [ "src/**/db.ts" ] })
    assert load.first.matches?("src/server/db.ts")
  end

  def test_paths_compose_with_extensions_as_or
    skill_dir("drizzle", auto: { "extensions" => [ "sql" ], "paths" => [ "drizzle/**" ] })
    skill = load.first
    assert skill.matches?("/p/migrations/x.sql")
    assert skill.matches?("/p/drizzle/meta.json")
    refute skill.matches?("/p/app.ts")
  end

  def test_paths_absent_is_backward_compatible
    skill_dir("ruby", auto: { "extensions" => [ "rb" ] })
    refute load.first.matches?("/p/README.md")
  end
end
