#!/usr/bin/env ruby
# frozen_string_literal: true

require 'erb'
require 'json'

# The rendering context the artifact templates are evaluated against. Templates
# get named readers and small helpers and nothing else: no filesystem, no AWS
# client, no Findings object. That boundary is what lets the page template be
# read as a page rather than as a program, and it is also the cf:pdf-rendering
# rule about passing plain data objects into a compiled template.
#
# Everything user- or tool-supplied goes through `h` (HTML-escaped) or `json`
# (JSON-escaped for a `<script type="application/json">` block). A finding's
# detail is free text produced by axe, ZAP, k6, or a page's own console, so it
# is never trusted markup.
class ChangeArtifactView
  STATUS_LABELS = { 'pass' => 'PASS', 'warn' => 'WARN', 'fail' => 'FAIL' }.freeze

  # `section` is one viewport's slice of the manifest, set only when rendering
  # that viewport's PDF. `inline` is the callable that turns a bundle-relative
  # image path into a data URI; the page template leaves images as relative
  # paths (they sit next to `index.html` in the bucket), while the PDF template
  # inlines them, since the rendering browser is in a container with no access
  # to the host filesystem.
  def initialize(manifest, artifacts:, section: nil, inline: nil)
    @manifest = manifest
    @artifacts = artifacts
    @section = section
    @inline = inline
  end

  def render(template_path)
    ERB.new(File.read(template_path), trim_mode: '-').result(binding)
  end

  # --- run facts ----------------------------------------------------------------

  def manifest = @manifest
  def section = @section
  def run_id = @manifest['run_id'].to_s
  def status = @manifest['status'].to_s
  def status_label = STATUS_LABELS.fetch(status, status.upcase)
  def generated_at = @manifest['generated_at'].to_s
  def team_id = @manifest['team_id'].to_s
  def repo_id = @manifest['repo_id'].to_s
  def contributor_name = @manifest['contributor_name'].to_s
  def contributor_id = @manifest['contributor_id'].to_s
  def roster = Array(@manifest['roster'])
  def git = @manifest['git'] || {}
  def run = @manifest['run'] || {}
  def counts = @manifest['counts'] || {}
  def lane_status = @manifest['lane_status'] || {}
  def findings = Array(@manifest['findings'])
  def viewports = Array(@manifest['viewports'])
  def reports = @manifest['reports'] || {}

  def project = run['project'].to_s
  def title = "#{project} #{status_label}: #{run_id}"

  def findings_for(lane) = findings.select { |finding| finding['lane'] == lane }

  def lanes = lane_status.keys

  def pr_link
    number = git['pr_number']
    return nil unless number

    { 'label' => "PR ##{number}", 'url' => git['pr_url'].to_s, 'title' => git['pr_title'].to_s }
  end

  # --- per-viewport ---------------------------------------------------------------

  def section_name = (@section || {})['name'].to_s
  def section_screenshots = Array((@section || {})['screenshots'])
  def section_findings = Array((@section || {})['findings'])
  def section_video = (@section || {})['video']

  def findings_for_route(route)
    section_findings.select { |finding| finding['location'].to_s == route.to_s }
  end

  # The screenshot as the template should reference it: a data URI when this
  # render inlines assets (the PDF), the bundle-relative path otherwise (the
  # page, whose images sit beside it in the bucket).
  def image_src(path)
    return path.to_s unless @inline

    @inline.call(path) || ''
  end

  def video_available?(entry) = entry.is_a?(Hash) && !entry['path'].to_s.empty?

  def human_bytes(bytes)
    value = bytes.to_i
    return "#{value} B" if value < 1024
    return format('%.1f KB', value / 1024.0) if value < 1024 * 1024

    format('%.1f MB', value / (1024.0 * 1024))
  end

  # --- escaping helpers -------------------------------------------------------------

  def h(text) = ERB::Util.html_escape(text.to_s)

  # Embeds data in a `<script type="application/json">` block. `</script>` is
  # escaped as well as the JSON itself, so a finding whose detail quotes a
  # closing tag cannot break out of the block.
  def json(data) = JSON.generate(data).gsub('</', '<\\/')

  def status_class(value) = "s-#{ChangeArtifactView.token(value)}"

  def self.token(value)
    cleaned = value.to_s.downcase.gsub(/[^a-z0-9]+/, '-')
    cleaned.empty? ? 'none' : cleaned
  end
end

# The rendering context for the team index: one page at the bucket root listing
# every published run across every contributor on the team. It holds rows, not a
# manifest, and deliberately shares nothing with the per-run view beyond the
# escaping helpers, since the two pages answer different questions ("what did
# this run find" against "what has this team run").
class ChangeArtifactIndexView
  def initialize(rows, team_id:, generated_at:)
    @rows = rows
    @team_id = team_id
    @generated_at = generated_at
  end

  def render(template_path)
    ERB.new(File.read(template_path), trim_mode: '-').result(binding)
  end

  def rows = @rows
  def team_id = @team_id.to_s
  def generated_at = @generated_at.to_s
  def contributors = @rows.map { |row| row['contributor_name'].to_s }.reject(&:empty?).uniq.sort
  def repos = @rows.map { |row| row['repo_id'].to_s }.reject(&:empty?).uniq.sort
  def failing = @rows.count { |row| row['status'] == 'fail' }

  def h(text) = ERB::Util.html_escape(text.to_s)
  def json(data) = JSON.generate(data).gsub('</', '<\\/')
end
