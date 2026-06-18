# frozen_string_literal: true
# Shared helpers for the PST session-scoped hooks. Installed alongside the hook
# bodies in ~/.claude/pst/bin and loaded with require_relative. Keep this free of
# the literal em dash glyph (use Pst::EM).
require 'json'
require 'fileutils'

module Pst
  EM = [0x2014].pack('U') # em dash (long dash); built so no literal glyph appears
  HOME = File.expand_path('~/.claude/pst')

  module_function

  # Parse the hook JSON payload from stdin once, memoized. Empty hash on error.
  def payload
    @payload ||= begin
      JSON.parse($stdin.read)
    rescue StandardError
      {}
    end
  end

  def session_id
    payload['session_id'].to_s
  end

  def armed?(sid = session_id)
    !sid.empty? && File.exist?(File.join(HOME, 'armed', sid))
  end

  def allow!
    exit 0
  end

  # Signal a PreToolUse deny and exit. Reason must not contain an em dash.
  def deny!(reason)
    puts JSON.generate(
      'hookSpecificOutput' => {
        'hookEventName' => 'PreToolUse',
        'permissionDecision' => 'deny',
        'permissionDecisionReason' => reason
      }
    )
    exit 0
  end

  def reviewed_dir
    File.join(HOME, 'reviewed')
  end

  def reviewed?(sha)
    !sha.to_s.empty? && File.exist?(File.join(reviewed_dir, sha))
  end

  def mark_reviewed(sha)
    return if sha.to_s.empty?

    FileUtils.mkdir_p(reviewed_dir)
    FileUtils.touch(File.join(reviewed_dir, sha))
  end

  def local_dir
    File.join(HOME, 'local')
  end

  # Merge mode 4: this session may not mutate remote GitHub state.
  def local_only?(sid = session_id)
    !sid.to_s.empty? && File.exist?(File.join(local_dir, sid))
  end
end
