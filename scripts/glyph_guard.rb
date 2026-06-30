#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'

# PreToolUse hook: denies a tool call whose authored text carries an AI-slop
# glyph (em-dash, bullet, ellipsis, smart quotes) or a banned attribution phrase
# (the agent harness appends a Claude Code footer to commits and PR bodies by
# default; the maintainer does not want it on any surface). The "no em-dash"
# doctrine was advisory only, so a probabilistic author could leak the character
# straight to an external surface - the leak that prompted this was a Jira comment
# posted via MCP, a surface no git-side or Bash-only check can see. PreToolUse is
# the one interception point that sits in front of every outbound surface (Bash,
# file writes, MCP), and it can deny before anything external happens, so the model
# retries clean - the same self-correcting loop as merge_mode_guard.
#
# Like the other guards here this is a loud guardrail, not a sandbox: it matches
# authored content and is bypassable (PST_ALLOW_GLYPH=1 is the documented escape
# hatch for the rare genuine insertion, e.g. editing a third-party fixture).
class GlyphGuard
  EVENT = 'PreToolUse'

  # Banned glyph => the ASCII the model should use instead, named in the deny
  # reason so the fix is unambiguous. En-dash and other dashes are allowed.
  BANNED = {
    "—" => "' - ' (spaced hyphen) or restructure",   # em-dash
    "•" => "'*' or '-' for a list bullet",            # bullet
    "…" => "'...'",                                   # ellipsis
    "“" => 'a straight double quote',                # left smart quote
    "”" => 'a straight double quote',                # right smart quote
    "‘" => "a straight single quote",                # left smart quote
    "’" => "a straight single quote"                 # right smart quote / apostrophe
  }.freeze

  PATTERN = Regexp.union(*BANNED.keys)

  # Banned authored phrases (not single glyphs) => the fix named in the deny
  # reason. The harness footer is "Generated with [Claude Code](...)"; the bracket
  # is optional so both the linked and plain forms are caught.
  BANNED_PHRASES = {
    /generated with \[?claude code/i =>
      'remove the agent attribution footer (the "Generated with" / "Claude Code" line)'
  }.freeze

  # Bash commands that author outbound text (mirrors slop_remind's categories).
  # Other Bash is left alone so glyph-handling commands (grep/sed over the
  # character) and file authoring covered by the Write/Edit path are not blocked.
  AUTHORING_BASH = [
    /\bgit\b[^&|;]*\bcommit\b/,
    /\bgit\s+(?:checkout\s+-b|switch\s+-c|branch\s+(?:-[mM]\b|[^-\s]))/,
    /\bgh\b[^&|;]*\bpr\b[^&|;]*\b(?:create|edit)\b/
  ].freeze

  # MCP write verbs. A read tool whose name happens to contain one of these is
  # also scanned (harmless - query strings rarely carry these glyphs, and the
  # escape hatch exists), which is the cost of matching broad substrings so new
  # write tools are covered without an exact-name allowlist to maintain.
  MCP_AUTHORING = /create|edit|update|save|add|reply|comment|draft|post|worklog/i

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return if ENV['PST_ALLOW_GLYPH'] == '1'

    found = offenders
    return if found.empty?

    io.puts(JSON.generate(deny(found)))
  rescue StandardError
    nil
  end

  private

  # Each offender is a ready "what -> fix" line for the deny reason, so glyphs and
  # phrases report through one path.
  def offenders
    text = scannable.join
    glyphs = BANNED.select { |glyph, _| text.include?(glyph) }
                   .map { |glyph, fix| "#{glyph} -> #{fix}" }
    phrases = BANNED_PHRASES.select { |pattern, _| text.match?(pattern) }.values
    glyphs + phrases
  end

  # Strings authored by this call, by tool. The added side only: Edit/MultiEdit
  # never scan old_string, so editing a file precisely to remove a glyph is not
  # blocked. Read/Grep/Glob/WebFetch and read-verb MCP tools yield nothing, so
  # reading third-party text full of these glyphs never trips.
  def scannable
    input = @event['tool_input']
    return [] unless input.is_a?(Hash)

    strings_for(@event['tool_name'].to_s, input).select { |s| s.is_a?(String) }
  end

  def strings_for(tool, input)
    case tool
    when 'Bash'         then authoring_bash?(input['command']) ? [ input['command'] ] : []
    when 'Write'        then [ input['content'] ]
    when 'Edit'         then [ input['new_string'] ]
    when 'MultiEdit'    then Array(input['edits']).map { |e| e['new_string'] if e.is_a?(Hash) }
    when 'NotebookEdit' then [ input['new_source'] ]
    else mcp_authoring?(tool) ? deep_strings(input) : []
    end
  end

  def authoring_bash?(command)
    AUTHORING_BASH.any? { |pattern| command.to_s.match?(pattern) }
  end

  def mcp_authoring?(tool)
    tool.start_with?('mcp__') && tool.match?(MCP_AUTHORING)
  end

  # MCP inputs are arbitrarily shaped, so collect every String value.
  def deep_strings(value)
    case value
    when String then [ value ]
    when Array  then value.flat_map { |v| deep_strings(v) }
    when Hash   then value.values.flat_map { |v| deep_strings(v) }
    else []
    end
  end

  def deny(found)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason:
          "[pst] Banned AI-slop content in #{@event['tool_name']} input: #{found.join('; ')}. " \
          'Rewrite without it. Set PST_ALLOW_GLYPH=1 only if it is genuinely ' \
          'required (e.g. editing a third-party fixture).'
      }
    }
  end
end

GlyphGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
