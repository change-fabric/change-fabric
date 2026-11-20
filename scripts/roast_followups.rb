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

  # One pending entry per P1 issue of a round's critic json, except the issues
  # in `skip` (compared by identity), such as ones the response rebutted.
  def from_critic(round, critic, skip: [])
    Array(critic['issues']).each_with_index.filter_map do |issue, i|
      entry_for(round, i, issue) if issue['priority'] == 'P1' && skip.none? { |s| s.equal?(issue) }
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

  # The local P1 pass as code. Callers inject four roles: classify (a classifier
  # agent), ask (AskUserQuestion), mitigate (a worker agent or this session) and
  # judge (a local critic, never the paid roast). Pass never calls roast.rb.
  #
  #   classify: ->(entry) { { needs_human: bool, reason: str } }
  #   ask:      ->(entry, reason) { { approved: bool, direction: str } }
  #   mitigate: ->(entry, direction) { note_str } (or { note:, decision: str } when
  #             the fix raised a new human decision, which is classified again)
  #   judge:    ->(entry) { :resolved | :unresolved }
  class Pass
    def initialize(classify:, ask:, mitigate:, judge:, away: false)
      @classify = classify
      @ask = ask
      @mitigate = mitigate
      @judge = judge
      @away = away
    end

    # Runs every pending follow-up in the response file and persists each
    # outcome through RoastFollowups.upsert. Returns the entries it settled.
    def run(path)
      RoastFollowups.followups(path).select { |e| e['outcome'] == 'pending' }.map do |entry|
        settled = settle(entry.dup)
        RoastFollowups.upsert(path, [ settled ])
        settled
      end
    end

    private

    # Classify first, then mitigate and judge with one retry.
    def settle(entry)
      direction = gate(entry)
      return entry if direction == :stop

      decisions = 0
      until entry['attempts'] >= MAX_ATTEMPTS
        entry['attempts'] += 1
        result = @mitigate.call(entry, direction)
        decision = result.is_a?(Hash) ? (result[:decision] || result['decision']) : nil
        entry['note'] = (result.is_a?(Hash) ? (result[:note] || result['note']) : result).to_s
        if decision
          # A raised decision is not a judged fix: refund the attempt, bounded
          # so a worker that keeps asking cannot loop forever.
          entry['attempts'] -= 1
          return finish(entry, 'unresolved') if (decisions += 1) > MAX_ATTEMPTS

          direction = gate(entry, decision)
          return entry if direction == :stop

          next
        end
        entry['judge_verdict'] = @judge.call(entry).to_s
        return finish(entry, 'mitigated') if entry['judge_verdict'] == 'resolved'
      end
      finish(entry, 'unresolved')
    end

    # Returns the human direction (nil when none needed) or :stop after setting
    # a terminal outcome (escalated or declined_by_human).
    def gate(entry, decision = nil)
      subject = decision ? entry.merge('problem' => decision) : entry
      verdict = @classify.call(subject)
      return nil unless verdict[:needs_human]

      reason = verdict[:reason].to_s
      if @away
        entry['escalation_reason'] = reason
        finish(entry, 'escalated')
        return :stop
      end
      answer = @ask.call(subject, reason)
      return answer[:direction].to_s if answer[:approved]

      finish(entry, 'declined_by_human')
      :stop
    end

    def finish(entry, outcome)
      entry['outcome'] = outcome
      entry
    end
  end
end
