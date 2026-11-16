# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../scripts/roast_lens"
require_relative "../scripts/skill_registry"

# cf:simplicity is a roast lens only: a group: rubrics skill with no auto:
# block, so RoastLens finds it and SkillRegistry (the auto-firing set behind
# the per-change review) never does.
class SimplicityLensTest < Minitest::Test
  SKILLS = File.expand_path("../skills", __dir__)
  PATH = File.join(SKILLS, "simplicity", "SKILL.md")

  def frontmatter
    front, = SkillRegistry::Frontmatter.split(File.read(PATH))
    YAML.safe_load(front)
  end

  def test_rubrics_include_simplicity_with_body
    lens = RoastLens.rubrics(SKILLS).fetch("simplicity")
    assert_equal "cf:simplicity", lens.name
    assert_includes lens.body, "least code, the fewest files"
    assert_includes lens.body, "NotifierFactory"
  end

  def test_resolve_returns_one_lens
    lenses = RoastLens.resolve(["cf:simplicity"], SKILLS)
    assert_equal ["cf:simplicity"], lenses.map(&:name)
  end

  def test_skill_registry_never_loads_it
    refute_includes SkillRegistry.load(SKILLS).map(&:name), "cf:simplicity"
  end

  def test_frontmatter_is_a_rubric_without_auto
    meta = frontmatter
    assert_equal "rubrics", meta["group"]
    refute meta.key?("auto")
  end
end
