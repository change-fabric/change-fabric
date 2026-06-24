#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'skill_store'

# PreToolUse hook: the pst:ai-slop rubric governs text authored through git/gh,
# not just file contents. When a Bash command is about to write a commit message,
# a branch name, or a PR title/description, surface the rubric at that moment. The
# full rubric is injected once per session (sharing pst:ai-slop's surfaced marker
# with skill_inject, so it is not repeated after a file edit already showed it);
# later authoring gets a one-line pointer, once per category, to avoid noise.
class SlopRemind
  EVENT = 'PreToolUse'
  SKILL = 'pst:ai-slop'

  CATEGORIES = {
    'commit message' => /\bgit\b[^&|;]*\bcommit\b/,
    'branch name' => /\bgit\s+(?:checkout\s+-b|switch\s+-c|branch\s+(?:-[mM]\b|[^-\s]))/,
    'PR title or description' => /\bgh\b[^&|;]*\bpr\b[^&|;]*\b(?:create|edit)\b/
  }.freeze

  def initialize(event, skills: nil)
    @event = event
    @skills = skills
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'

    category = categorize(command)
    return unless category && skill

    text = reminder(category)
    return unless text

    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: text }))
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  def categorize(cmd)
    CATEGORIES.find { |_, pattern| cmd.match?(pattern) }&.first
  end

  def skill
    @skill ||= (@skills || SkillRegistry.load).find { |candidate| candidate.name == SKILL }
  end

  # Each category reminds once per session. The first reminder of the session
  # carries the full rubric; later ones point at the body already in context
  # (which a file edit may also have surfaced).
  def reminder(category)
    reminded = SkillStore.new(@event['session_id'], 'slop-reminded')
    return unless reminded.fresh([ category ]) == [ category ]

    reminded.mark([ category ])
    surfaced = SkillStore.new(@event['session_id'])
    if surfaced.fresh([ SKILL ]) == [ SKILL ]
      surfaced.mark([ SKILL ])
      "[pst #{SKILL}] You are authoring a #{category}. Apply this rubric:\n\n#{skill.body}"
    else
      "[pst #{SKILL}] You are authoring a #{category}; apply the AI slop rubric already in context."
    end
  end
end

SlopRemind.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
