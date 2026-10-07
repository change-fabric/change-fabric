#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/plan_check"

# Guards the cf:drive thorough engine against losing a lesson. Each release run that
# shaped this skill patched its workflow.js by hand; the engine half of the
# template carries those patches so a new plan starts with them. A plan's
# engine is diffed against this template at planning time (the thorough mode steps in SKILL.md),
# so what this test pins is what every thorough plan inherits.
class DriveThoroughTemplateTest < Minitest::Test
  SKILL = File.expand_path("../skills/drive", __dir__)
  TEMPLATE = File.join(SKILL, "reference", "thorough", "workflow-template.js")
  RUN_FILES = %w[review-findings qa-report gate-log followups owner-handoff run-log].freeze
  ENGINE_MARKER = "// ===== ENGINE"

  # Each guard is text the engine must keep, keyed by the failure it prevents.
  GUARDS = {
    "halts only on the explicit prefix, not a mail|sms regex" => 'SAFETY_PREFIX = "SAFETY STOP: "',
    "applies the prefix with startsWith" => "s.startsWith(SAFETY_PREFIX)",
    "refuses a sweep with no pinned health URL" => "change_run.rb without --health-url",
    "refuses a QA sweep that would publish" => "QA sweep without --no-publish",
    "reviews only the delta after two rounds" => "FULL_DIFF_ROUNDS = 2",
    "needs a recorded owner approval to carry a lane" => "starting 'OWNER APPROVAL'",
    "stops reviewers discounting admin-only bugs" => "Who can trigger a bug never lowers its severity",
    "demands a failing test before each fix" => "failingFirst",
    "revises an open fix PR in place" => "batch.revise",
    "passes the planner's notes to the fix agent" => "Planner notes, constraints to honor",
    "hard-stops a fix on schema paths" => "PLAN.fix.schemaPaths",
    "turns denials into owner questions" => "do not route around it",
    "merges open fixes together for pre-merge QA" => "git merge --no-edit each of",
    "computes the diffs to read from changed paths" => "Compute them, do not copy them",
    "requires a unit for every touched risk area" => "but no review unit has kind",
    "keeps one writer for the ledgers" => "You are the single writer for"
  }.freeze

  def template = File.read(TEMPLATE)

  def engine = template.split(ENGINE_MARKER, 2).last

  def test_template_splits_into_plan_and_engine_once
    assert_equal 1, template.scan(ENGINE_MARKER).size
    assert_equal 1, template.scan("// ===== PLAN").size
  end

  def test_engine_keeps_every_guard
    missing = GUARDS.reject { |_, text| engine.include?(text) }
    assert_empty missing.keys, "engine lost guards"
  end

  def test_lanes_run_one_at_a_time
    assert_match(/for \(const lane of lanes\)/, engine)
    refute_match(/parallel\([^)]*lanes/, engine)
  end

  def test_placeholders_live_only_in_the_plan_half
    refute_includes engine, "FILL:"
  end

  def test_every_phase_call_matches_a_meta_title
    titles = template[/export const meta = \{.*?\n\}/m].scan(/title: "([^"]+)"/).flatten
    calls = engine.scan(/phase: "([^"]+)"|phase\("([^"]+)"\)/).flatten.compact.uniq
    assert_empty calls - titles, "phase names missing from meta.phases"
  end

  def test_template_passes_the_workflow_contract_checks
    lines = []
    assert PlanCheck.check_determinism(template, lines), lines.join("\n")
    refute_match PlanCheck::GLYPHS, template
  end

  def test_run_templates_exist_and_name_their_single_writer
    RUN_FILES.each do |name|
      path = File.join(SKILL, "reference", "thorough", "templates", "#{name}.md")
      assert File.exist?(path), "missing template #{name}.md"
      assert_match(/^Writer: .*nobody else/, File.read(path), "#{name}.md must name its single writer")
    end
  end

  def test_skill_prose_is_free_of_slop_glyphs
    Dir.glob(File.join(SKILL, "**", "*.md")).each do |path|
      refute_match PlanCheck::GLYPHS, File.read(path), path
    end
  end

  def skill_md = File.read(File.join(SKILL, "SKILL.md"))

  def test_trigger_line_defaults_to_thorough
    trigger = skill_md[/^Trigger: .*\n.*$/]
    assert_includes trigger, "`/cf:drive [thorough|quick] <PR url or change set> [--area <name>] [--signoff]`"
    assert_match(/Mode defaults to `thorough`/, trigger)
  end

  def test_description_names_both_modes
    desc = skill_md[/^description: (.*)$/, 1]
    assert desc.length <= 1026, "description too long"
    assert_match(/\bquick\b/, desc)
    assert_match(/\bthorough\b/, desc)
  end

  META_PLACEHOLDERS = %w[{{placeholder}} {{...}}].freeze

  def test_parameter_table_covers_every_thorough_placeholder
    table = skill_md[/^## Parameters\n(.*?)^## /m, 1]
    refute_nil table, "missing ## Parameters section"
    used = Dir.glob(File.join(SKILL, "reference", "thorough", "*.md"))
              .flat_map { |f| File.read(f).scan(/\{\{[a-z_.]+\}\}/) }.uniq - META_PLACEHOLDERS
    refute_empty used
    assert_empty used.reject { |ph| table.include?(ph) }, "placeholders missing from the parameter table"
  end
end
