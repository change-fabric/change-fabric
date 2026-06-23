# frozen_string_literal: true
# Shared helpers for the PST session-scoped hooks. Installed alongside the hook
# bodies in ~/.claude/pst/bin and loaded with require_relative. Keep this free of
# the literal em dash glyph (use Pst::EM).
require 'json'
require 'fileutils'
require 'open3'
require 'timeout'

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
  # exit 2 blocks the tool call; stderr is surfaced to Claude as the error.
  def deny!(reason)
    $stderr.puts reason
    exit 2
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

  # Default branch for the repo at `dir`, resolved from origin/HEAD.
  # Falls back to "main" on any failure.
  def default_branch(dir)
    dir = Dir.pwd unless dir && File.directory?(dir)
    out, st = Timeout.timeout(10) do
      Open3.capture2e('git', '-C', dir, 'symbolic-ref', 'refs/remotes/origin/HEAD')
    end
    return 'main' unless st.success?
    ref = out.strip
    ref.empty? ? 'main' : ref.split('/').last
  rescue StandardError
    'main'
  end

  # Current checked-out branch name at `dir`, or '' on failure/detached HEAD.
  def current_branch(dir)
    dir = Dir.pwd unless dir && File.directory?(dir)
    out, st = Timeout.timeout(10) do
      Open3.capture2e('git', '-C', dir, 'rev-parse', '--abbrev-ref', 'HEAD')
    end
    st.success? ? out.strip : ''
  rescue StandardError
    ''
  end

  IN_FLIGHT_STATUSES = %w[pending running].freeze

  def ledger_path(sid = session_id)
    File.join(HOME, 'ledger', "#{sid}.json")
  end

  # Read and parse a ledger file by path. Empty array on missing or corrupt file.
  # Single source of ledger-read behavior shared by the CLI and the hooks so
  # neither side reimplements the on-disk schema knowledge.
  def read_entries(path)
    return [] unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue StandardError
    []
  end

  def load_ledger(sid = session_id)
    read_entries(ledger_path(sid))
  end

  def in_flight_count(sid = session_id)
    load_ledger(sid).count { |e| IN_FLIGHT_STATUSES.include?(e['status']) }
  end
end
