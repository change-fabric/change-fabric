# frozen_string_literal: true

require_relative "test_helpers"

# Keeps the rubric set small: every rubric an agent can load costs tokens in
# every session that loads it, and instruction-following falls as instruction
# count rises. Tokens are estimated at four characters each.
class RubricBudgetTest < Minitest::Test
  CHARS_PER_TOKEN = 4

  # Auto when detected: ai-slop and refactoring load in every code repo.
  ALWAYS_ON = %w[cf:ai-slop cf:refactoring].freeze
  DETECTED = %w[cf:nextjs cf:docker cf:turbo-workspaces].freeze
  REVIEW_TIME = %w[
    cf:terraform cf:usability cf:react cf:postgres-sql cf:pdf-rendering cf:railway cf:typescript
    cf:client-state cf:express-node cf:laravel cf:php cf:oauth-jwt cf:prisma cf:redis
  ].freeze
  CULLED = %w[javascript rails vite ruby github-actions js-testing drizzle].freeze

  ALWAYS_ON_BUDGET = 600
  TYPICAL_TS_NEXT_BUDGET = 1000
  # Target is about 5000 once the unread backend rubrics are audited; this
  # ceiling only stops growth until then.
  WHOLE_SET_BUDGET = 9000
  MAX_DESCRIPTION_CHARS = 450
  EMPHASIS = /\b(CRITICAL|MUST|IMPORTANT)\b/

  def rubrics
    @rubrics ||= Dir[File.join(REPO_SKILLS, "*", "SKILL.md")].sort.filter_map do |path|
      front, body = SkillRegistry::Frontmatter.split(File.read(path))
      meta = YAML.safe_load(front)
      next unless meta["group"] == "rubrics"

      { name: meta["name"], meta: meta, tokens: body.strip.length / CHARS_PER_TOKEN }
    end
  end

  def tokens(*names) = rubrics.select { |r| names.include?(r[:name]) }.sum { |r| r[:tokens] }

  def registry = SkillRegistry.load(REPO_SKILLS).to_h { |skill| [ skill.name, skill ] }

  def test_always_on_rubrics_stay_small
    assert_operator tokens(*ALWAYS_ON), :<=, ALWAYS_ON_BUDGET
  end

  def test_typical_typescript_next_session_fits_the_budget
    # What a session at the standard level surfaces for a Next.js TypeScript repo.
    surfaced = registry.values.select { |s| s.surfaces_at?("standard") }.map(&:name) & (ALWAYS_ON + DETECTED)
    assert_includes surfaced, "cf:nextjs"
    assert_operator tokens(*surfaced), :<=, TYPICAL_TS_NEXT_BUDGET
  end

  def test_whole_rubric_set_stays_under_the_ceiling
    assert_operator rubrics.sum { |r| r[:tokens] }, :<=, WHOLE_SET_BUDGET
  end

  def test_review_time_rubrics_are_not_surfaced_while_authoring_below_strict
    REVIEW_TIME.each do |name|
      skill = registry.fetch(name)
      assert_predicate skill, :review?, name
      refute skill.surfaces_at?("standard"), "#{name} must not surface at standard"
      refute skill.surfaces_at?("lean"), "#{name} must not surface at lean"
      assert skill.surfaces_at?("strict"), "#{name} surfaces at strict"
    end
  end

  def test_detected_and_always_on_rubrics_surface_at_every_level
    (ALWAYS_ON + DETECTED).each do |name|
      %w[lean standard strict].each { |level| assert registry.fetch(name).surfaces_at?(level), "#{name} at #{level}" }
    end
  end

  def test_nextjs_loads_only_with_the_next_dependency
    { "react" => false, "next" => true }.each do |dep, expected|
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "package.json"), JSON.generate("dependencies" => { dep => "1" }))
        assert_equal expected, registry.fetch("cf:nextjs").matches?("app/page.tsx", root: dir), dep
      end
    end
  end

  def test_railway_dockerfile_needs_railway_toml
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Dockerfile"), "FROM scratch\n")
      assert registry.fetch("cf:railway").gated?(dir)
      File.write(File.join(dir, "railway.toml"), "")
      refute registry.fetch("cf:railway").gated?(dir)
    end
  end

  def test_postgres_sql_covers_drizzle_files
    skill = registry.fetch("cf:postgres-sql")
    assert skill.matches?("drizzle.config.ts")
    assert skill.matches?("drizzle/0001_init.sql")
    assert_includes skill.body, "drizzle-kit push"
  end

  def test_culled_rubrics_are_gone
    CULLED.each { |name| refute Dir.exist?(File.join(REPO_SKILLS, name)), "skills/#{name} was culled" }
  end

  def test_aws_stays_a_roast_lens_only
    meta = YAML.safe_load(SkillRegistry::Frontmatter.split(File.read(File.join(REPO_SKILLS, "aws", "SKILL.md"))).first)
    refute meta.key?("auto")
  end

  def test_no_emphasis_words_or_long_descriptions_in_skills
    Dir[File.join(REPO_SKILLS, "**", "*.md")].each do |path|
      refute_match EMPHASIS, File.read(path), "#{path} shouts"
    end
    Dir[File.join(REPO_SKILLS, "*", "SKILL.md")].each do |path|
      desc = YAML.safe_load(SkillRegistry::Frontmatter.split(File.read(path)).first)["description"].to_s
      assert_operator desc.length, :<=, MAX_DESCRIPTION_CHARS, "#{path} description is #{desc.length} chars"
    end
  end

  def test_session_level_chain
    Dir.mktmpdir do |home|
      assert_equal "standard", SkillRegistry.session_level(env: {}, home: home)
      FileUtils.mkdir_p(File.join(home, ".claude", "cf"))
      File.write(File.join(home, ".claude", "cf", "doctrine_level"), "lean\n")
      assert_equal "lean", SkillRegistry.session_level(env: {}, home: home)
      assert_equal "strict", SkillRegistry.session_level(env: { "CF_DOCTRINE_LEVEL" => "strict" }, home: home)
      assert_equal "lean", SkillRegistry.session_level(env: { "CF_DOCTRINE_LEVEL" => "bogus" }, home: home)
    end
  end
end
