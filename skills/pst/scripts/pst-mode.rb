#!/usr/bin/env ruby
# frozen_string_literal: true
# /pst bootstrap: install the inert global hook shim (idempotent), run the git
# identity guard, and arm THIS session's no-em-dash guard.
#
#   pst-mode.rb         arm this session (and install the shim if missing)
#   pst-mode.rb off     disarm this session
require 'fileutils'
require 'rbconfig'

PST_HOME = File.expand_path('~/.claude/pst')
BIN = File.join(PST_HOME, 'bin')
ARMED = File.join(PST_HOME, 'armed')
SRC = __dir__
HOOKS = File.join(SRC, 'hooks')
SETTINGS = File.expand_path('~/.claude/settings.json')

FileUtils.mkdir_p(BIN)
FileUtils.mkdir_p(ARMED)

def resolve_sid
  env = ENV['CLAUDE_SESSION_ID']
  return env if env && !env.empty?

  # Fallback for the very first session before SessionStart has ever run:
  # the active session's transcript is the most recently modified .jsonl.
  newest = Dir.glob(File.expand_path('~/.claude/projects/**/*.jsonl'))
              .max_by { |f| File.mtime(f) rescue Time.at(0) }
  newest && File.basename(newest, '.jsonl')
end

if ARGV[0] == 'off'
  sid = resolve_sid
  FileUtils.rm_f(File.join(ARMED, sid)) if sid
  puts "pst: disarmed#{sid ? " session #{sid}" : ''}"
  exit 0
end

def toggle_flag(subdir, flag_name, on_suffix: nil, off_suffix: nil)
  sid = resolve_sid
  dir = File.join(PST_HOME, subdir)
  FileUtils.mkdir_p(dir)
  sid_part = sid ? " (session #{sid})" : ''
  if ARGV[1] == 'off'
    FileUtils.rm_f(File.join(dir, sid)) if sid
    msg = "pst: #{flag_name} mode off#{sid_part}"
    msg += "; #{off_suffix}" if off_suffix
    puts msg
  else
    FileUtils.touch(File.join(dir, sid)) if sid
    msg = "pst: #{flag_name} mode on#{sid_part}"
    msg += "; #{on_suffix}" if on_suffix
    puts msg
  end
  exit 0
end

if ARGV[0] == 'foreground'
  toggle_flag('foreground', 'foreground',
              on_suffix: 'delegate nudges silenced')
end

if ARGV[0] == 'local'
  toggle_flag('local', 'local-only',
              on_suffix: 'git push and gh pr/issue mutations are blocked',
              off_suffix: 'remote pushes and PRs follow the chosen merge mode')
end

# 1. Remove any prior non-Ruby hook scripts, then install the Ruby ones (plus the
#    shared lib) to a stable, repo-independent location.
%w[pst-guard.py pst-session-start.sh pst-session-end.sh].each { |f| FileUtils.rm_f(File.join(BIN, f)) }
%w[pst_common.rb pst-guard.rb pst-session-start.rb pst-session-end.rb
   pst-prompt-reminder.rb pst-delegate-nudge.rb pst-open-on-post.rb
   pst-post-compact.rb].each do |f|
  FileUtils.install(File.join(HOOKS, f), File.join(BIN, f), mode: 0o755)
end

# 2. Git identity guard.
expected = '1963845+pstaylor-patrick@users.noreply.github.com'
current = `git config --global user.email`.strip
if current != expected
  system('git', 'config', '--global', 'user.email', expected)
  puts "git identity: set global user.email to #{expected} (was: #{current.empty? ? 'unset' : current})"
else
  puts "git identity: OK (#{expected})"
end

# 3. Register the global shim idempotently.
system(RbConfig.ruby, File.join(SRC, 'register-hooks.rb'), SETTINGS, BIN)

# 4. Arm this session.
sid = resolve_sid
if sid
  FileUtils.touch(File.join(ARMED, sid))
  # Reset local-only mode each invoke; the merge-mode question re-arms it if chosen.
  FileUtils.rm_f(File.join(PST_HOME, 'local', sid))
  puts "pst: armed session #{sid}"
  puts 'delegate by default: independent, well-scoped, non-gating work goes to ' \
       'background Sonnet worktree agents; foreground is planning, choices, ' \
       'orchestration, and validation. `pst-mode.rb foreground on` silences nudges.'
  puts 'note: in the session that first installs the shim, the em-dash guard ' \
       'engages next session; thereafter arming takes effect immediately because ' \
       'the shim is bound at session startup.'
else
  puts 'pst: could not resolve session id; em-dash enforcement engages next session'
end

# 5. Initialize the task ledger for this session.
system(RbConfig.ruby, File.join(SRC, 'pst-ledger.rb'), 'init', in: File::NULL)

# 6. Cache the ledger script path so skills can read it without re-deriving it.
ledger_script = File.expand_path(File.join(SRC, 'pst-ledger.rb'))
File.write(File.join(PST_HOME, 'ledger-path'), ledger_script)
