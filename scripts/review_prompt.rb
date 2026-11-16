#!/usr/bin/env ruby
# frozen_string_literal: true

require 'shellwords'
require_relative 'review_queue'

# The fixed review instructions handed to the agent when review-eligible files
# changed. Extracted from skill_review so both consumers - the Stop-hook driver
# (skill_review) and the pre-PR gate (review_gate) - emit identical text from one
# source.
module ReviewPrompt
  module_function

  ACK_SCRIPT = File.expand_path('review_ack.rb', __dir__)
  # Hosts without an Agent tool rewrite this line to their native reviewer.
  REVIEWER = 'Agent(subagent_type: "general-purpose", model: "haiku")'

  # The gate is released only by the explicit ack, never by the review being
  # dispatched. Agent calls may return asynchronously, so the prompt does not ask
  # the agent to block on the review; it says to run the ack once the review's
  # result arrives, and that the gate stays closed until then. The ack and the
  # retry must be separate commands: the gate inspects the command at
  # PreToolUse, before it runs, so an "ack; push" chain reads the still
  # unreviewed queue and denies the whole thing. New edits after the ack change
  # their content hash and re-arm the review. keys is one queue key or several.
  def build(entries, registry, keys)
    by_name = registry.to_h { |skill| [ skill.name, skill ] }
    sections = entries.group_by { |entry| entry[:skill] }
                      .map { |name, rows| section(by_name[name], name, rows) }
    <<~TEXT.strip
      [cf review] #{entries.size} file(s) changed this session under review-enabled
      skills have not been reviewed yet. Review them before this work leaves the machine.

      Launch the review now:
      #{REVIEWER},
      giving it exactly the task below. Report only concrete violations as
      `path:line - smell -> smallest behavior-preserving fix`; if none, say "clean".
      When its result arrives, address any findings, then record the verdict.
      The gate stays closed until this ack runs:

          #{ack_command(keys)}

      Run that ack on its own, then re-run your push or PR as a separate command,
      or finish the turn. The gate reads the queue before a command runs, so
      chaining them (ack and push in one command) is still denied.

      #{sections.join("\n\n")}
    TEXT
  end

  def ack_command(keys) = Shellwords.join([ 'ruby', ACK_SCRIPT, *Array(keys) ])

  def cap_notice(count)
    "[cf review] Round cap (#{ReviewQueue::CAP}) reached; #{count} file(s) " \
      'still changing. Automatic design review is paused for this batch until it ' \
      'changes; review remaining changes manually or invoke /cf:ruby.'
  end

  def section(skill, name, rows)
    files = rows.map { |row| "- #{row[:path]}" }.join("\n")
    <<~TEXT.strip
      ## Review against the #{name} skill
      #{taxonomy_note(skill)}
      Files:
      #{files}

      #{name} principles:
      #{skill&.body || '(principles unavailable)'}
    TEXT
  end

  # Each scope frames what the reviewer should treat as in-bounds. all_code
  # matches by extension, which can misfire on data or prose that merely looks
  # like code, so judge code-ness first. all_files is deliberately broad, so the
  # reviewer must not skip prose or documentation as "not code".
  def taxonomy_note(skill)
    return code_only_note if skill&.all_code?
    return every_file_note if skill&.all_files?

    ''
  end

  def code_only_note
    "\nFirst confirm each changed file is genuinely code (it may be code embedded " \
      "in another format). Review only real code; mark anything that is not code as clean.\n"
  end

  def every_file_note
    "\nThis skill applies to every changed file, including prose and documentation, " \
      "not just code. Review all of them.\n"
  end
end
