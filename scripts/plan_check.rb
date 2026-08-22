#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'glyph_guard'

# Mechanically verifies a landed cf:plan triple: plan.md, goal.md, and the
# workflow.js that operationalizes the plan. Every file must exist and be
# non-empty, goal.md must be at or under the 4000-character hard cap, no file
# may carry an AI-slop glyph, and workflow.js must satisfy the Workflow tool's
# authoring contract as far as a text check can reach it. Every check runs and
# reports (not fail-fast), so a single invocation names everything wrong at
# once rather than making the writing agent fix one thing and re-run to
# discover the next. The glyph check reuses GlyphGuard::PATTERN directly so the
# checker can never drift from the hook that already guards Write/Edit.
module PlanCheck
  GOAL_CAP = 4000
  THIN_PLAN_LINES = 60

  # The Workflow tool re-executes a script's prelude on resume, so a value that
  # differs between executions silently changes the run. There is no way to
  # observe that from outside, which is what makes a grep worth having.
  NONDETERMINISM = { 'Date.now(' => 'Date.now()', 'Math.random(' => 'Math.random()',
                     'new Date(' => 'new Date()' }.freeze

  Result = Data.define(:lines, :warnings, :ok?)

  def self.run(goal_path, plan_path, workflow_path = nil)
    lines = []
    ok = true

    ok &= check_non_empty(plan_path, 'plan.md', lines)
    ok &= check_non_empty(goal_path, 'goal.md', lines)
    ok &= check_goal_cap(goal_path, lines)
    ok &= check_glyphs(goal_path, 'goal.md', lines)
    ok &= check_glyphs(plan_path, 'plan.md', lines)
    ok &= check_workflow(workflow_path, lines) if workflow_path

    warnings = plan_warnings(plan_path)
    Result.new(lines:, warnings:, ok?: ok)
  end

  # The Workflow script is checked by grep, not by parsing: the checker has no
  # JS engine and the tool itself is the real validator. These are the failures
  # that survive a valid parse and only surface at run time, when the plan is
  # already being executed by someone else.
  def self.check_workflow(path, lines)
    ok = check_non_empty(path, 'workflow.js', lines)
    return false unless ok

    ok &= check_glyphs(path, 'workflow.js', lines)
    text = File.read(path)
    ok &= require_marker(text, /^export const meta = \{/, 'export const meta = { literal header', lines)
    ok &= require_marker(text, /\bphase\(/, 'at least one phase() call', lines)
    ok &= check_determinism(text, lines)
    ok
  end

  def self.require_marker(text, pattern, label, lines)
    if text.match?(pattern)
      lines << "workflow.js: #{label} present"
      true
    else
      lines << "workflow.js: MISSING #{label}"
      false
    end
  end

  def self.check_determinism(text, lines)
    found = NONDETERMINISM.select { |needle, _| text.include?(needle) }.values
    if found.empty?
      lines << 'workflow.js: no nondeterministic calls'
      true
    else
      lines << "workflow.js: nondeterministic call(s) #{found.join(', ')}"
      false
    end
  end

  def self.check_non_empty(path, label, lines)
    if File.exist?(path) && !File.read(path).strip.empty?
      lines << "#{label}: present"
      true
    else
      lines << "#{label}: MISSING or empty (#{path})"
      false
    end
  end

  def self.check_goal_cap(path, lines)
    return false unless File.exist?(path)

    count = File.read(path, encoding: 'UTF-8').length
    if count <= GOAL_CAP
      lines << "goal.md: #{count}/#{GOAL_CAP} characters OK"
      true
    else
      lines << "goal.md: #{count}/#{GOAL_CAP} characters OVER CAP"
      false
    end
  end

  def self.check_glyphs(path, label, lines)
    return false unless File.exist?(path)

    text = File.read(path)
    if text.match?(GlyphGuard::PATTERN)
      lines << "#{label}: contains a banned AI-slop glyph"
      false
    else
      lines << "#{label}: no banned glyphs"
      true
    end
  end

  # Advisory only: a thin plan.md is a signal, not a fact a script can settle,
  # so it never fails the run.
  def self.plan_warnings(path)
    return [] unless File.exist?(path)

    text = File.read(path)
    warnings = []
    warnings << "plan.md: under #{THIN_PLAN_LINES} lines" if text.lines.count < THIN_PLAN_LINES
    warnings << 'plan.md: no "## " heading found' unless text.match?(/^## /)
    warnings
  end

  module CLI
    def self.run(argv, out: $stdout)
      goal_path, plan_path, workflow_path = paths_for(argv)
      unless goal_path && plan_path
        out.puts('usage: plan_check.rb <plan_dir> | --goal <path> --plan <path> [--workflow <path>]')
        exit 2
      end

      result = PlanCheck.run(goal_path, plan_path, workflow_path)
      out.puts(result.lines)
      result.warnings.each { |w| out.puts("warning: #{w}") }
      exit(result.ok? ? 0 : 1)
    end

    # Directory mode checks the workflow script too, since a plan directory is
    # only complete with one. Flag mode checks it only when named, so a writing
    # agent mid-run can verify the pair before the script exists.
    def self.paths_for(argv)
      if argv.first && !argv.first.start_with?('--')
        dir = argv.first
        [ File.join(dir, 'goal.md'), File.join(dir, 'plan.md'), File.join(dir, 'workflow.js') ]
      else
        flags = parse(argv)
        return nil unless flags['goal'] && flags['plan']

        [ flags['goal'], flags['plan'], flags['workflow'] ]
      end
    end

    def self.parse(args)
      flags = {}
      until args.empty?
        token = args.shift
        key = token.start_with?('--') && token.delete_prefix('--')
        flags[key] = args.shift if key
      end
      flags
    end
  end
end

PlanCheck::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
