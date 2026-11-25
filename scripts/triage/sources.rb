# frozen_string_literal: true

require 'json'
require_relative '../plan_paths'
require_relative '../epic_store'
require_relative '../epic_gh'
require_relative '../stack_store'
require_relative '../inbox_store'
require_relative 'paths'
require_relative 'host_map'
require_relative 'heartbeat'
require_relative 'snapshot'
require_relative 'gh_live'
require_relative 'report'

module Triage
  # Reads every report input from disk and the network, read-only. The pure
  # computation lives in Report; this is the only place report touches state.
  module Sources
    # Keyword arguments for Report.new, plus injectable seams for tests.
    def self.collect(root:, now:, host: Paths.host, plans_root: PlanPaths.root, stack_root: StackStore.root,
                     gh: GhLive.new, epic_gh: EpicGh::Cli.new, decisions: nil, pull: Snapshot.method(:pull))
      findings = []
      map = HostMap.load(Paths.hosts_file(root))
      findings << { 'code' => 'host_map_invalid', 'detail' => map.error } unless map.valid?
      epics = epics(plans_root, findings)
      {
        host_map: map, epics: epics, stacks: stacks(stack_root), gh: gh, epic_gh: epic_gh, now: now, host: host,
        decisions: decisions || inbox_decisions, remote: remote(map, host, pull), findings: findings,
        heartbeats: Heartbeat.read_all(Paths.heartbeat_dir(root)), previous: previous(Paths.report_file(root))
      }
    end

    # Epic files under <plans root>/epics/<slug>/epic.md. A missing store is a
    # stack-only report; an epic that does not parse is a finding.
    def self.epics(plans_root, findings)
      Dir.glob(File.join(plans_root, 'epics', '*', 'epic.md')).sort.filter_map do |path|
        epic = EpicStore.load(path, plans_root: plans_root)
        next epic if epic.problems.empty?

        findings << { 'code' => 'epic_invalid', 'detail' => "#{File.basename(File.dirname(path))}: #{epic.problems.first}" }
        nil
      end
    end

    # Every readable stack record under every repo directory; a corrupt file
    # reads as absent, matching StackStore.
    def self.stacks(stack_root)
      Dir.glob(File.join(stack_root, '*', '*.json')).sort.filter_map do |file|
        record = JSON.parse(File.read(file))
        record if record.is_a?(Hash) && record['prs'].is_a?(Array) && record['slug'] && record['repo']
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end

    # Pending items addressed to a human in the cf:inbox store. Approval
    # requests live on the phone console and have no local pending record, so
    # they are not listed here.
    def self.inbox_decisions
      InboxStore.humans.flat_map { |role| InboxStore.pending(role) }.map do |item|
        { 'id' => "inbox:#{File.basename(item['path'], '.md')}", 'kind' => 'inbox', 'subject' => item['subject'].to_s,
          'refs' => item['refs'].to_s, 'host' => nil }
      end.sort_by { |item| item['id'] }
    rescue StandardError
      []
    end

    # The other mapped host's snapshot, pulled read-only. Only a host that
    # knows its own name aggregates; an unset host never reaches over SSH.
    def self.remote(map, host, pull)
      return {} unless host

      (map.hosts - [ host ]).to_h { |other| [ other, pull.call(map.ssh_target(other)) ] }
    end

    def self.previous(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) && data['units'].is_a?(Array) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end
end
