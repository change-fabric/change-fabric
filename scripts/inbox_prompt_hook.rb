#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require_relative 'hook_event'
require_relative 'inbox_store'

# UserPromptSubmit hook: shows an AMFM role session its own pending inbox and
# the tail of the shared ledger, once per change. Role comes from the
# session's /rename title, which lands mid-transcript as a custom-title
# record, so this is a prompt hook rather than a SessionStart hook: at cold
# start the title is not in the file yet. The hook is registered globally
# because settings.json is the only settings file on this machine, so it
# self-gates on cwd and prints nothing everywhere else.
class InboxPromptHook
  EVENT = 'UserPromptSubmit'
  PROJECT = File.join(Dir.home, 'code', 'servant-io', 'AMFM')
  ROLE_PATTERN = /\b(PLAN|BUILD|PULLS|DEPLOY|QA|LOCAL)\b/

  def self.run(event, io = $stdout)
    return unless in_project?(event['cwd'])

    role = role_for(event)
    return if role.nil?

    body = render(role)
    return if body.nil?

    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: body }))
  rescue StandardError
    nil
  end

  # Worktrees live under the project path too, so a prefix match on the
  # realpath is the gate. Anything outside it prints nothing at all.
  def self.in_project?(cwd)
    return false if cwd.to_s.empty?

    real = File.realpath(cwd.to_s)
    project = File.realpath(PROJECT)
    real == project || real.start_with?("#{project}/")
  rescue StandardError
    false
  end

  def self.transcript_path(event)
    path = event['transcript_path'].to_s
    return path unless path.empty?

    slug = event['cwd'].to_s.gsub(/[^a-zA-Z0-9]/, '-')
    File.join(Dir.home, '.claude', 'projects', slug, "#{event['session_id']}.jsonl")
  end

  # The last custom-title record wins: a session that was renamed twice is
  # whatever it was renamed to last.
  def self.role_for(event)
    path = transcript_path(event)
    return nil unless File.exist?(path)

    title = nil
    File.foreach(path) do |line|
      next unless line.include?('custom-title')

      parsed = (JSON.parse(line) rescue nil)
      title = parsed['customTitle'] if parsed.is_a?(Hash) && parsed['type'] == 'custom-title'
    end
    match = ROLE_PATTERN.match(title.to_s)
    match && match[1]
  rescue StandardError
    nil
  end

  def self.render(role)
    items = InboxStore.pending(role)
    tail = InboxStore.ledger_tail(8)
    lines = [ "[inbox] #{role}: #{items.length} pending" ]
    items.each { |item| lines << "  - #{item['subject']} (#{item['status']}) #{item['path']}" }
    lines << 'Recent ledger:'
    tail.each { |line| lines << "  #{line}" }
    lines << 'Pick one up with: ruby ~/.claude/cf/bin/inbox_store.rb pick <path>'
    body = lines.join("\n")
    seen?(body) ? nil : body
  end

  # Print-once-on-change, the same idiom as skills-announced and
  # slop-reminded: a session that is deep in a tool loop should not see the
  # same block on every prompt.
  def self.seen?(body)
    session = ENV['CLAUDE_INBOX_SESSION'].to_s
    return false if session.empty?

    path = File.join(Dir.home, '.claude', 'cf', 'sessions', session, 'inbox-seen')
    digest = Digest::SHA256.hexdigest(body)
    return true if File.exist?(path) && File.read(path).strip == digest

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, digest)
    false
  rescue StandardError
    false
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  ENV['CLAUDE_INBOX_SESSION'] = event['session_id'].to_s
  InboxPromptHook.run(event)
end
