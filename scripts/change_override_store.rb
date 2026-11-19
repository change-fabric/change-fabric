#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_sha_record'

# Records a human-authorized override of the change-fabric merge gate for one
# exact (sha[, profile]): the reachable substitute change_merge_guard.rb reads
# when CF_ALLOW_UNGATED_MERGE=1 cannot be, because that env var is read inside
# the guard's own PreToolUse hook process, whose environment is fixed at
# harness launch and unreachable from anything an agent exports or prefixes on
# a command mid-session. change_override.rb is the human-run companion that
# writes this record; nothing here runs unattended. Keyed the same way
# ChangeGateStore is, so an override for one profile's head can never unlock a
# different profile or a later commit: the moment the head SHA moves, the
# override is simply gone. A distinct file extension (not just the shared base
# class's plain sha[/__profile] path) keeps a recorded override from ever
# colliding with a gate-store record for the same key.
class ChangeOverrideStore < ChangeShaRecord
  # An optional `proof` (see scripts/approval_console) is stored beside the
  # reason; ChangeGateCheck verifies it. `policy_sha` is the authoritative
  # policy commit the Recorder checked the proof against.
  def record(reason:, recorded_by:, proof: nil, policy_sha: nil)
    payload = {
      'sha' => @sha,
      'profile' => @profile,
      'reason' => reason.to_s,
      'recorded_by' => recorded_by.to_s,
      'recorded_at' => Time.now.utc.iso8601
    }
    payload['proof'] = proof if proof
    payload['policy_sha'] = policy_sha if policy_sha
    write(payload)
  end

  def authorized? = !read.nil?

  # Rewrites the stored proof when its body is `body` (a sync attaching a
  # console receipt, or marking a conflict).
  def update_proof(body)
    record = read
    return 0 unless record.is_a?(Hash) && record.dig('proof', 'body') == body

    write(record.merge('proof' => yield(record['proof'])))
    1
  end

  private

  def extension = '.override'
end
