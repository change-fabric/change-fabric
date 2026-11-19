# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

# The open-P1 follow-up contract shared by roast.rb decide, the fidelity loop,
# and every caller that records an outcome. A stop at the target leaves P1s
# behind; they become follow-ups in the top-level `followups` array of
# roast/round-N.response.json, next to Claude's `responses`, and are mitigated
# locally, never by another paid round. Writers touch only their own key.
module RoastFollowups
  OUTCOMES = %w[pending mitigated unresolved escalated declined_by_human].freeze
  VERDICTS = [ nil, 'resolved', 'unresolved' ].freeze
  MAX_ATTEMPTS = 2
  # Fields the local pass owns; a decide rerun must not reset them.
  STATE_KEYS = %w[outcome judge_verdict attempts escalation_reason note].freeze
  # Outcomes a --final gate refuses on: the pass has not run or did not settle it.
  UNSETTLED = %w[pending unresolved].freeze

  class InvalidEntry < StandardError; end

  module_function

  # r<round>-i<index>-<hash>: index is the issue's 0-based position in the
  # round's issues, hash the first 8 hex of SHA-256 over where, a newline, problem.
  def id_for(round, index, issue)
    "r#{round}-i#{index}-#{Digest::SHA256.hexdigest("#{issue['where']}\n#{issue['problem']}")[0, 8]}"
  end

  def entry_for(round, index, issue)
    { 'id' => id_for(round, index, issue), 'priority' => 'P1', 'where' => issue['where'], 'problem' => issue['problem'],
      'fix' => issue['fix'], **blank }
  end

  # One pending entry per P1 issue of a round's critic json.
  def from_critic(round, critic)
    Array(critic['issues']).each_with_index.filter_map do |issue, i|
      entry_for(round, i, issue) if issue['priority'] == 'P1'
    end
  end

  def validate!(entry)
    raise InvalidEntry, 'followup needs an id' if entry['id'].to_s.empty?
    raise InvalidEntry, "invalid outcome #{entry['outcome'].inspect} (one of #{OUTCOMES.join(', ')})" unless OUTCOMES.include?(entry['outcome'])
    raise InvalidEntry, "invalid judge_verdict #{entry['judge_verdict'].inspect}" unless VERDICTS.include?(entry['judge_verdict'])
    raise InvalidEntry, "attempts must be an integer 0 to #{MAX_ATTEMPTS}" unless entry['attempts'].is_a?(Integer) && (0..MAX_ATTEMPTS).cover?(entry['attempts'])

    entry
  end

  def read(path)
    empty = { 'responses' => [], 'followups' => [] }
    return empty unless File.file?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? data : empty
  end

  def followups(path) = Array(read(path)['followups'])

  # Keys by id. A new id is appended; an existing id is updated field by field
  # and never duplicated. An incoming pending entry never resets one the pass
  # has moved on. Only the `followups` key is written. Returns the stored list.
  def upsert(path, entries)
    data = read(path)
    list = Array(data['followups'])
    entries.map { |e| e.transform_keys(&:to_s) }.each do |entry|
      existing = list.find { |e| e['id'] == entry['id'] }
      merged = existing ? merge(existing, entry) : { **blank, **entry }
      validate!(merged)
      existing ? existing.replace(merged) : list << merged
    end
    data['responses'] ||= []
    data['followups'] = list
    write(path, data)
    list
  end

  def blank = { 'outcome' => 'pending', 'judge_verdict' => nil, 'attempts' => 0, 'escalation_reason' => nil, 'note' => '' }

  def merge(existing, entry)
    entry = entry.reject { |k, _| STATE_KEYS.include?(k) } if entry['outcome'] == 'pending' && existing['outcome'] != 'pending'
    existing.merge(entry)
  end

  def write(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.tmp"
    File.write(tmp, "#{JSON.pretty_generate(data)}\n")
    File.rename(tmp, path)
  end

  # The id-and-problem line decide prints for each follow-up.
  def line(entry) = "- #{entry['id']} (#{entry['where']}): #{entry['problem']}"
end
