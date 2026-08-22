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
#
# A monorepo (v0.4.0 `change_config.apps`) records one entry per app under the
# same (sha, profile) key rather than one file per app: a merge gate asks one
# question per SHA, and keying by app would multiply override files too, forcing
# a human recording an override to enumerate apps. `record(app: ...)` merges
# into whatever is already on disk for this (sha, profile) instead of
# overwriting, so a `--app portal` run today and a `--app scattergram` run
# tomorrow both land in the same record. Merging is sound precisely because the
# key already expires the moment the head moves: any entry found under this SHA
# was, by construction, produced against this exact tree. The top-level
# `scope`/`status`/`report` fields are retained as the aggregate across every
# recorded app, so a 0.3.1-era reader (single-app mode, `app` always nil) sees
# exactly the record shape it always has.
class ChangeGateStore < ChangeShaRecord
  # `manifest` is the run's inputs (image digests, the vendored axe version, a
  # digest of the resolved config, the toolkit version). It is stored beside
  # the verdict, never consulted by the gate: the gate's question stays "did a
  # comprehensive run pass for this SHA", and the manifest is what lets someone
  # reading a recorded pass weeks later see what it was a pass of.
  def record(scope:, status:, project:, lanes:, report:, app: nil, profile: nil, target: nil, manifest: nil)
    if app
      record_app(app.to_s, scope: scope, status: status, lanes: lanes, report: report, project: project,
                 target: target, manifest: manifest)
    else
      payload = {
        'sha' => @sha,
        'scope' => scope.to_s,
        'status' => status.to_s,
        'project' => project.to_s,
        'lanes' => lanes,
        'report' => report.to_s,
        'recorded_at' => Time.now.utc.iso8601
      }
      payload['profile'] = profile.to_s unless profile.to_s.empty?
      payload['target'] = target.to_s unless target.to_s.empty?
      payload['manifest'] = manifest unless manifest.nil? || manifest.empty?
      write(payload)
    end
  end

  # The release gate's question: did a comprehensive run pass for this SHA?
  # With no `apps` list, unchanged 0.3.1 behavior: the top-level aggregate must
  # be a passing `all` run. With an `apps` list, every named app must itself
  # carry a passing `all` entry in the record's `apps` map; a record written by
  # a pre-0.4.0 toolkit has no `apps` map at all and so fails closed rather than
  # being misread as "every app passed".
  def comprehensive_pass?(apps: nil)
    record = read
    return false unless record

    return record['scope'] == 'all' && record['status'] == 'pass' unless apps

    apps.all? { |name| app_passed?(record, name) }
  end

  # Whether one named lane passed in the record for this SHA (0.10.0), asked by
  # a promotion rule that gates on a specific lane
  # (`promotion.<ref>.require_testcases`) rather than only on the aggregate
  # verdict. Fails closed: a record that never ran the lane has no entry for
  # it, and "not run" is not "passed". With an `apps` list every named app's
  # own entry must carry the passing lane, the same way comprehensive_pass?
  # scopes by app.
  def lane_passed?(lane, apps: nil)
    record = read
    return false unless record

    return record.dig('lanes', lane.to_s) == 'pass' unless apps

    apps.all? { |name| record.dig('apps', name.to_s, 'lanes', lane.to_s) == 'pass' }
  end

  # The subset of `names` with no passing comprehensive entry recorded, for a
  # merge-gate deny message that names exactly what is missing rather than
  # forcing the operator to diff the whole record by hand.
  def missing_apps(names)
    record = read
    names.reject { |name| app_passed?(record, name) }
  end

  private

  def app_passed?(record, name)
    entry = record && record['apps'] && record['apps'][name.to_s]
    entry && entry['scope'] == 'all' && entry['status'] == 'pass'
  end

  def record_app(app, scope:, status:, lanes:, report:, project:, target:, manifest: nil)
    payload = read || { 'sha' => @sha }
    payload['project'] = project.to_s
    apps = (payload['apps'] ||= {})
    apps[app] = {
      'scope' => scope.to_s,
      'status' => status.to_s,
      'lanes' => lanes,
      'report' => report.to_s
    }
    apps[app]['target'] = target.to_s unless target.to_s.empty?
    apps[app]['manifest'] = manifest unless manifest.nil? || manifest.empty?

    payload['scope'] = scope.to_s
    payload['status'] = apps.values.all? { |entry| entry['status'] == 'pass' } ? 'pass' : 'fail'
    payload['report'] = report.to_s
    payload['recorded_at'] = Time.now.utc.iso8601
    write(payload)
  end
end
