#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'hook_event'
require_relative 'leased_inbox'
require_relative 'inbox_store'
require_relative 'inbox_paths'
require_relative 'inbox_prompt_hook'

# Stop hook: surfaces the shared leased inbox (triage decisions, escalations,
# stale hosts) and the cf:inbox announce items, where pulse P0s go. Announce
# items are mirrored into the leased inbox under a stable key, so both sources
# share one delivery rule: a new item is announced once, then marked delivered.
# An unresolved delivered item is not repeated here; it stays listed by
# LeasedInbox#open_items (and the triage report) until acknowledged. Never
# blocks the turn and fails silent: a broken inbox must not wedge a session.
class DoctrineReviewSurface
  ANNOUNCE_WINDOW = 24 * 3600
  LEASE_TTL = 300

  def self.run(event, io = $stdout, inbox: LeasedInbox.new, now: Time.now.utc)
    new(event, inbox, now).emit(io)
  rescue StandardError
    nil
  end

  def initialize(event, inbox, now)
    @event = event
    @inbox = inbox
    @now = now
  end

  def emit(io)
    return if @event['stop_hook_active']

    mirror_announces
    leased = @inbox.lease(owner: owner, ttl: LEASE_TTL)
    return if leased.empty?

    # Announce first; mark delivered only once output succeeded. If output
    # raises, the items stay leased and a later session reclaims them.
    io.puts(JSON.generate(systemMessage: message(leased)))
    io.flush if io.respond_to?(:flush)
    leased.each { |item| deliver(item) }
  end

  private

  def owner = @event['session_id'].to_s.then { |id| id.empty? ? 'unknown' : id }

  def deliver(item)
    @inbox.deliver(item['key'], token: item['fence'])
  rescue LeasedInbox::Error
    nil
  end

  def message(items)
    lines = items.map { |item| "- [#{item['kind']}] #{item['title']}" }
    "Inbox: #{items.size} new item#{'s' if items.size > 1}\n#{lines.join("\n")}"
  end

  # cf:inbox announce items are fyi files, one per role. Only the session's own
  # role directory is read, and only recent files, so history never floods.
  def mirror_announces
    root = InboxPromptHook.configured_root or return
    role = InboxPromptHook.role_for(@event, root) or return
    source = File.realpath(root)
    Dir.glob(File.join(InboxStore.inbox_dir(role), '*.md')).sort.each { |path| mirror(path, role, source) }
  end

  def mirror(path, role, source)
    return if @now - File.mtime(path) > ANNOUNCE_WINDOW

    meta = InboxStore.frontmatter(File.read(path))
    return unless meta['status'] == 'fyi'

    @inbox.upsert(kind: 'announce', key: LeasedInbox.dedup_key('announce', "#{source}##{role}", File.basename(path)),
                  title: meta['subject'].to_s, body: File.read(path), data: { 'from' => meta['from'], 'path' => path })
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.instrument('doctrine_review_surface', event) { DoctrineReviewSurface.run(event) }
end
