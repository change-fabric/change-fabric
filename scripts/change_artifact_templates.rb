#!/usr/bin/env ruby
# frozen_string_literal: true

# Locates the two ERB templates the artifact pipeline renders. They live with
# the skill they belong to (`skills/change/reference/`) rather than beside the
# scripts, because they are part of what a reader of cf:change is pointed at:
# the artifact page is as much a documented output shape as `CHANGE.template.md`
# is a documented input shape.
#
# That placement is why this lookup exists. `install.rb` copies `scripts/*.rb`
# into `~/.claude/cf/bin` and symlinks each skill directory into
# `~/.claude/skills/<name>`, so an installed script and its templates end up in
# two different trees, and the same script has to work when run straight out of
# a clone. Both roots are checked, in that order, and a genuinely missing
# template raises by name rather than rendering an empty artifact.
module ChangeArtifactTemplates
  class MissingTemplate < StandardError; end

  PAGE = 'artifact.html.erb'
  PDF = 'artifact-pdf.html.erb'

  module_function

  def page = path(PAGE)
  def pdf = path(PDF)

  def path(name)
    found = roots.map { |root| File.join(root, name) }.find { |candidate| File.exist?(candidate) }
    raise MissingTemplate, "artifact template not found: #{name} (looked in #{roots.join(', ')})" unless found

    found
  end

  # The repo checkout first (so a working copy's edits are what a local run
  # renders), then every installed skill root `install.rb` can produce.
  def roots
    [
      File.expand_path('../skills/change/reference', __dir__),
      File.join(Dir.home, '.claude', 'skills', 'cf:change', 'reference'),
      File.join(Dir.home, '.config', 'opencode', 'skills', 'cf-change', 'reference')
    ]
  end

  def slug(text)
    cleaned = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
    cleaned.empty? ? 'item' : cleaned
  end
end
