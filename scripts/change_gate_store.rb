#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_sha_record'

# Records the outcome of a change-fabric run keyed by the git head SHA it ran
# against, so a merge gate in a later session can ask "did a comprehensive
# cf:change run pass for the exact commit this PR merges?" State is keyed by SHA
# rather than session id (unlike the merge-mode and review stores) precisely
# because the writer and the reader are different sessions: change_run writes
# after a run, the merge guard reads when a `gh pr merge` is attempted, possibly
# days later.
#
# A record is written for every run, standalone lane or comprehensive; only a
# `scope: all` record that passed satisfies the release gate, so a single-lane
# `cf:k6` run never accidentally unlocks a staging merge. `profile` scopes the
# record to one of a CHANGE.md's named change_config profiles (v0.2.0), so a
# comprehensive pass against `staging` never satisfies a gate that requires
# `production`, or the unscoped (no profiles configured) gate.
class ChangeGateStore < ChangeShaRecord
  def record(scope:, status:, project:, lanes:, report:)
    write(
      'sha' => @sha,
      'scope' => scope.to_s,
      'status' => status.to_s,
      'project' => project.to_s,
      'lanes' => lanes,
      'report' => report.to_s,
      'recorded_at' => Time.now.utc.iso8601
    )
  end

  # The release gate's question: did a comprehensive run pass for this SHA?
  def comprehensive_pass?
    record = read
    record && record['scope'] == 'all' && record['status'] == 'pass'
  end
end
