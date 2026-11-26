# frozen_string_literal: true

module Triage
  # Where triage keeps its state, and which host this process is. The host
  # name comes only from CF_TRIAGE_HOST (set by the scheduler unit), never from
  # hostname guessing; an unset or unknown value means report-only.
  module Paths
    HOSTS = %w[mini vm].freeze

    def self.root = ENV.fetch('CF_TRIAGE_ROOT') { File.join(Dir.home, '.claude', 'cf', 'triage') }

    def self.host
      name = ENV['CF_TRIAGE_HOST'].to_s
      HOSTS.include?(name) ? name : nil
    end

    def self.hosts_file(root = self.root) = File.join(root, 'hosts.yml')
    def self.report_file(root = self.root) = File.join(root, 'report.json')
    def self.prev_report_file(root = self.root) = File.join(root, 'report.prev.json')
    def self.snapshot_file(root = self.root) = File.join(root, 'snapshot.json')
    def self.heartbeat_dir(root = self.root) = File.join(root, 'heartbeat')
    def self.lock_file(root = self.root) = File.join(root, 'publish.lock')
    def self.tick_lock_file(root = self.root) = File.join(root, 'tick.lock')
    def self.journal_file(root = self.root) = File.join(root, 'journal.jsonl')
    def self.limits_file(root = self.root) = File.join(root, 'limits.json')
    def self.units_dir(root = self.root) = File.join(root, 'units')
    def self.disabled_dir(root = self.root) = File.join(root, 'disabled')
    def self.runs_dir(root = self.root) = File.join(root, 'runs')
  end
end
