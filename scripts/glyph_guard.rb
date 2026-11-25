#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'guarded_command'
require_relative 'plan_check'

# PreToolUse hook: the glyph and length rules for authored text, enforced at the
# moment of authoring instead of only reminded.
#
#   glyph_guard/glyph      deny: a commit message, `gh pr create|edit` title or
#                          body, or a .md Write/Edit holds a PlanCheck::GLYPHS
#                          character (em-dash, bullet, ellipsis, smart quote).
#   glyph_guard/title_len  deny: a PR title over 60 characters.
#   glyph_guard/body_len   advise: a PR body over 640 characters.
#
# Like the other guards it reads the command text, so it is a loud guardrail and
# not a sandbox. CF_ALLOW_GLYPH=1 waives the glyph rule for a downstream repo
# whose own product copy needs these characters.
class GlyphGuard
  EVENT = 'PreToolUse'
  TITLE_MAX = 60
  BODY_MAX = 640
  TITLE_FLAGS = %w[--title -t].freeze
  BODY_FLAGS = %w[--body -b].freeze
  HEREDOC = /<<-?\s*['"]?(\w+)['"]?[^\n]*\n(.*?)\n[ \t]*\1\b/m

  def initialize(event) = @event = event

  def emit(io = $stdout)
    verdict = decide
    io.puts(JSON.generate(verdict)) if verdict
  rescue StandardError
    nil
  end

  private

  def decide
    case @event['tool_name']
    when 'Bash' then bash_verdict(command)
    when 'Write', 'Edit' then file_verdict
    end
  end

  def input
    value = @event['tool_input']
    value.is_a?(Hash) ? value : {}
  end

  def command = input['command'].to_s

  def glyph_allowed? = ENV['CF_ALLOW_GLYPH'] == '1'

  # --- Bash: git commit, gh pr create, gh pr edit

  def bash_verdict(cmd)
    commit = GuardedCommand.invokes?(cmd, 'git', 'commit')
    pr = GuardedCommand.invokes?(cmd, 'gh', 'pr', 'create') || GuardedCommand.invokes?(cmd, 'gh', 'pr', 'edit')
    return nil unless commit || pr

    return deny('glyph', glyph_reason(commit ? 'commit message' : 'PR title or body')) if cmd.match?(PlanCheck::GLYPHS) && !glyph_allowed?
    return nil unless pr

    pr_length_verdict(cmd)
  end

  def pr_length_verdict(cmd)
    title = flag_value(cmd, TITLE_FLAGS)
    if title && title.length > TITLE_MAX
      return deny('title_len', "[cf] PR title is #{title.length} characters; the cap is #{TITLE_MAX}. " \
                               'Shorten it: say what changed, not how or why.')
    end

    body = body_value(cmd)
    return nil unless body && body.length > BODY_MAX

    advise("[cf] PR body is #{body.length} characters; keep it to #{BODY_MAX} unless a code snippet or test-plan " \
           'checklist needs more, and keep the core description inside the limit.')
  end

  def body_value(cmd)
    value = flag_value(cmd, BODY_FLAGS)
    return value unless value&.include?('<<')

    # A heredoc body: the tokenizer sees the whole `$(cat <<'EOF' ...)` string,
    # so measure the heredoc text itself.
    cmd.match(HEREDOC)&.captures&.last
  end

  # The value of the first of `flags`, in `--flag value` or `--flag=value` form.
  def flag_value(cmd, flags)
    tokens = GuardedCommand.tokens(cmd)
    tokens.each_with_index do |token, index|
      flags.each do |flag|
        return tokens[index + 1] if token == flag && tokens[index + 1]
        return token.delete_prefix("#{flag}=") if flag.start_with?('--') && token.start_with?("#{flag}=")
      end
    end
    nil
  end

  # --- Write and Edit of markdown

  def file_verdict
    return nil unless input['file_path'].to_s.downcase.end_with?('.md')
    return nil if glyph_allowed?

    text = input['content'].to_s + input['new_string'].to_s
    deny('glyph', glyph_reason('markdown file')) if text.match?(PlanCheck::GLYPHS)
  end

  # --- Output

  def glyph_reason(what)
    "[cf glyph_guard] The #{what} holds an AI-slop glyph (em-dash, bullet glyph, ellipsis glyph, or smart " \
      "quote). Use a comma, colon or restructure for the dash; '-' or '*' for bullets; '...' for the ellipsis; " \
      'straight quotes. CF_ALLOW_GLYPH=1 waives this for a repo whose own copy needs them.'
  end

  def deny(rule, reason)
    { hookSpecificOutput: { hookEventName: EVENT, permissionDecision: 'deny',
                            permissionDecisionReason: "#{reason} (glyph_guard/#{rule})" } }
  end

  def advise(text)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: "#{text} (glyph_guard/body_len)" } }
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.instrument('glyph_guard', event) { GlyphGuard.new(event).emit }
end
