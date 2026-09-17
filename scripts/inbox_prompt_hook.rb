#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require_relative 'hook_event'
require_relative 'inbox_store'
require_relative 'inbox_paths'
require_relative 'inbox_roster'

# UserPromptSubmit hook: shows a role session its own pending inbox and the
# tail of the shared ledger, once per change. It self-gates on the resolved
# inbox root actually existing and carrying a roster.json, so it prints
# nothing in every project that has not opted into the inbox capability.
#
# Role comes from ~/.claude/cf/sessions/<session_id>/inbox-role first (written
# by `inbox_store.rb bind`); only when that is absent does it fall back to
# sniffing the session's last /rename title against a pattern built from the
# roster's own configured roles, never a hardcoded list. That fallback exists
# because a role session's title lands mid-transcript as a custom-title
# record, so this is a prompt hook rather than a SessionStart hook: at cold
# start the title is not in the file yet.
class InboxPromptHook
  EVENT = 'UserPromptSubmit'

  def self.run(event, io = $stdout)
    root = configured_root
    return unless root

    role = role_for(event, root)
    return if role.nil?

    body = render(role, event['session_id'].to_s)
    return if body.nil?

    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: body }))
  rescue StandardError
    nil
  end

  # The inbox is "configured" only when its resolved root exists on disk and
  # carries a roster.json. Returns the root path, or nil.
  def self.configured_root
    root = InboxPaths.root
    return nil unless File.directory?(root)
    return nil unless File.exist?(InboxRoster.path(root))

    root
  rescue StandardError
    nil
  end

  def self.role_pattern(root)
    roles = InboxRoster.roles(root)
    return nil if roles.empty?

    /\b(#{roles.map { |role| Regexp.escape(role) }.join('|')})\b/
  end

  def self.session_role_path(session_id)
    File.join(Dir.home, '.claude', 'cf', 'sessions', session_id, 'inbox-role')
  end

  def self.transcript_path(event)
    path = event['transcript_path'].to_s
    return path unless path.empty?

    slug = event['cwd'].to_s.gsub(/[^a-zA-Z0-9]/, '-')
    File.join(Dir.home, '.claude', 'projects', slug, "#{event['session_id']}.jsonl")
  end

  # Primary: the session's bound role, written by `bind`. Fallback: the last
  # custom-title record in the transcript, matched against a pattern built
  # from the roster's configured roles. Neither present: nil, print nothing.
  def self.role_for(event, root)
    bound = bound_role(event['session_id'].to_s)
    return bound if bound

    role_from_transcript(event, root)
  end

  def self.bound_role(session_id)
    return nil if session_id.empty?

    path = session_role_path(session_id)
    return nil unless File.exist?(path)

    role = File.read(path).strip
    role.empty? ? nil : role
  rescue StandardError
    nil
  end

  # The last custom-title record wins: a session that was renamed twice is
  # whatever it was renamed to last.
  def self.role_from_transcript(event, root)
    pattern = role_pattern(root)
    return nil unless pattern

    path = transcript_path(event)
    return nil unless File.exist?(path)

    title = nil
    File.foreach(path) do |line|
      next unless line.include?('custom-title')

      parsed = (JSON.parse(line) rescue nil)
      title = parsed['customTitle'] if parsed.is_a?(Hash) && parsed['type'] == 'custom-title'
    end
    match = pattern.match(title.to_s)
    match && match[1]
  rescue StandardError
    nil
  end

  def self.render(role, session_id)
    items = InboxStore.pending(role)
    tail = InboxStore.ledger_tail(8)
    lines = [ "[inbox] #{role}: #{items.length} pending" ]
    items.each { |item| lines << "  - #{item['subject']} (#{item['status']}) #{item['path']}" }
    lines << 'Recent ledger:'
    tail.each { |line| lines << "  #{line}" }
    lines << 'Pick one up with: ruby ~/.claude/cf/bin/inbox_store.rb pick <path>'
    body = lines.join("\n")
    seen?(body, session_id) ? nil : body
  end

  # Print-once-on-change, the same idiom as skills-announced and
  # slop-reminded: a session that is deep in a tool loop should not see the
  # same block on every prompt.
  def self.seen?(body, session_id)
    return false if session_id.empty?

    path = File.join(Dir.home, '.claude', 'cf', 'sessions', session_id, 'inbox-seen')
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
  InboxPromptHook.run(event)
end
