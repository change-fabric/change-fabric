#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'

# PreToolUse hook: denies a tool call whose authored text carries a client,
# customer, or downstream-project name/domain the user has flagged as
# sensitive. This exists to protect THIS toolkit, which is shared across
# projects: the banned-term list is never committed here (that would defeat
# the point, and would itself leak whatever it names); each user maintains
# their own list at ~/.claude/cf/sensitive_terms.txt (one term per line, '#'
# comments and blank lines ignored). Because the hook installs globally (every
# repo, every session), it must not fire outside this repo: a client's own
# project mentioning its own name in its own repo is normal and correct, not a
# leak. So it only activates when the current repo's remote is this toolkit's
# own (CF_REPO_REMOTE below); anywhere else, including the client's own repos
# that merely have this toolkit installed, it is a silent no-op. With no
# terms, or no matching repo, the guard has nothing to flag and stays quiet,
# matching the hooks-fail-silent rule.
#
# Like the other guards here this is a loud guardrail, not a sandbox: it
# matches authored content and is bypassable (CF_ALLOW_SENSITIVE_TERM=1 is
# the escape hatch for a genuine, deliberate mention).
class ClientNameGuard
  EVENT = 'PreToolUse'

  DEFAULT_TERMS_PATH = File.join(Dir.home, '.claude', 'cf', 'sensitive_terms.txt')

  # Matches this toolkit's own GitHub remote, however it is cloned (origin,
  # a fork remote, https or ssh). Not a client name: this is the tool's own
  # identity, same as it citing its own repo name elsewhere in its docs.
  CF_REPO_REMOTE = %r{[/:]pstaylor-patrick/change-fabric(?:\.git)?\b}i

  # Bash commands that author outbound text (mirrors glyph_guard's categories).
  AUTHORING_BASH = [
    /\bgit\b[^&|;]*\bcommit\b/,
    /\bgit\s+(?:checkout\s+-b|switch\s+-c|branch\s+(?:-[mM]\b|[^-\s]))/,
    /\bgh\b[^&|;]*\bpr\b[^&|;]*\b(?:create|edit)\b/
  ].freeze

  MCP_AUTHORING = /create|edit|update|save|add|reply|comment|draft|post|worklog/i

  def initialize(event, terms_path: ENV['CF_SENSITIVE_TERMS_FILE'] || DEFAULT_TERMS_PATH,
                 remote_v: -> { `git remote -v 2>/dev/null` })
    @event = event
    @terms_path = terms_path
    @remote_v = remote_v
  end

  def emit(io = $stdout)
    return if ENV['CF_ALLOW_SENSITIVE_TERM'] == '1'

    terms = banned_terms
    return if terms.empty?

    found = offenders(terms)
    return if found.empty?
    return unless cf_toolkit_repo?

    io.puts(JSON.generate(deny(found)))
  rescue StandardError
    nil
  end

  private

  # Checked only once a term has actually matched, so the common case (no
  # match) never pays for a git shell-out.
  def cf_toolkit_repo?
    @remote_v.call.to_s.lines.any? { |line| line.match?(CF_REPO_REMOTE) }
  end

  def banned_terms
    return [] unless File.file?(@terms_path)

    File.readlines(@terms_path).map(&:strip)
        .reject { |line| line.empty? || line.start_with?('#') }
  rescue StandardError
    []
  end

  def offenders(terms)
    text = scannable.join(' ')
    terms.select { |term| text.match?(/#{Regexp.escape(term)}/i) }
  end

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
          "[cf] Sensitive term(s) in #{@event['tool_name']} input: #{found.join(', ')}. " \
          'This repo is shared across projects; keep authored output generic (no specific ' \
          'client, customer, or downstream-project names/domains). Set CF_ALLOW_SENSITIVE_TERM=1 ' \
          'only if this mention is genuinely deliberate.'
      }
    }
  end
end

ClientNameGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
