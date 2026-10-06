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
  # Any machine-local reference: a home shorthand, the .claude tree, a
  # file:// URL, a Windows drive path, or an absolute POSIX path of two or
  # more segments. The lookbehind keeps URL paths (https://host/a/b),
  # repo-relative paths (scripts/x.rb) and slash commands (/cf:plan) legal.
  LOCAL_PATH = %r{~/|\$\{?HOME\b|\.claude/|file://|\b[A-Za-z]:\\|(?<![\w.:/~-])/[\w.@+-]+/}
  FOLDED_LEAD = 'Also found this round: '

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
    raise 'handoff names a local path' if @handoff.match?(LOCAL_PATH)
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
