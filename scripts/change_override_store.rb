#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_sha_record'

# Records a human-authorized override of the change-fabric merge gate for one
# exact (sha[, profile]): the reachable substitute change_merge_guard.rb reads
# when PST_ALLOW_UNGATED_MERGE=1 cannot be, because that env var is read inside
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
  def record(reason:, recorded_by:)
    write(
      'sha' => @sha,
      'profile' => @profile,
      'reason' => reason.to_s,
      'recorded_by' => recorded_by.to_s,
      'recorded_at' => Time.now.utc.iso8601
    )
  end

  def authorized? = !read.nil?

  private

  def extension = '.override'
end
