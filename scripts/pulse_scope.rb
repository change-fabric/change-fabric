#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'pulse_store'
require_relative 'cf_state'

# C7: the coordinator resolves the allowed scope sources before any review and
# persists them to pulse_scope.json. The reviewer never nominates a source.
class PulseScope
  GOAL_LINE = /^\s*pulse\.goal:\s*(.+?)\s*$/

  def initialize(session:, project:, plan_dir: nil, home: Dir.home)
    @session = session
    @project = project
    @home = home
    @plan_dir = plan_dir || recorded_plan_dir
  end

  def resolve
    sources = run_sources + project_source
    conflict = override_conflict?
    result = { 'sources' => sources, 'conflicts' => conflict ? [ 'scope-conflict' ] : [],
               'report_only' => sources.empty? }
    dir = Pulse.session_dir(@session)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'pulse_scope.json'), JSON.pretty_generate(result))
    result
  end

  private

  # plan_path is stamped into the session record when a Workflow or plan run
  # starts (pulse_stamp.rb), so the coordinator needs no --plan-dir.
  def recorded_plan_dir
    path = CfState.new(host: 'claude', project: @project, session_id: @session, root: CfState.root(home: @home), home: @home).pulse['plan_path']
    path if path.is_a?(String) && File.directory?(path)
  rescue StandardError
    nil
  end

  def run_sources
    return [] unless @plan_dir

    { 'run_goal' => 'goal.md', 'run_plan' => 'plan.md' }.filter_map { |role, name| entry(role, File.join(@plan_dir, name)) }
  end

  def project_source
    path = goal_path(overrides.first.last) if overrides.any? && !override_conflict?
    path ||= ctx_goal
    path ? [ entry('project_goal', path) ].compact : []
  end

  def entry(role, path)
    return unless File.file?(path)

    { 'role' => role, 'source_path' => tilde(path), 'revision' => Pulse.sha(File.read(path)) }
  end

  def overrides
    %w[AGENTS.md CLAUDE.md].filter_map do |name|
      file = File.join(@project, name)
      next unless File.file?(file)

      goal = File.read(file)[GOAL_LINE, 1]
      [ file, goal ] if goal
    end
  end

  # The override names a goal document, relative to the project or with ~.
  def goal_path(goal)
    path = File.expand_path(goal.start_with?('~') ? goal.sub('~', @home) : goal, @project)
    path if File.file?(path)
  end

  def override_conflict? = overrides.map(&:last).uniq.size > 1

  def ctx_goal
    dir = File.join(@home, '.claude', 'cf', 'ctx', @project.gsub('/', '-'))
    [ File.join(dir, 'truth', 'goal.md'), File.join(dir, 'ROADMAP.md') ].find { |file| File.file?(file) }
  end

  def tilde(path) = path.sub(/\A#{Regexp.escape(@home)}(?=\/|\z)/, '~')
end

if __FILE__ == $PROGRAM_NAME
  opts = ARGV.drop(1).each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
  abort 'usage: pulse_scope.rb resolve --session ID [--project DIR] [--plan-dir DIR]' unless ARGV.first == 'resolve' && opts['session']
  puts JSON.generate(PulseScope.new(session: opts['session'], project: File.realpath(opts['project'] || Dir.pwd),
                                    plan_dir: opts['plan-dir']).resolve)
end
