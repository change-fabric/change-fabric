#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'review_queue'

# The fixed review instructions handed to the agent when review-eligible files
# changed. Extracted from skill_review so both consumers - the Stop-hook driver
# (skill_review) and the pre-PR gate (review_gate) - emit identical text from one
# source.
module ReviewPrompt
  module_function

  ACK_SCRIPT = File.expand_path('review_ack.rb', __dir__)

  # The review must run and return BEFORE the verdict is recorded, and the gate
  # is released only by the explicit ack, never by being dispatched. So the
  # prompt tells the agent to wait for the review (not background it), then run
  # the ack command, then retry. The ack and the retry must be separate commands:
  # the gate inspects the command at PreToolUse, before it runs, so an "ack; push"
  # chain reads the still-unreviewed queue and denies the whole thing. New edits
  # after the ack change their content hash and re-arm the review.
  def build(entries, registry, session_id)
    by_name = registry.to_h { |skill| [ skill.name, skill ] }
    sections = entries.group_by { |entry| entry[:skill] }
                      .map { |name, rows| section(by_name[name], name, rows) }
    <<~TEXT.strip
      [cf review] #{entries.size} file(s) changed this session under review-enabled
      skills have not been reviewed yet. Review them before this work leaves the machine.

      Run the review now and WAIT for its result (do not background it):
      Agent(subagent_type: "general-purpose", model: "haiku", run_in_background: false),
      giving it exactly the task below. Report only concrete violations as
      `path:line - smell -> smallest behavior-preserving fix`; if none, say "clean".
      Address any findings, then record the verdict so the gate releases:

          #{ack_command(session_id)}

      Run that ack on its own, then re-run your push or PR as a separate command,
      or finish the turn. The gate reads the queue before a command runs, so
      chaining them (ack and push in one command) is still denied.

      #{sections.join("\n\n")}
    TEXT
  end

  def ack_command(session_id) = "ruby #{ACK_SCRIPT} #{session_id}"

  def cap_notice(count)
    "[cf review] Round cap (#{ReviewQueue::CAP}) reached; #{count} file(s) " \
      'still changing. Automatic design review is paused for this session; review ' \
      'remaining changes manually or invoke /cf:ruby.'
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
