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

if ARGV[0] == 'foreground'
  sid = resolve_sid
  fdir = File.join(PST_HOME, 'foreground')
  FileUtils.mkdir_p(fdir)
  if ARGV[1] == 'off'
    FileUtils.rm_f(File.join(fdir, sid)) if sid
    puts "pst: foreground mode off#{sid ? " (session #{sid})" : ''}"
  else
    FileUtils.touch(File.join(fdir, sid)) if sid
    puts "pst: foreground mode on#{sid ? " (session #{sid})" : ''}; delegate nudges silenced"
  end
  exit 0
end

if ARGV[0] == 'local'
  sid = resolve_sid
  ldir = File.join(PST_HOME, 'local')
  FileUtils.mkdir_p(ldir)
  if ARGV[1] == 'off'
    FileUtils.rm_f(File.join(ldir, sid)) if sid
    puts "pst: local-only mode off#{sid ? " (session #{sid})" : ''}; remote pushes and PRs follow the chosen merge mode"
  else
    FileUtils.touch(File.join(ldir, sid)) if sid
    puts "pst: local-only mode on#{sid ? " (session #{sid})" : ''}; git push and gh pr/issue mutations are blocked"
  end
  exit 0
end

# 1. Remove any prior non-Ruby hook scripts, then install the Ruby ones (plus the
#    shared lib) to a stable, repo-independent location.
%w[pst-guard.py pst-session-start.sh pst-session-end.sh].each { |f| FileUtils.rm_f(File.join(BIN, f)) }
%w[pst_common.rb pst-guard.rb pst-session-start.rb pst-session-end.rb
   pst-prompt-reminder.rb pst-delegate-nudge.rb pst-open-on-post.rb].each do |f|
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
