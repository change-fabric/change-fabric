#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'

# Shared storage for the phone-approved records keyed by more than a sha:
# ChangeCarveOutStore (repo + PR number + head sha) and ChangeReleaseStore
# (repo + tag + sha). One JSON file per key under ~/.claude/cf/change/<dir>/,
# named by a digest of the key so any repo or tag spelling is a safe path.
# The key fields are stored too, and `lookup` returns a record only when they
# all match, so a renamed or copied file never satisfies another key.
# ApprovalConsole::Recorder is the only writer; the guards read with `lookup`.
class ChangeReceiptStore
  def initialize(root: nil)
    @root = root || File.join(Dir.home, '.claude', 'cf', 'change', self.class::DIR)
  end

  def path(**key) = File.join(@root, "#{Digest::SHA256.hexdigest(JSON.generate(normalize(key)))[0, 32]}.json")

  # Writes the verified receipt for `key`, replacing any earlier one.
  def write(key, proof:, policy_sha:, recorded_by:)
    record = normalize(key).merge('proof' => proof, 'policy_sha' => policy_sha.to_s,
                                  'recorded_by' => recorded_by.to_s, 'recorded_at' => Time.now.utc.iso8601)
    FileUtils.mkdir_p(@root)
    file = path(**key)
    tmp = "#{file}.#{Process.pid}.tmp"
    File.write(tmp, JSON.pretty_generate(record))
    File.rename(tmp, file)
    record
  end

  # The record for exactly `key`, or nil.
  def read(**key)
    file = path(**key)
    return nil unless File.file?(file)

    record = JSON.parse(File.read(file))
    record.is_a?(Hash) && record.slice(*normalize(key).keys) == normalize(key) ? record : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  private

  def normalize(key) = key.to_h { |name, value| [ name.to_s, value.to_s ] }.sort.to_h
end
