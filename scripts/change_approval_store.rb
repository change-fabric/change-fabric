#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

# Human approvals of host-run step definitions (boot.up, boot.down, command
# lane entries) that differ from the base branch, keyed by the exact commit
# they were approved for. An approval names a step and the digest of the
# definition a human read, so it covers that definition at that commit only:
# a new commit, or an edited step at the same commit, needs a new approval.
#
# Written only by change_approve.rb, which refuses without a real terminal.
# Read by ChangeTrust at run time and by ChangeGateCheck at merge or tag time.
class ChangeApprovalStore
  def initialize(sha, root: File.join(Dir.home, '.claude', 'cf', 'change', 'approvals'))
    @sha = sha.to_s
    @root = root
  end

  # [[step, digest], ...] approved for this sha.
  def approvals
    record = read
    return [] unless record

    Array(record['approved']).filter_map do |entry|
      next unless entry.is_a?(Hash)

      [ entry['step'].to_s, entry['digest'].to_s ]
    end
  end

  def approved?(step, digest) = approvals.include?([ step.to_s, digest.to_s ])

  # `steps` is [[step, digest], ...]. Merges into what is already on record for
  # this sha, so approving a second profile's steps keeps the first.
  def record(steps:, by:)
    return if @sha.empty?

    now = Time.now.utc.iso8601
    existing = Array(read&.fetch('approved', nil))
    known = existing.map { |entry| [ entry['step'], entry['digest'] ] }
    added = steps.reject { |pair| known.include?(pair) }.map do |step, digest|
      { 'step' => step, 'digest' => digest, 'at' => now, 'by' => by.to_s }
    end
    write('sha' => @sha, 'approved' => existing + added)
  end

  def path = File.join(@root, "#{@sha}.json")

  private

  def read
    return nil if @sha.empty? || !File.exist?(path)

    record = JSON.parse(File.read(path))
    record.is_a?(Hash) && record['sha'] == @sha ? record : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def write(payload)
    FileUtils.mkdir_p(@root)
    tmp = "#{path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.pretty_generate(payload))
    File.rename(tmp, path)
  end
end
