#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'
require 'fileutils'
require_relative 'inbox_paths'

# One shared inbox with a lease state machine: pending, leased, delivered,
# resolved. A producer upserts an item on a stable dedup key, so repeated
# ticks never duplicate it. A consumer leases pending items (a fenced token,
# a TTL), announces them once, and marks them delivered. Delivered is not
# done: an unresolved delivered item stays visible until someone acknowledges
# or supersedes it, and it is never announced a second time. A lease that
# lapses (the session ended mid-delivery) makes the item leasable again.
#
# Every mutation runs under one flock and writes through write-then-rename, so
# two sessions cannot both win a lease and a crash leaves a whole file.
class LeasedInbox
  STATES = %w[pending leased delivered resolved].freeze
  DEFAULT_TTL = 300

  class Error < StandardError; end
  class Fenced < Error; end

  def self.default_root
    ENV.fetch('CF_LEASED_INBOX_ROOT') { File.join(InboxPaths.expected_home, '.claude', 'cf', 'leased_inbox') }
  end

  def self.dedup_key(kind, unit, finding) = [ kind, unit, finding ].map(&:to_s).join('|')

  def initialize(root: self.class.default_root, clock: -> { Time.now.utc })
    @root = root
    @clock = clock
  end

  attr_reader :root

  # Creates the item, or refreshes title, body and data of an existing
  # unresolved one. State, lease and delivery are untouched by a refresh. A
  # resolved item stays resolved: an acknowledged finding does not nag again.
  def upsert(kind:, key:, title:, body: '', data: {})
    locked do
      item = read(key) || new_item(kind, key)
      item.merge!('title' => title, 'body' => body, 'data' => data, 'updated_at' => stamp) unless item['state'] == 'resolved'
      write(item)
      item
    end
  end

  # Leases up to limit items that are pending, or leased with a lapsed lease.
  # Each lease bumps the item's fence; the returned items carry the new token.
  def lease(owner:, ttl: DEFAULT_TTL, limit: 20)
    locked do
      now = @clock.call
      claimable = all.select { |item| claimable?(item, now) }.first(limit)
      claimable.map do |item|
        fence = item['fence'].to_i + 1
        item.merge!('state' => 'leased', 'fence' => fence, 'updated_at' => stamp,
                    'lease' => { 'owner' => owner, 'token' => fence, 'expires_at' => (now + ttl).iso8601 })
        write(item)
        item
      end
    end
  end

  # Marks a leased item delivered. A stale token (the lease lapsed and another
  # owner took it) or a lapsed lease raises Fenced and changes nothing.
  def deliver(key, token:)
    locked do
      item = read(key) or raise Error, "unknown item #{key}"
      raise Fenced, "stale lease on #{key}" unless item['state'] == 'leased' && item['fence'] == token
      raise Fenced, "lease lapsed on #{key}" if Time.parse(item['lease']['expires_at']) <= @clock.call

      item.merge!('state' => 'delivered', 'delivered_at' => stamp, 'updated_at' => stamp, 'lease' => nil)
      write(item)
      item
    end
  end

  # The only ways out of delivered: the human acknowledges, or a later tick
  # proves the finding gone and supersedes it. Both resolve the item.
  def acknowledge(key, by: 'human') = resolve(key, "acknowledged:#{by}")
  def supersede(key, reason: 'superseded') = resolve(key, reason)

  def fetch(key) = locked { read(key) }

  # Everything the human still owes an answer to: anything not resolved,
  # including delivered items and leased items whose delivery may have been lost.
  def open_items = locked { all.reject { |item| item['state'] == 'resolved' } }

  def counts = locked { all.group_by { |item| item['state'] }.transform_values(&:size) }

  private

  def resolve(key, how)
    locked do
      item = read(key) or raise Error, "unknown item #{key}"
      unless item['state'] == 'resolved'
        item.merge!('state' => 'resolved', 'resolved_at' => stamp, 'resolution' => how, 'lease' => nil, 'updated_at' => stamp)
        write(item)
      end
      item
    end
  end

  def claimable?(item, now)
    return true if item['state'] == 'pending'

    item['state'] == 'leased' && Time.parse(item.dig('lease', 'expires_at').to_s) <= now
  rescue ArgumentError
    true
  end

  def new_item(kind, key)
    { 'key' => key, 'kind' => kind, 'state' => 'pending', 'fence' => 0, 'lease' => nil,
      'created_at' => stamp, 'delivered_at' => nil }
  end

  def stamp = @clock.call.iso8601(3)

  def items_dir = File.join(@root, 'items')

  def path_for(key) = File.join(items_dir, "#{Digest::SHA256.hexdigest(key)[0, 32]}.json")

  def read(key)
    JSON.parse(File.read(path_for(key)))
  rescue Errno::ENOENT
    nil
  end

  def all
    Dir.glob(File.join(items_dir, '*.json')).sort.filter_map do |path|
      JSON.parse(File.read(path))
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end.sort_by { |item| [ item['created_at'].to_s, item['key'] ] }
  end

  def write(item)
    FileUtils.mkdir_p(items_dir)
    InboxPaths.write_atomically(path_for(item['key']), "#{JSON.pretty_generate(item)}\n")
  end

  def locked
    FileUtils.mkdir_p(@root)
    File.open(File.join(@root, 'inbox.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  inbox = LeasedInbox.new
  case ARGV[0]
  when 'list' then puts JSON.pretty_generate(inbox.open_items)
  when 'ack' then puts JSON.pretty_generate(inbox.acknowledge(ARGV.fetch(1)))
  else warn 'usage: leased_inbox.rb list | ack <key>'
       exit 2
  end
end
