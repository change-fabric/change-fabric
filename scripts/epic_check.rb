#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'epic_store'
require_relative 'epic_graph'

# Structural validation of a cross-repo epic. Every check runs and reports a
# `"<kind>: <detail>"` line (never fail-fast), so one run names everything
# wrong. Exit 0 clean, 1 problems, 2 usage error. `--order` prints the
# dependency layers instead, or the cycle when there is one.
module EpicCheck
  Result = Data.define(:problems, :order) do
    def ok? = problems.empty?
  end

  def self.run(epic)
    problems = epic.problems.dup
    plans = index_plans(epic, problems)
    check_repos(epic, problems)
    phases = check_plan_files(epic, problems)
    check_edges(epic, plans, phases, problems)
    check_criteria(epic, problems)
    order = EpicGraph.build(epic).order
    problems << "cycle: #{order.cycle.join(', ')}" unless order.cycle.empty?
    Result.new(problems:, order:)
  end

  def self.index_plans(epic, problems)
    epic.plans.each_with_object({}) do |plan, index|
      id = plan['id'].to_s
      problems << "plan: entry with no id (dir #{plan['dir']})" if id.empty?
      problems << "duplicate_plan: #{id}" if index.key?(id)
      index[id] ||= plan
    end
  end

  def self.check_repos(epic, problems)
    epic.plans.each do |plan|
      next if epic.repos.include?(plan['repo'])

      problems << "out_of_scope_repo: #{plan['id']} repo #{plan['repo'].inspect} is not in repos"
    end
  end

  # The first entry for a duplicated id wins, matching index_plans, so a
  # duplicate is reported once and does not cascade into edge problems.
  def self.check_plan_files(epic, problems)
    epic.plans.each_with_object({}) do |plan, numbers|
      phases = plan['dir'].to_s.empty? ? nil : EpicStore.phases_for(epic, plan)
      problems << "missing_plan: #{plan['id']} has no plan.md at #{plan['dir'].inspect}" unless phases
      numbers[plan['id'].to_s] ||= (phases || []).map(&:first)
    end
  end

  def self.check_edges(epic, plans, phases, problems)
    epic.edges.each do |edge|
      %w[from to].each do |side|
        ref = edge[side].to_s
        match = EpicGraph::NODE.match(ref)
        if !match
          problems << "bad_edge: #{side} #{ref.inspect} is not <plan_id>#Phase N"
        elsif !plans.key?(match[:plan])
          problems << "unknown_plan: edge #{side} #{ref} names no plan in this epic"
        elsif !phases.fetch(match[:plan], []).include?(match[:phase].to_i)
          problems << "missing_node: edge #{side} #{ref} has no such phase heading"
        end
      end
    end
  end

  def self.check_criteria(epic, problems)
    dirs = epic.plans.map { |plan| plan['dir'].to_s }
    seen = {}
    epic.criteria.each do |criterion|
      id = criterion['id'].to_s
      problems << "duplicate_criterion: #{id}" if seen[id]
      seen[id] = true
      owner = criterion['owner'].to_s
      if owner.empty?
        problems << "orphan_criterion: #{id} has no owner"
      elsif !dirs.include?(owner)
        problems << "orphan_criterion: #{id} owner #{owner} is not a plan of this epic"
      end
    end
  end

  def self.order_lines(order)
    return [ "cycle: #{order.cycle.join(', ')}" ] unless order.cycle.empty?

    order.layers.each_with_index.map { |layer, index| "Layer #{index + 1}: #{layer.join(', ')}" }
  end

  # Usage: epic_check.rb [--order] [--plans-root DIR] <slug|path>
  module CLI
    USAGE = 'usage: epic_check.rb [--order] [--plans-root DIR] <slug|path/to/epic.md>'

    def self.run(argv, out: $stdout, err: $stderr)
      flags = parse(argv.dup)
      path = flags && resolve(flags[:target])
      return usage(err, flags && flags[:target]) unless path

      epic = EpicStore.load(path, plans_root: flags[:plans_root] || PlanPaths.root)
      result = EpicCheck.run(epic)
      # An order from an epic with problems would silently drop the bad edges,
      # so --order prints the problems instead and fails like validation.
      lines = flags[:order] && result.ok? ? EpicCheck.order_lines(result.order) : result.problems
      lines.each { |line| out.puts(line) }
      out.puts('epic_check: clean') if !flags[:order] && result.ok?
      result.ok? ? 0 : 1
    end

    def self.usage(err, target)
      err.puts(target ? "epic_check: no epic at #{target}" : USAGE)
      2
    end

    def self.resolve(target)
      return nil if target.to_s.empty?
      return target if File.file?(target)
      return nil if target.include?('/') || target.end_with?('.md')

      path = EpicStore.path_for(target)
      File.file?(path) ? path : nil
    end

    def self.parse(args)
      flags = {}
      until args.empty?
        token = args.shift
        case token
        when '--order' then flags[:order] = true
        when '--plans-root' then flags[:plans_root] = args.shift or return nil
        when /\A--/ then return nil
        else
          return nil if flags[:target]

          flags[:target] = token
        end
      end
      flags
    end
  end
end

exit(EpicCheck::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
