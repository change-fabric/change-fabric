#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'hook_event'

# Validates and logs the stage 2 reviewer's findings. The reviewer returns a
# JSON array; an empty array ("no findings") is valid. A finding must cite a
# file and a line, name one of the judgment kinds, and say what it found. An
# add_abstraction finding is only accepted with a second_caller that exists
# now (file:line): extraction needs a second user today, not a guessed one.
# Accepted and rejected rows are both appended to review_findings.jsonl so the
# weekly review can see how often each judgment item fires.
module ReviewFindings
  KINDS = %w[scope_creep refactoring_smell add_abstraction react_effect terraform_moved_block rails_n_plus_1 rubric].freeze
  CITE = /\A[^\s:]+:\d+\z/
  FILE_NAME = 'review_findings.jsonl'

  module_function

  def path(home: Dir.home)
    override = ENV.fetch('CF_REVIEW_FINDINGS_PATH', '')
    return override unless override.empty? || home != Dir.home

    File.join(HookEvent.state_dir(home), FILE_NAME)
  end

  # [accepted, rejected] where rejected rows are { finding:, reason: }.
  def validate(raw)
    return [ [], [ { finding: raw, reason: 'findings must be a JSON array' } ] ] unless raw.is_a?(Array)

    accepted = []
    rejected = []
    raw.each do |finding|
      reason = problem(finding)
      reason ? rejected << { finding: finding, reason: reason } : accepted << finding
    end
    [ accepted, rejected ]
  end

  def problem(finding)
    return 'finding is not an object' unless finding.is_a?(Hash)
    return "kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(finding['kind'])
    return 'file is required' if finding['file'].to_s.strip.empty?
    return 'line must be a positive integer' unless finding['line'].is_a?(Integer) && finding['line'].positive?
    return 'summary is required' if finding['summary'].to_s.strip.empty?
    return unless finding['kind'] == 'add_abstraction'

    'add_abstraction needs a second_caller (file:line) that exists now' unless finding['second_caller'].to_s.match?(CITE)
  end

  # Appends every row (accepted and rejected) and returns [accepted, rejected].
  def record(raw, session:, home: Dir.home)
    accepted, rejected = validate(raw)
    rows = accepted.map { |finding| entry(finding, session, true, nil) } +
           rejected.map { |row| entry(row[:finding], session, false, row[:reason]) }
    append(rows, home)
    [ accepted, rejected ]
  end

  def entry(finding, session, accepted, reason)
    base = finding.is_a?(Hash) ? finding.slice('kind', 'file', 'line', 'summary', 'second_caller') : {}
    { 'ts' => Time.now.utc.iso8601, 'session' => session.to_s, 'accepted' => accepted }.merge(base).merge(reason ? { 'reason' => reason } : {})
  end

  def append(rows, home)
    return if rows.empty?

    target = path(home: home)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, rows.map { |row| "#{JSON.generate(row)}\n" }.join, mode: 'a')
  rescue SystemCallError
    nil
  end
end

if __FILE__ == $PROGRAM_NAME
  session = ARGV.fetch(0, '')
  raw = begin
    JSON.parse($stdin.read)
  rescue JSON::ParserError
    nil
  end
  accepted, rejected = ReviewFindings.record(raw, session: session)
  puts "[cf review] #{accepted.size} finding(s) accepted, #{rejected.size} rejected."
  rejected.each { |row| puts "  rejected: #{row[:reason]}" }
  accepted.each { |finding| puts "  #{finding['file']}:#{finding['line']} #{finding['kind']} #{finding['summary']}" }
end
