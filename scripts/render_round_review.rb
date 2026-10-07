#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'render_finding_comment'

# Renders a second-round cf:code-review consolidated comment: a root-cause
# recommendation for the whole PR instead of more inline findings. Takes JSON
# on stdin ({title, summary, folded?, handoff}) and prints the review body.
# The core (header, summary, folded findings) is capped at CORE_CAP; the
# fenced agent handoff prompt below it is not, since it is meant to be pasted
# whole. The handoff must name no local or absolute filesystem path: it is
# read by whoever opens the PR, on a machine that has none of this one's files.
class RenderRoundReview
  CORE_CAP = 640
  HEADER_PREFIX = '**Root cause review - '
  # The body an away-mode second round posts at the head: it carries the
  # header so thread_history's consolidatedAtHead stops a rerun at that head.
  PENDING_BODY = "#{HEADER_PREFIX}plan pending**\n\nA root-cause plan for this PR is pending " \
                 'with its author; the remaining lower-tier findings are held for it.'
  # An allowlist, not a denylist of local shapes: each whitespace token is
  # split on markup delimiters (Markdown link brackets, angle brackets,
  # quotes, backticks, emphasis, tables, key=value, commas, semicolons) so a path embedded in
  # markup is judged on its own, and every component that names a path
  # (holds a slash or backslash, or starts with ~ or $) must be an http(s)
  # URL, a namespaced slash command (/cf:plan), or a repo-relative path.
  # A .. segment escapes the repo, so it is refused like an absolute path.
  # Anything else, including a bare root-level /repo or /tmp, a drive
  # path, a UNC share or ~/x, is machine-local and refused.
  PATHLIKE = %r{[/\\]|\A[~$]}
  URL = %r{\Ahttps?://[^\s/]+(?:/\S*)?\z}
  SLASH_COMMAND = /\A\/[a-z][\w-]*:[\w-]+\z/
  RELATIVE_PATH = %r{\A(?![/~$]|[A-Za-z]:)(?!.*(?:\\|//|:[/~$]|\$\{?HOME|(?:\A|/)\.claude/|(?:\A|[/:])\.\.(?:/|\z)))\S+\z}
  COMPONENT_SPLIT = /[\[\](){}<>"'`=,;*_|]+/
  TOKEN_WRAP = /\A[`"'(\[<{]+|[`"')\]>},.;:!?]+\z/
  FOLDED_LEAD = 'Also found this round: '

  def self.local_path?(text)
    text.split.flat_map { |raw| raw.split(COMPONENT_SPLIT) }.any? do |raw|
      token = raw.gsub(TOKEN_WRAP, '')
      next false unless token.match?(PATHLIKE)

      !(token.match?(URL) || token.match?(SLASH_COMMAND) || token.match?(RELATIVE_PATH))
    end
  end

  def initialize(input)
    @title = input.fetch('title').strip
    @summary = input.fetch('summary').strip
    @folded = Array(input['folded'])
    @handoff = input.fetch('handoff').strip
    validate!
  end

  def render
    "#{core}\n\nAgent handoff prompt:\n\n```text\n#{@handoff}\n```"
  end

  def core
    (0..@folded.size).reverse_each do |keep|
      text = core_text(@summary, keep)
      return text if text.length <= CORE_CAP
    end
    without_folded = core_text(@summary, 0, folded: false)
    core_text(truncated_summary(without_folded.length), 0, folded: false)
  end

  private

  def validate!
    raise 'title, summary and handoff must be non-empty' if [ @title, @summary, @handoff ].any?(&:empty?)
    raise 'handoff names a local path' if self.class.local_path?(@handoff)
    raise 'handoff must not contain a code fence' if @handoff.include?('```')

    @folded.each do |item|
      raise "unknown tier: #{item['tier']}" unless RenderFindingComment::BADGES.key?(item['tier'])
    end
  end

  def core_text(summary, keep, folded: true)
    parts = [ "#{HEADER_PREFIX}#{@title}**", '', summary ]
    parts += [ '', folded_line(keep) ] if folded && @folded.any?
    parts.join("\n")
  end

  def folded_line(keep)
    shown = @folded.first(keep).map { |f| "#{RenderFindingComment::BADGES.fetch(f['tier'])} #{f['tier']} #{f['title'].strip}" }
    rest = @folded.size - keep
    shown << "+#{rest} more" if rest.positive?
    "#{FOLDED_LEAD}#{shown.join('; ')}."
  end

  def truncated_summary(current_length)
    budget = @summary.length - (current_length - CORE_CAP) - 3
    "#{@summary[0, [ budget, 0 ].max]}..."
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    puts RenderRoundReview.new(JSON.parse($stdin.read)).render
  rescue StandardError => e
    warn "render_round_review: #{e.message}"
    exit 1
  end
end
