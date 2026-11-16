# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/overnight_store"
require_relative "../scripts/overnight_plan"

# Guards the cf:overnight docs against the code they describe: the gates,
# the safety fields, the dispatch table, the disabled execution status, and
# the catalog row.
class OvernightSkillTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def skill = File.read(File.join(ROOT, "skills/overnight/SKILL.md"))
  def dispatch = File.read(File.join(ROOT, "skills/overnight/reference/dispatch.md"))

  def test_frontmatter_names_the_skill
    assert_match(/\A---\nname: cf:overnight\ngroup: workflow\ndescription: /, skill)
  end

  def test_lists_every_gate_once
    (1..12).each { |n| assert_equal 1, skill.scan(/^- ON-#{n}: /).size, "ON-#{n}" }
  end

  def test_names_every_safety_field
    OvernightPlan::SAFETY.each { |field| assert_includes skill, "`#{field}`" }
  end

  def test_states_execution_is_disabled
    refute OvernightStore::OVERNIGHT_EXECUTE_ENABLED
    assert_includes skill, "## Status: dry-run only"
    assert_includes skill, "`OVERNIGHT_EXECUTE_ENABLED`"
  end

  def test_dispatch_table_matches_the_store
    rows = dispatch.scan(/^\| ([a-z-]+) \| (.+?) \| (.+?) \|$/).reject { |r| r[0] == "Kind" }
    expected = OvernightStore::DISPATCH.map { |kind, row| [ kind, row[:idempotency], row[:lookup] ] }
    assert_equal expected, rows
  end

  def test_skill_points_at_the_dispatch_reference
    assert_includes skill, "`reference/dispatch.md`"
  end

  def test_catalog_row
    assert_match(/^\| `cf:overnight` \| /, File.read(File.join(ROOT, "skills/README.md")))
  end
end
