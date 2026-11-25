# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../epic_store'
require_relative '../epic_graph'
require_relative '../epic_gh'
require_relative 'gh_live'
require_relative 'heartbeat'
require_relative 'snapshot'

module Triage
  # The deterministic roadmap report. Pure computation over injected sources;
  # `Sources` (sources.rb) reads them from disk. Units, percent and next step
  # follow contract C4:
  #
  # - Unit id: `<owner/repo>#<epic>/<node>` for an epic node, or
  #   `<owner/repo>#stack/<stack-id>` for a stack. A stack whose PRs carry the
  #   `Plan-Phase` of an epic node is counted once, as that node; PRs it holds
  #   that link to no node stay a stack unit.
  # - Evidence precedence for which PRs a node has: stack record, then
  #   `Plan-Phase` trailer. Live gh gives each PR's state. A stack that
  #   recorded a PR merged while gh says it is not is a conflict: the unit is
  #   `escalated`, never done and never eligible.
  # - Terminal states: done, escalated. Blockers for a `next` unit: an open
  #   inbox decision naming it, a carve-out or tag phase, another active unit in
  #   its repo. Eligible is `next` with no blocker.
  # - Percent is done units over all units of the epic (nodes) or the stack
  #   (its PRs, merged over all); an empty denominator is `n/a`.
  # - Order: repo order in the host map (unmapped repos last), then epic node
  #   order.
  class Report
    SCHEMA = 1
    CARVE_OUT = /carve-out|\btag\b|\brelease\b/i
    OPEN_ONLY = %w[OPEN].freeze

    def initialize(host_map:, epics:, stacks:, gh:, now:, epic_gh: nil, decisions: [], remote: {}, heartbeats: {},
                   previous: nil, host: nil, findings: [])
      @map = host_map
      @epics = epics
      @stacks = stacks
      @gh = gh
      @epic_gh = epic_gh
      @now = now
      @decisions = decisions
      @remote = remote
      @heartbeats = heartbeats
      @previous = previous
      @host = host
      @findings = findings.dup
      @linked = Hash.new { |hash, key| hash[key] = [] }
      @pr_cache = {}
    end

    def build
      remote_decisions = merge_remote_decisions
      @all_decisions = (@decisions + remote_decisions).uniq { |item| item['id'] }.sort_by { |item| item['id'].to_s }
      groups = epic_groups + stack_groups
      units = groups.flat_map { |group| group[:units] }
      finalize(units)
      ordered = units.sort_by { |unit| order_key(unit) }
      by_key = groups.to_h { |group| [ group[:key], group ] }
      result = {
        'schema' => SCHEMA, 'generated_at' => @now.utc.iso8601, 'host' => @host,
        'generation' => @previous ? @previous['generation'].to_i : 0,
        'units' => ordered.map { |unit| public_unit(unit, by_key.fetch(unit[:group])) },
        'groups' => groups.map { |group| group_row(group) }.sort_by { |row| group_key(row, ordered) },
        'eligible' => ordered.select { |unit| unit[:eligible] }.map { |unit| unit[:id] },
        'decisions' => @all_decisions, 'hosts' => hosts, 'findings' => sorted_findings, 'changed' => []
      }
      apply_changes(result)
    end

    # --- diff against the previous published tick -----------------------

    def self.diff(previous, current)
      return [] unless previous.is_a?(Hash) && previous['units'].is_a?(Array)

      before = previous['units'].to_h { |unit| [ unit['unit'], unit ] }
      after = current['units'].to_h { |unit| [ unit['unit'], unit ] }
      changes = (after.keys - before.keys).map { |id| change(id, 'unit', nil, 'added') }
      changes += (before.keys - after.keys).map { |id| change(id, 'unit', 'present', 'removed') }
      (after.keys & before.keys).each do |id|
        %w[state percent_label prs].each do |field|
          next if before[id][field] == after[id][field]

          changes << change(id, field, before[id][field], after[id][field])
        end
      end
      changes.sort_by { |row| [ row['unit'], row['field'] ] }
    end

    def self.change(unit, field, from, to) = { 'unit' => unit, 'field' => field, 'from' => from, 'to' => to }

    # --- rendering ---------------------------------------------------------

    def self.render_text(report)
      lines = [ "roadmap generation #{report['generation']} (#{report['generated_at']})" ]
      lines << hosts_line(report['hosts']) unless report['hosts'].empty?
      lines.concat(group_lines(report))
      lines << "decisions waiting: #{report['decisions'].size}"
      report['decisions'].each { |item| lines << "  #{item['id']}: #{item['subject']}" }
      report['findings'].each { |finding| lines << "finding #{finding['code']}: #{finding['detail']}" }
      lines << "changed since last publish: #{report['changed'].size}" unless report['changed'].empty?
      lines
    end

    def self.hosts_line(hosts)
      'hosts: ' + hosts.map { |row| "#{row['host']} #{row['status']}#{row['reason'] ? " (#{row['reason']})" : ''}" }.join(', ')
    end

    def self.group_lines(report)
      done = report['groups'].count { |group| group['total'].positive? && group['done'] == group['total'] }
      lines = report['groups'].reject { |group| group['total'].positive? && group['done'] == group['total'] }.flat_map do |group|
        head = "#{group['name']} #{group['done']}/#{group['total']} (#{group['percent_label']}) next: #{group['next_step']}"
        [ head ] + report['units'].select { |unit| unit['group'] == group['group'] }.map { |unit| unit_line(unit) }
      end
      lines << "finished: #{done}" if done.positive?
      lines
    end

    def self.unit_line(unit)
      pr = unit['prs'].map { |p| "##{p['number']} #{p['state']} ci=#{p['ci']} clean=#{p['clean']} threads=#{p['unresolved_threads']}" }
      "  #{unit['unit']} [#{unit['state']}] #{unit['next_step']}#{pr.empty? ? '' : "  (#{pr.join('; ')})"}"
    end

    private

    # --- epics ---------------------------------------------------------------

    def epic_groups
      @epics.map do |epic|
        slug = File.basename(File.dirname(epic.path))
        graph = EpicGraph.build(epic)
        order = graph.order
        plans = epic.plans.to_h { |plan| [ plan['id'].to_s, plan ] }
        done = {}
        built = (order.layers.flatten + order.cycle).to_h do |node|
          preds = graph.nodes.select { |other| graph.successors(other).include?(node) }
          unit = node_unit(epic, slug, node, plans, preds.reject { |pred| done[pred] })
          done[node] = unit[:state] == 'done'
          [ node, unit ]
        end
        units = graph.nodes.map { |node| built[node] }
        units.each_with_index { |unit, index| unit[:index] = index }
        { key: "epic/#{slug}", kind: 'epic', name: slug, units: units, total: units.size,
          done: units.count { |unit| unit[:state] == 'done' } }
      end
    end

    def node_unit(epic, slug, node, plans, open_deps)
      match = EpicGraph::NODE.match(node)
      plan = plans.fetch(match[:plan], {})
      repo = plan['repo'].to_s
      ref = "#{plan['dir']}#Phase #{match[:phase].to_i}"
      title = (EpicStore.phases_for(epic, plan) || []).find { |number, _| number == match[:phase].to_i }&.last.to_s
      evidence, failed = node_evidence(repo, ref)
      prs = evidence.map { |entry| live_pr(repo, entry) }
      unit = { id: "#{repo}##{slug}/#{node}", kind: 'epic', repo: repo, epic: slug, node: node, phase: title,
               group: "epic/#{slug}", prs: prs, deps: open_deps.map { |dep| "#{slug}/#{dep}" }, store: evidence }
      unit[:state] = classify(prs, evidence, failed, open_deps.empty?)
      unit
    end

    # PR numbers for a node: stack record first, trailer search only when no
    # stack names the node. Returns [entries, failed].
    def node_evidence(repo, ref)
      entries = []
      @stacks.each do |record|
        next unless record['repo'] == repo

        Array(record['prs']).each do |pr|
          next unless pr['phase'] == ref

          entries << { 'number' => pr['number'], 'store_state' => pr['state'] }
          @linked[[ repo, record['slug'] ]] << pr['number']
        end
      end
      entries = entries.uniq { |entry| entry['number'] }.sort_by { |entry| entry['number'] }
      return [ entries, false ] unless entries.empty? && @epic_gh

      trailer = @epic_gh.pr_search_trailer(repo, ref).uniq.sort.map { |number| { 'number' => number, 'store_state' => nil } }
      [ trailer, false ]
    rescue EpicGh::Error => e
      finding('gh_unavailable', "#{repo} #{ref}: #{e.message}")
      [ [], true ]
    end

    def classify(prs, evidence, failed, deps_done)
      return 'unknown' if failed
      return 'escalated' if conflict?(prs, evidence) || evidence.any? { |e| %w[paused escalated].include?(e['store_state']) }

      live = prs.reject { |pr| pr['state'] == 'CLOSED' }
      return 'unknown' if live.any? { |pr| pr['state'] == 'unknown' }
      return 'done' if !live.empty? && live.all? { |pr| pr['state'] == 'MERGED' }
      return 'active' if live.any? { |pr| OPEN_ONLY.include?(pr['state']) }

      deps_done ? 'next' : 'pending'
    end

    def conflict?(prs, evidence)
      evidence.any? do |entry|
        live = prs.find { |pr| pr['number'] == entry['number'] }
        entry['store_state'] == 'merged' && live && !%w[MERGED unknown].include?(live['state'])
      end
    end

    # --- stacks --------------------------------------------------------------

    def stack_groups
      @stacks.filter_map do |record|
        all = Array(record['prs'])
        linked = @linked[[ record['repo'].to_s, record['slug'] ]]
        rest = all.reject { |pr| linked.include?(pr['number']) }
        next if !all.empty? && rest.empty?

        stack_unit(record, rest)
      end
    end

    def stack_unit(record, prs)
      repo = record['repo'].to_s
      id = "#{repo}#stack/#{record['slug']}"
      finished = !prs.empty? && prs.all? { |pr| pr['state'] == 'merged' }
      live = prs.map { |pr| finished ? merged_pr(pr) : live_pr(repo, { 'number' => pr['number'], 'store_state' => pr['state'] }) }
      state = stack_state(prs, live, finished)
      merged = live.count { |pr| pr['state'] == 'MERGED' }
      unit = { id: id, kind: 'stack', repo: repo, epic: nil, node: record['slug'], phase: current_phase(prs), group: id,
               prs: live, deps: [], store: [], state: state, index: 0 }
      { key: id, kind: 'stack', name: id, units: [ unit ], total: live.size, done: merged, unit_done: state == 'done' }
    end

    def stack_state(prs, live, finished)
      return 'done' if finished || (!live.empty? && live.all? { |pr| pr['state'] == 'MERGED' })
      return 'unknown' if prs.empty?

      entries = prs.map { |pr| { 'number' => pr['number'], 'store_state' => pr['state'] } }
      escalated = conflict?(live, entries) || live.any? { |pr| pr['state'] == 'CLOSED' } ||
                  prs.any? { |pr| %w[paused escalated].include?(pr['state']) }
      escalated ? 'escalated' : 'active'
    end

    def current_phase(prs) = prs.find { |pr| pr['state'] != 'merged' }&.fetch('phase', nil).to_s

    # --- live PR facts -------------------------------------------------------

    def merged_pr(pr) = { 'number' => pr['number'], 'state' => 'MERGED', 'ci' => nil, 'clean' => nil, 'unresolved_threads' => nil }

    def live_pr(repo, entry)
      key = [ repo, entry['number'] ]
      @pr_cache[key] ||= begin
        facts = @gh.pr(repo, entry['number'])
        open = facts.state == 'OPEN'
        { 'number' => entry['number'], 'state' => facts.state, 'ci' => open ? facts.ci : nil,
          'clean' => open ? facts.clean : nil, 'unresolved_threads' => open ? facts.unresolved_threads : nil }
      rescue GhLive::Unavailable => e
        finding('gh_unavailable', "#{repo}##{entry['number']}: #{e.message}")
        { 'number' => entry['number'], 'state' => 'unknown', 'ci' => 'unknown', 'clean' => 'unknown',
          'unresolved_threads' => 'unknown' }
      end
    end

    # --- eligibility, percent, next step -------------------------------------

    def finalize(units)
      busy = units.select { |unit| unit[:state] == 'active' }
      units.each do |unit|
        unit[:blockers] = blockers(unit, busy)
        unit[:eligible] = unit[:state] == 'next' && unit[:blockers].empty?
        unit[:next_step] = next_step(unit)
      end
    end

    def blockers(unit, busy)
      case unit[:state]
      when 'pending' then unit[:deps].map { |dep| "unmet_dependency:#{dep}" }
      when 'next' then next_blockers(unit, busy)
      else []
      end
    end

    def next_blockers(unit, busy)
      list = []
      list << 'open_decision' if open_decision?(unit)
      list << 'carve_out_or_tag' if unit[:phase].to_s.match?(CARVE_OUT)
      busy.select { |other| other[:repo] == unit[:repo] && other[:id] != unit[:id] }.each { |other| list << "repo_busy:#{other[:id]}" }
      list
    end

    def open_decision?(unit) = @all_decisions.any? { |item| item['refs'].to_s.include?(unit[:id]) }

    def next_step(unit)
      case unit[:state]
      when 'done' then 'done'
      when 'escalated' then "escalated: #{escalation_reason(unit)}"
      when 'unknown' then unit[:kind] == 'stack' && unit[:prs].empty? ? 'stack records no PRs yet' : 'unknown: evidence unavailable, recheck when gh is reachable'
      when 'pending' then "waiting on #{unit[:deps].join(', ')}"
      when 'next' then unit[:eligible] ? "start #{unit[:phase].to_s.empty? ? unit[:node] : "#{unit[:node]} #{unit[:phase]}"}" : "blocked: #{unit[:blockers].join(', ')}"
      else active_step(unit)
      end
    end

    def escalation_reason(unit)
      closed = unit[:prs].find { |pr| pr['state'] == 'CLOSED' }
      return "##{closed['number']} closed unmerged" if closed && unit[:kind] == 'stack'

      conflict = unit[:store].find { |e| e['store_state'] == 'merged' }
      return "state conflict (stack says merged, gh disagrees on ##{conflict['number']})" if conflict && conflict?(unit[:prs], unit[:store])

      'paused or escalated in the stack record'
    end

    def active_step(unit)
      pr = unit[:prs].find { |p| p['state'] == 'OPEN' } || unit[:prs].find { |p| p['state'] != 'MERGED' }
      return 'recheck when gh is reachable' unless pr

      n = "##{pr['number']}"
      return "recheck #{n} when gh is reachable" if pr['state'] == 'unknown'
      return "fix failing checks on #{n}" if pr['ci'] == 'failed'

      threads = pr['unresolved_threads']
      return "resolve #{threads} review thread#{threads == 1 ? '' : 's'} on #{n}" if threads.is_a?(Integer) && threads.positive?
      return "wait for checks on #{n}" if pr['ci'] == 'pending'
      return "merge #{n} at the ready bar" if pr['clean'] == true && %w[passed none].include?(pr['ci'])

      "bring #{n} to CLEAN (rebase or fix conflicts)"
    end

    # --- output shaping ------------------------------------------------------

    def percent(done, total) = total.zero? ? nil : (done * 100 / total)

    def group_row(group)
      pct = percent(group[:done], group[:total])
      sorted = group[:units].sort_by { |unit| order_key(unit) }
      first = sorted.find { |unit| unit[:state] == 'active' } || sorted.find { |unit| unit[:eligible] } ||
              sorted.find { |unit| unit[:state] != 'done' }
      { 'group' => group[:key], 'kind' => group[:kind], 'name' => group[:name], 'total' => group[:total],
        'done' => group[:done], 'percent' => pct, 'percent_label' => pct ? "#{pct}%" : 'n/a',
        'next_step' => first ? first[:next_step] : (group[:total].zero? ? 'no units' : 'done') }
    end

    def public_unit(unit, group)
      pct = percent(group[:done], group[:total])
      mine = @all_decisions.select { |item| item['refs'].to_s.include?(unit[:id]) }
      { 'unit' => unit[:id], 'repo' => unit[:repo], 'epic' => unit[:epic], 'node' => unit[:node], 'phase' => unit[:phase],
        'group' => unit[:group], 'kind' => unit[:kind], 'state' => unit[:state], 'prs' => unit[:prs],
        'percent' => pct, 'percent_label' => pct ? "#{pct}%" : 'n/a', 'next_step' => unit[:next_step],
        'blockers' => unit[:blockers], 'eligible' => unit[:eligible], 'changed' => [], 'decisions' => mine }
    end

    def order_key(unit)
      [ @map.rank(unit[:repo]), unit[:repo], unit[:kind] == 'epic' ? 0 : 1, unit[:group], unit[:index].to_i ]
    end

    def group_key(row, ordered)
      first = ordered.index { |unit| unit['group'] == row['group'] }
      [ first || ordered.size, row['group'] ]
    end

    def apply_changes(result)
      changes = self.class.diff(@previous, result)
      result['changed'] = changes
      result['units'].each { |unit| unit['changed'] = changes.select { |row| row['unit'] == unit['unit'] } }
      result
    end

    # --- hosts, decisions, findings ------------------------------------------

    def hosts
      names = (@map.hosts + [ @host ]).compact.uniq.sort
      names.map { |name| host_row(name) }
    end

    def host_row(name)
      return remote_row(name, @remote[name]) if name != @host && @remote[name]

      entry = @heartbeats[name]
      status = Heartbeat.status(entry, @now)
      finding('host_stale', "#{name} heartbeat is #{Heartbeat.age(entry, @now)}s old") if status == 'stale'
      { 'host' => name, 'self' => name == @host, 'status' => status, 'heartbeat_age' => Heartbeat.age(entry, @now),
        'generation' => entry && entry['generation'], 'reason' => nil }
    end

    def remote_row(name, pulled)
      if pulled.status != 'ok'
        finding('host_stale', "#{name} snapshot #{pulled.status}: #{pulled.reason}")
        return { 'host' => name, 'self' => false, 'status' => 'stale', 'heartbeat_age' => nil, 'generation' => nil,
                 'reason' => "#{pulled.status}: #{pulled.reason}" }
      end

      snap = pulled.snapshot
      status = Snapshot.freshness(snap, @now)
      finding('host_stale', "#{name} snapshot is older than two ticks") if status == 'stale'
      check_assignments(name, snap)
      { 'host' => name, 'self' => false, 'status' => status,
        'heartbeat_age' => (@now - Time.iso8601(snap['heartbeat_at'] || snap['generated_at'])).to_i,
        'generation' => snap['generation'], 'reason' => status == 'stale' ? 'older than 2 ticks' : nil }
    end

    # A snapshot whose repo assignment disagrees with this host's map means the
    # two hosts are not on the same assignment version: report it (the acting
    # phase refuses and escalates on it).
    def check_assignments(name, snap)
      snap['repos'].each do |row|
        local = @map.entry_for(row['repo'])
        next if local && local.host == name && local.version == row['assignment_version']

        finding('assignment_mismatch', "#{row['repo']}: #{name} snapshot has version #{row['assignment_version']}, " \
                                       "map has #{local ? "#{local.host} v#{local.version}" : 'no entry'}")
      end
    end

    def merge_remote_decisions
      @remote.flat_map do |name, pulled|
        next [] unless pulled.status == 'ok'

        pulled.snapshot['decisions'].map { |item| item.merge('host' => item['host'] || name) }
      end
    end

    def finding(code, detail)
      @findings << { 'code' => code, 'detail' => detail } unless @findings.any? { |f| f['code'] == code && f['detail'] == detail }
    end

    def sorted_findings = @findings.sort_by { |f| [ f['code'], f['detail'] ] }
  end
end
