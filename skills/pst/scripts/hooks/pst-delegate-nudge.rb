#!/usr/bin/env ruby
# frozen_string_literal: true
# PST PostToolUse nudge: after a few inline implementation edits in an armed
# session, surface a non-blocking reminder to consider delegating to a background
# worktree agent (rule 1). NEVER blocks (PostToolUse). Silent under the foreground
# escape hatch (PST_FOREGROUND_OK=1 or ~/.claude/pst/foreground/<sid>).
#
# Counts only foreground grunt work: it counts an edit only when the file is in
# the PRIMARY git worktree. Delegated work runs in linked worktrees (rules 2, 3),
# so worktree edits are never counted. This is correct whether or not sub-agents
# share the parent session id. Also skips docs/config/lockfiles/dotfiles. Favors
# under-counting over false positives.
require_relative 'pst_common'
require 'fileutils'
require 'open3'

# True only when the file lives in the primary worktree (not a linked worktree,
# not outside a repo). In a linked worktree, git-dir differs from git-common-dir.
def primary_worktree?(path)
  dir = File.dirname(path)
  return false unless File.directory?(dir)

  out, st = Open3.capture2e('git', '-C', dir, 'rev-parse', '--git-dir', '--git-common-dir')
  return false unless st.success?

  gd, gcd = out.lines.map(&:strip)
  return false if gd.nil? || gcd.nil?

  File.expand_path(gd, dir) == File.expand_path(gcd, dir)
end

exit 0 unless Pst.armed?

sid = Pst.session_id
exit 0 if ENV['PST_FOREGROUND_OK'] == '1'
exit 0 if File.exist?(File.join(Pst::HOME, 'foreground', sid))

path = (Pst.payload['tool_input'] || {})['file_path'].to_s
exit 0 if path.empty?

base = File.basename(path).downcase
SKIP_EXT = /\.(md|markdown|mdx|lock|tfvars|json|ya?ml|toml|ini|cfg|conf|env|txt|csv|svg)$/i
exit 0 if path =~ SKIP_EXT || base.include?('lock') || base == 'gemfile' || base.start_with?('.')

primary = primary_worktree?(path)

if ENV['PST_DEBUG_DELEGATE'] == '1'
  FileUtils.mkdir_p(File.join(Pst::HOME, 'delegate'))
  File.open(File.join(Pst::HOME, 'delegate', 'debug.log'), 'a') do |f|
    f.puts "sid=#{sid} primary=#{primary} cwd=#{Pst.payload['cwd']} path=#{path}"
  end
end

exit 0 unless primary # delegated edits live in linked worktrees; do not count

THRESHOLD = 3
dir = File.join(Pst::HOME, 'delegate')
FileUtils.mkdir_p(dir)
counter = File.join(dir, sid)
n = Pst.read_counter(counter) + 1

if n == 1
  d = Pst.default_branch(File.dirname(path))
  if Pst.current_branch(File.dirname(path)) == d
    puts JSON.generate(
      'hookSpecificOutput' => {
        'hookEventName' => 'PostToolUse',
        'additionalContext' =>
          "PST: editing directly on the default branch '#{d}'. " \
          'Create a feature branch before continuing.'
      }
    )
  end
end

if n >= THRESHOLD
  File.write(counter, '0')
  puts JSON.generate(
    'hookSpecificOutput' => {
      'hookEventName' => 'PostToolUse',
      'additionalContext' =>
        "PST: #{n} inline implementation edits in the primary worktree this session. " \
        'If this is independent, well-scoped, non-gating grunt work, delegate it to a ' \
        'background Sonnet agent in an isolated worktree (rule 1) instead of continuing ' \
        'inline. Run `pst-mode.rb foreground on` to silence this when foreground work ' \
        'is intentional.'
    }
  )
else
  File.write(counter, n.to_s)
end
exit 0
