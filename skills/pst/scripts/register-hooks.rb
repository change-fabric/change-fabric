#!/usr/bin/env ruby
# frozen_string_literal: true
# Idempotently register the PST inert global hook shim in a settings.json.
#
#   register-hooks.rb <settings_path> <bin_dir>
#
# Adds SessionStart, SessionEnd, and a PreToolUse dispatcher whose commands live
# in <bin_dir>. Existing PST entries (any command referencing the bin dir) are
# removed first, so re-running self-updates rather than duplicating. All other
# hooks and settings are preserved.
require 'json'
require 'fileutils'
require 'rbconfig'

settings = File.expand_path(ARGV[0])
bin = ARGV[1]
ruby = RbConfig.ruby

cfg =
  if File.exist?(settings)
    begin
      JSON.parse(File.read(settings))
    rescue StandardError
      {}
    end
  else
    {}
  end

hooks = (cfg['hooks'] ||= {})
cmd = ->(name) { "#{ruby} #{File.join(bin, name)}" }
strip = lambda do |groups|
  (groups || []).reject do |g|
    (g['hooks'] || []).any? { |h| h['command'].to_s.include?(bin) }
  end
end

pre = strip.call(hooks['PreToolUse'])
pre << {
  'matcher' => 'Write|Edit|MultiEdit|NotebookEdit|Bash|Agent|Task',
  'hooks' => [{ 'type' => 'command', 'command' => cmd.call('pst-guard.rb') }]
}
hooks['PreToolUse'] = pre

start = strip.call(hooks['SessionStart'])
start << { 'hooks' => [{ 'type' => 'command', 'command' => cmd.call('pst-session-start.rb') }] }
hooks['SessionStart'] = start

ending = strip.call(hooks['SessionEnd'])
ending << { 'hooks' => [{ 'type' => 'command', 'command' => cmd.call('pst-session-end.rb') }] }
hooks['SessionEnd'] = ending

prompt = strip.call(hooks['UserPromptSubmit'])
prompt << { 'hooks' => [{ 'type' => 'command', 'command' => cmd.call('pst-prompt-reminder.rb') }] }
hooks['UserPromptSubmit'] = prompt

post = strip.call(hooks['PostToolUse'])
post << {
  'matcher' => 'Write|Edit|MultiEdit',
  'hooks' => [{ 'type' => 'command', 'command' => cmd.call('pst-delegate-nudge.rb') }]
}
post << {
  'matcher' => 'Bash|mcp__.*Atlassian__(createJiraIssue|editJiraIssue|addCommentToJiraIssue)',
  'hooks' => [{ 'type' => 'command', 'command' => cmd.call('pst-open-on-post.rb') }]
}
hooks['PostToolUse'] = post

FileUtils.mkdir_p(File.dirname(settings))
File.write(settings, "#{JSON.pretty_generate(cfg)}\n")
puts "pst: registered global hook shim in #{settings}"
