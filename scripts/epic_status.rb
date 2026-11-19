#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'epic_store'
require_relative 'epic_graph'
require_relative 'epic_gh'
require_relative 'stack_store'

# Read-only consolidated progress across every plan an epic points at.
# Every answer is derived from evidence: cf:sweep stack_store records first
# (the `phase` field, E3), then a `Plan-Phase:` trailer search (the fallback
# for PRs opened outside stack mode), then the PR's real gh state. No field
# here is ever set from a model's judgment.
#
# PR policy for v1 (one authoritative PR per node): identical references
# (the same repo and number, from stack and/or trailer) are deduplicated.
# Distinct PR numbers linked to one node are ambiguous and the node reads
# `unknown`; an ambiguous node never counts as done and never unlocks a
# downstream node.
module EpicStatus
  STATES = %w[done blocked in_progress pending next unknown].freeze

  Node = Data.define(:id, :repo, :state, :pr)

  # github.com/<owner>/<repo>, matching ContributorsTeam#repo_id's normal
  # form for a GitHub remote. v1 is GitHub only (E9); a non-GitHub host is a
  # later epic's problem, not this one's.
  def self.repo_id(repo) = "github.com/#{repo}"

  # PR numbers linked to `ref` through stack_store records for `repo`,
  # deduplicated. Scans every stack record under the repo's stack directory
  # (not just one slug), because an epic's PR may have been opened by any
  # cf:sweep stack, not necessarily one named after the epic.
  def self.stack_prs_for(repo, ref)
    base = File.join(StackStore.root, StackStore.repo_dir(repo_id(repo)))
    Dir.glob(File.join(base, '*.json')).sort.flat_map do |file|
      record = JSON.parse(File.read(file))
      Array(record['prs']).select { |pr| pr['phase'] == ref }.map { |pr| pr['number'] }
    rescue JSON::ParserError
      []
    end.compact.uniq.sort
  end

  # Resolves one node's PR number(s) for `repo`, combining stack records and
  # a trailer search. Returns `{ numbers:, error: }`; `error` is set only
  # when the trailer search itself failed (gh unavailable), never when it
  # simply found nothing.
  def self.resolve_pr(gh, repo, ref)
    numbers = stack_prs_for(repo, ref)
    begin
      numbers = (numbers + gh.pr_search_trailer(repo, ref)).uniq.sort
      { numbers:, error: nil }
    rescue EpicGh::Error => e
      { numbers:, error: e.message }
    end
  end

  # One node's state and the evidence behind it. `done_upstream` is whether
  # every direct predecessor already classified `done`; callers process
  # nodes in topological order so that is always known by the time a node
  # is reached.
  # `node` is the epic-level id (`<plan_id>#Phase N`), used only as the
  # display key. `ref` is the `<area>/<slug>#Phase N` form that stack
  # records and PR trailers actually carry (E3, Phase 2): the plan's own
  # directory, not its epic-local id, because a PR was opened against that
  # plan with no knowledge of the epic or the epic's plan ids.
  def self.classify(gh, repo, ref, done_upstream:, node: ref)
    resolved = resolve_pr(gh, repo, ref)
    return Node.new(id: node, repo:, state: 'unknown', pr: nil) if resolved[:error]
    return Node.new(id: node, repo:, state: 'unknown', pr: nil) if resolved[:numbers].size > 1

    number = resolved[:numbers].first
    return Node.new(id: node, repo:, state: done_upstream ? 'next' : 'pending', pr: nil) unless number

    begin
      view = gh.pr_view(repo, number)
    rescue EpicGh::Error
      return Node.new(id: node, repo:, state: 'unknown', pr: nil)
    end

    pr = { 'number' => number, 'url' => view['url'], 'state' => view['state'] }
    return Node.new(id: node, repo:, state: 'done', pr:) if view['state'] == 'MERGED'

    stack_record_state = stack_state_for(repo, ref)
    return Node.new(id: node, repo:, state: 'blocked', pr:) if %w[paused escalated].include?(stack_record_state)

    if view['state'] == 'OPEN'
      Node.new(id: node, repo:, state: done_upstream ? 'in_progress' : 'blocked', pr:)
    else
      # CLOSED and not merged: a closed unmerged PR counts as no PR (E3).
      Node.new(id: node, repo:, state: done_upstream ? 'next' : 'pending', pr: nil)
    end
  end

  # The stack record's own `state` field for the PR linked to `ref`, or nil
  # when no stack record names it (a trailer-only link has no stack state).
  def self.stack_state_for(repo, ref)
    base = File.join(StackStore.root, StackStore.repo_dir(repo_id(repo)))
    Dir.glob(File.join(base, '*.json')).each do |file|
      record = JSON.parse(File.read(file))
      pr = Array(record['prs']).find { |entry| entry['phase'] == ref }
      return pr['state'] if pr
    rescue JSON::ParserError
      next
    end
    nil
  end

  # Walks the epic's graph in topological-layer order (predecessors before
  # successors) and classifies every node. Nodes left over from a cycle
  # (epic_check reports the cycle separately) are classified last, with
  # every predecessor treated as not done, since their order is undefined.
  def self.run(epic, gh)
    graph = EpicGraph.build(epic)
    order = graph.order
    plans = epic.plans.to_h { |plan| [ plan['id'].to_s, plan ] }
    classified = {}
    (order.layers.flatten + order.cycle).each do |node|
      predecessors = graph.nodes.select { |other| graph.successors(other).include?(node) }
      states = predecessors.map { |p| classified[p]&.state }
      done_upstream = states.all? { |s| s == 'done' }
      match = EpicGraph::NODE.match(node)
      plan = plans.fetch(match && match[:plan], {})
      repo = plan['repo'].to_s
      ref = plan['dir'].to_s.empty? ? node : "#{plan['dir']}#Phase #{match[:phase]}"
      classified[node] = classify(gh, repo, ref, done_upstream:, node:)
    end
    graph.nodes.map { |node| classified[node] }
  end

  def self.counts(nodes)
    STATES.to_h { |state| [ state, nodes.count { |node| node.state == state } ] }
  end

  def self.to_json_report(nodes)
    {
      'counts' => counts(nodes),
      'nodes' => nodes.map { |n| { 'id' => n.id, 'repo' => n.repo, 'state' => n.state, 'pr' => n.pr } }
    }
  end

  def self.report_lines(nodes)
    lines = []
    counts = counts(nodes)
    lines << counts.map { |state, count| "#{state.tr('_', ' ')} #{count}" }.join(', ')
    STATES.each do |state|
      group = nodes.select { |node| node.state == state }
      next if group.empty?

      lines << ''
      lines << "#{state}:"
      group.each do |node|
        url = node.pr ? " #{node.pr['url']}" : ''
        lines << "  #{node.id}#{url}"
      end
    end
    lines
  end

  # Usage: epic_status.rb [--json] [--fake-gh DIR] [--plans-root DIR] <slug|path>
  module CLI
    USAGE = 'usage: epic_status.rb [--json] [--fake-gh DIR] [--plans-root DIR] <slug|path/to/epic.md>'

    def self.run(argv, out: $stdout, err: $stderr)
      flags = parse(argv.dup)
      path = flags && resolve_target(flags[:target], flags[:plans_root])
      return usage(err, flags && flags[:target]) unless path

      epic = EpicStore.load(path, plans_root: flags[:plans_root] || PlanPaths.root)
      gh = flags[:fake_gh] ? EpicGh::Fake.new(flags[:fake_gh]) : EpicGh::Cli.new
      nodes = EpicStatus.run(epic, gh)
      if flags[:json]
        out.puts(JSON.generate(EpicStatus.to_json_report(nodes)))
      else
        EpicStatus.report_lines(nodes).each { |line| out.puts(line) }
      end
      0
    end

    def self.usage(err, target)
      err.puts(target ? "epic_status: no epic at #{target}" : USAGE)
      2
    end

    # Shares epic_check's target resolution (slug vs explicit path) without
    # requiring that file solely for one helper; duplicated here as the
    # three-line body it is, to keep epic_gh the only new cross-script
    # dependency this phase adds.
    def self.resolve_target(target, plans_root = nil)
      return nil if target.to_s.empty?
      return target if File.file?(target)
      return nil if target.include?('/') || target.end_with?('.md')

      candidates = [ plans_root && EpicStore.path_for(target, root: plans_root), EpicStore.path_for(target) ]
      candidates.compact.find { |path| File.file?(path) }
    end

    def self.parse(args)
      flags = {}
      until args.empty?
        token = args.shift
        case token
        when '--json' then flags[:json] = true
        when '--fake-gh' then flags[:fake_gh] = args.shift or return nil
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

exit(EpicStatus::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
