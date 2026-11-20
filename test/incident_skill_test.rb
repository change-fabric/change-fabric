# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/incident_store"

# cf:incident is a skill protocol over scripts/incident_store.rb. These checks
# pin the rules the protocol states in prose, so a rewrite cannot quietly drop
# one.
class IncidentSkillTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SKILL = File.read(File.join(ROOT, "skills/incident/SKILL.md"))
  REFERENCES = Dir[File.join(ROOT, "skills/incident/reference/*.md")]

  def flat = SKILL.gsub(/\s+/, " ")

  def test_frontmatter_names_the_skill
    assert_match(/\A---\nname: cf:incident\ngroup: workflow\ndescription: .+\n---\n/, SKILL)
  end

  def test_stops_for_a_one_way_door_before_any_code
    assert_match(/One-way-door stop: when any path matches, stop before writing code and ask Patrick/, flat)
    %w[destructive_data contracts_and_auth money_and_sends infra gate_config].each { |door| assert_includes SKILL, door }
  end

  def test_the_hotfix_pr_body_carries_the_incident_line
    assert_includes SKILL, "`Incident: <id>`"
  end

  def test_never_runs_a_prod_command_or_pushes_a_tag
    assert_match(/Never run a production command and never push a tag/, flat)
    assert_match(/Never push a tag/, flat)
    assert_match(%r{manual/}, SKILL)
    refute_match(/git push[^\n]*(--tags|origin v)/, SKILL)
  end

  def test_the_store_records_approval_and_never_grants_it
    assert_match(/it never grants one/, flat)
    assert_match(/--approved-by/, SKILL)
  end

  def test_uses_role_tokens_and_no_literal_model_names
    assert_equal %w[author critic worker], SKILL.scan(/\{\{model:(\w+)\}\}/).flatten.uniq.sort
    (REFERENCES + [ File.join(ROOT, "skills/incident/SKILL.md") ]).each do |file|
      refute_match(/\b(opus|sonnet|haiku)\b/i, File.read(file), file)
    end
  end

  def test_advisory_limit_wording_is_exact
    assert_match(/2 attempts or 60 minutes/, flat)
    refute_match(/two attempts|60 min\b|1 hour/i, SKILL)
  end

  def test_the_roast_bar_is_never_hardcoded
    assert_match(/roast\.rb settings/, SKILL)
    refute_match(/roast[^.]*\b(score|bar|target) (of )?(8|9|10)\b/i, SKILL)
  end

  def test_verified_rule_and_close_preconditions_are_stated
    assert_match(/a tag alone never establishes it/, flat)
    assert_match(/refuses unless status is `reported`/, flat)
    assert_match(/`rca\.md` was modified after verified/, flat)
  end

  def test_the_runbook_reference_covers_the_migrations_caveat_and_no_prompts
    text = File.read(File.join(ROOT, "skills/incident/reference/rollback-runbook.md")).gsub(/\s+/, " ")
    assert_match(/Migrations do not roll back/, text)
    assert_match(%r{No y/N prompts}, text)
    assert_match(/No runbook found means no commands/, text)
  end

  def test_the_rca_template_has_the_headers_and_sections
    text = File.read(File.join(ROOT, "skills/incident/reference/rca-template.md"))
    %w[Date Environments Impact Issue].each { |header| assert_match(/^#{header}: /, text) }
    [ "Detection", "What happened", "Mitigation", "Fix", "Prevention", "Follow-ups" ].each do |name|
      assert_match(/^## #{name}$/, text)
    end
  end

  def status_section = flat[/## Status (.*?) ## Models/, 1]

  def test_the_status_section_matches_the_store_transition_table_exactly
    described = {}
    status_section.split(";").each do |clause|
      from, tos = clause.strip.sub(/\.\s*`set` cannot jump\.?\z/, "").sub(/\s*\(only via .*?\)/, "").split(" to ", 2)
      described[from.delete("`").strip] = tos.scan(/`(\w+)`/).flatten
    end
    described.transform_values! { |tos| tos.sort }
    expected = IncidentStore::STATUS_FLOW.reject { |_, tos| tos.empty? }.transform_values(&:sort)
    assert_equal expected, described
  end

  def test_every_status_the_skill_names_is_a_real_state
    names = IncidentStore::STATUS_FLOW.keys
    named = flat.scan(/(?:--status|leave the incident at|unless status is|sets|status becomes) `?(\w+)`?/).flatten
    named.reject! { |word| %w[approved running succeeded failed].include?(word) }
    refute_empty named
    assert_empty named - names
  end

  def test_the_attempt_limit_leaves_the_incident_at_fixing
    assert_match(/2 attempts or 60 minutes, then page Patrick and leave the incident at `fixing`/, flat)
    assert_includes IncidentStore::STATUS_FLOW.fetch("open"), "fixing"
  end
end
