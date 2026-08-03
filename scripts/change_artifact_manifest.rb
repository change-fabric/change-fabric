#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'
require_relative 'change_artifact_templates'
require_relative 'shell_git'

# The one record a published run is described by: who ran it, against which
# commit and PR, what the four lanes found, and where its media landed. The
# artifact page renders it, the bundle writes it out as `manifest.json`, and the
# publisher declares it to the artifacts service, which records the run and
# lists it on the team's findings page. Building it in one place is what keeps
# those consumers from each inventing their own idea of a run.
#
# Every git and GitHub lookup here is best-effort: a detached HEAD, a missing
# `gh`, or a branch with no PR yields a nil field, never an exception. This is
# an evidence artifact attached to a run, and no part of assembling it may
# affect whether the run itself passed.
class ChangeArtifactManifest
  SCHEMA = 1

  def self.build(...) = new(...).to_h

  # `findings` is the run's Findings collection, `report` the ChangeReport path
  # pair, `media` the ChangeMedia sink (or nil), `artifacts` the resolved
  # ChangeArtifactsConfig, `run` the mechanical run facts ChangeRun already has
  # in hand (project, app, scope, profile, target).
  # `generated_at` is passed in rather than taken here so that the bundle
  # directory a lane has already been writing media into, and the run id inside
  # the manifest, are stamped from the same instant instead of from whenever
  # assembly happened to start.
  def initialize(repo_root:, findings:, report:, media:, artifacts:, run:, generated_at: Time.now.utc)
    @repo_root = repo_root
    @findings = findings
    @report = report
    @media = media
    @artifacts = artifacts
    @run = run
    @generated_at = generated_at
  end

  def to_h
    identity = @artifacts.identity
    {
      'schema' => SCHEMA, 'run_id' => run_id, 'generated_at' => @generated_at.iso8601,
      'team_id' => @artifacts.team_id, 'repo_id' => repo_id,
      'contributor_id' => identity&.contributor_id || 'unknown',
      'contributor_name' => identity&.contributor_name || 'unregistered contributor',
      'roster' => @artifacts.roster, 'git' => git_context, 'run' => run_context,
      'status' => @findings.passed? ? 'pass' : 'fail', 'lane_status' => @findings.lane_status,
      'counts' => counts, 'findings' => findings_rows, 'viewports' => viewport_sections,
      'reports' => report_names
    }
  end

  # The stable, sortable id a run is addressed by everywhere: the UTC stamp
  # (which orders lexicographically) plus the short head SHA (which makes two
  # runs of the same commit in the same second distinguishable from two runs of
  # different commits).
  # WHERE the bundle lands is deliberately not decided here. The artifacts
  # service assigns every run's key prefix from the organization and team the
  # publishing key belongs to, so a client that invented one would be asserting
  # a location it has no authority over and that the server would ignore. The
  # run id above is this manifest's own identifier and stays local to it.
  def run_id = "#{@generated_at.strftime('%Y%m%dT%H%M%SZ')}-#{short_sha}"

  private

  # From the repo, not from the contributor. Reading this off `identity` meant a
  # machine that had never run `cf_team_join.rb` published `unknown-repo` even
  # though its git remote resolved perfectly well, which put the artifact's own
  # repo_id at odds with the `repo_link` row keyed on the real one. Those two
  # have to agree: the whole point of a repo link is answering "which team owns
  # what this run pushed from".
  def repo_id = (@artifacts.repo_id || 'unknown-repo')

  def run_context
    {
      'project' => @run[:project], 'app' => @run[:app], 'scope' => @run[:scope],
      'profile' => @run[:profile], 'target' => @run[:target]
    }
  end

  def git_context
    pr = pull_request
    {
      'branch' => git('rev-parse', '--abbrev-ref', 'HEAD'), 'head_sha' => head_sha,
      'short_sha' => short_sha, 'subject' => git('log', '-1', '--pretty=%s'),
      'pr_number' => pr && pr['number'], 'pr_url' => pr && pr['url'], 'pr_title' => pr && pr['title']
    }
  end

  def counts
    {
      'total' => @findings.size, 'fail' => count_status('fail'),
      'warn' => count_status('warn'), 'pass' => count_status('pass')
    }
  end

  def count_status(status) = @findings.count { |finding| finding.status == status }

  def findings_rows
    @findings.sort_by { |finding| status_order(finding.status) }.map do |finding|
      {
        'lane' => finding.lane, 'status' => finding.status, 'severity' => finding.severity,
        'target' => finding.target, 'check' => finding.check, 'location' => finding.location,
        'detail' => finding.detail, 'help' => finding.help
      }
    end
  end

  def status_order(status) = { 'fail' => 0, 'warn' => 1 }.fetch(status, 2)

  # One section per viewport actually captured, each carrying its own
  # screenshots, its recording, its PDF, and the findings that named that
  # viewport. Grouping the evidence by viewport (rather than one flat gallery)
  # is the whole point of the per-viewport sections: a responsive regression is
  # read by comparing one breakpoint's walk against another's.
  def viewport_sections
    return [] unless @media

    viewport_names.map do |name|
      {
        'name' => name,
        'screenshots' => @media.screenshots_for(name).map { |shot| { 'route' => shot.route, 'path' => shot.path } },
        'video' => video_entry(name), 'pdf' => "pdf/#{ChangeArtifactTemplates.slug(name)}.pdf",
        'findings' => findings_for_viewport(name)
      }
    end
  end

  def video_entry(name)
    video = @media.videos.find { |candidate| candidate.viewport == name }
    return nil unless video

    { 'path' => video.path, 'bytes' => video.bytes, 'error' => video.error }
  end

  # Viewport order follows capture order, so the artifact's sections read
  # smallest-to-largest exactly as the config declared them.
  def viewport_names
    (@media.screenshots.map(&:viewport) + @media.videos.map(&:viewport)).compact.uniq
  end

  # A browserless finding names its viewport in its `check` ("mobile 390x844",
  # "mobile figma diff"), which is how a finding is attached to the section it
  # belongs under without teaching the lane about artifacts.
  def findings_for_viewport(name)
    findings_rows.select { |row| row['lane'] == 'browserless' && row['check'].to_s.start_with?("#{name} ") }
  end

  def report_names
    return {} unless @report

    { 'markdown' => File.basename(@report[:markdown].to_s), 'csv' => File.basename(@report[:csv].to_s) }
  end

  def head_sha = @head_sha ||= git('rev-parse', 'HEAD').to_s
  def short_sha = head_sha.empty? ? 'nosha' : head_sha[0, 7]

  def git(*args) = ShellGit.run(@repo_root, *args)

  # The PR the head commit belongs to, via the real `gh` CLI, or nil when there
  # is none, `gh` is not installed, or it is not authenticated. A run outside a
  # PR is ordinary (a branch sweep, a local check), so this is a nil field, not
  # a warning.
  def pull_request
    return @pull_request if defined?(@pull_request)

    out, status = Open3.capture2e('gh', 'pr', 'view', '--json', 'number,url,title')
    @pull_request = status.success? ? JSON.parse(out) : nil
  rescue StandardError
    @pull_request = nil
  end
end
