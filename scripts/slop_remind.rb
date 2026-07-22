#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'skill_store'
require_relative 'guarded_command'

# PreToolUse hook: the cf:ai-slop rubric governs text authored through git/gh,
# not just file contents. When a Bash command is about to write a commit message,
# a branch name, or a PR title/description, surface the rubric at that moment. The
# full rubric is injected once per session (sharing cf:ai-slop's surfaced marker
# with skill_inject, so it is not repeated after a file edit already showed it);
# later authoring gets a one-line pointer, once per category, to avoid noise.
class SlopRemind
  EVENT = 'PreToolUse'
  SKILL = 'cf:ai-slop'

  CATEGORIES = {
    'commit message' => ->(cmd) { GuardedCommand.invokes?(cmd, 'git', 'commit') },
    'branch name' => ->(cmd) { branch_creation?(cmd) },
    'PR title or description' => lambda { |cmd|
      GuardedCommand.invokes?(cmd, 'gh', 'pr', 'create') || GuardedCommand.invokes?(cmd, 'gh', 'pr', 'edit')
    }
  }.freeze

  # `git checkout -b`/`git switch -c` always create; `git branch` creates only
  # with a name argument (a rename via -m/-M still counts, but -a/-d/etc do not).
  def self.branch_creation?(cmd)
    tokens = GuardedCommand.tokens(cmd)
    return true if tokens.each_cons(3).any? { |w| w == %w[git checkout -b] }
    return true if tokens.each_cons(3).any? { |w| w == %w[git switch -c] }

    idx = tokens.each_cons(2).find_index { |a, b| a == 'git' && b == 'branch' }
    return false unless idx

    arg = tokens[idx + 2]
    arg && (arg.match?(/\A-[mM]\z/) || !arg.start_with?('-'))
  end

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
    CATEGORIES.find { |_, matcher| matcher.call(cmd) }&.first
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
      "[cf #{SKILL}] You are authoring a #{category}. Apply this rubric:\n\n#{skill.body}"
    else
      "[cf #{SKILL}] You are authoring a #{category}; apply the AI slop rubric already in context."
    end
  end
end

SlopRemind.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
