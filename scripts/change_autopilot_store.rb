#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'
require_relative 'change_receipt_store'

# Phone-approved autopilot receipts, keyed by repo and the SHA-256 of the
# signed body (the autopilot id), under ~/.claude/cf/change/autopilot/.
# ApprovalConsole::Recorder is the only writer of a receipt; change_autopilot.rb
# reads every record with `all` and re-verifies each proof, so a file placed
# here by anything else never counts. Beside each receipt live the tombstone
# (<id>.ended, written by `autopilot end`) and the ledger of waivers taken
# (<id>.jsonl). A tombstone only narrows: nothing here extends an autopilot.
class ChangeAutopilotStore < ChangeReceiptStore
  DIR = 'autopilot'
  ID = /\A[0-9a-f]{64}\z/

  def record(repo:, autopilot_id:, proof:, policy_sha:, recorded_by:)
    write({ repo: repo, autopilot_id: autopilot_id }, proof: proof, policy_sha: policy_sha, recorded_by: recorded_by)
  end

  def lookup(repo:, autopilot_id:) = read(repo: repo, autopilot_id: autopilot_id)

  # Every parseable receipt on disk, valid or not; the reader verifies them.
  def all
    Dir.glob(File.join(@root, '*.json')).filter_map do |file|
      record = JSON.parse(File.read(file))
      record if record.is_a?(Hash)
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end

  # Ends the autopilot at once. Raises on a bad id or a failed write, so the
  # caller can exit nonzero.
  def end!(autopilot_id:, by:, reason:, at: Time.now)
    FileUtils.mkdir_p(@root)
    File.write(file_for(autopilot_id, 'ended'), JSON.generate('ended_at' => at.utc.iso8601, 'by' => by.to_s, 'reason' => reason.to_s))
  end

  # An ended autopilot whose end the prod runner has not been told about yet.
  # Written before the tombstone and cleared only once the runner confirms, so
  # a failed publish is retried by the next `end`.
  def mark_pending(autopilot_id, repo:, by:, reason:)
    FileUtils.mkdir_p(@root)
    File.write(file_for(autopilot_id, 'pending'), JSON.generate('repo' => repo, 'by' => by.to_s, 'reason' => reason.to_s))
  end

  def clear_pending(autopilot_id) = FileUtils.rm_f(file_for(autopilot_id, 'pending'))

  # [{'id', 'by', 'reason'}] for one repo.
  def pending(repo:)
    Dir.glob(File.join(@root, '*.pending')).filter_map do |file|
      row = JSON.parse(File.read(file))
      { 'id' => File.basename(file, '.pending'), 'by' => row['by'], 'reason' => row['reason'] } if row.is_a?(Hash) && row['repo'] == repo
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end

  # A tombstone of any content ends it; an unreadable id counts as ended.
  def ended?(autopilot_id)
    File.exist?(file_for(autopilot_id, 'ended'))
  rescue ArgumentError
    true
  end

  def append_ledger(autopilot_id, row)
    FileUtils.mkdir_p(@root)
    File.open(file_for(autopilot_id, 'jsonl'), 'a') { |file| file.puts(JSON.generate(row)) }
  end

  def ledger(autopilot_id)
    path = file_for(autopilot_id, 'jsonl')
    return [] unless File.file?(path)

    File.readlines(path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  private

  def file_for(autopilot_id, ext)
    raise ArgumentError, "not an autopilot id: #{autopilot_id.inspect}" unless autopilot_id.to_s.match?(ID)

    File.join(@root, "#{autopilot_id}.#{ext}")
  end
end
