# frozen_string_literal: true

require 'shellwords'
require_relative 'command'
require_relative 'inbox_items'
require_relative 'paths'
require_relative 'host_map'
require_relative 'snapshot'
require_relative '../leased_inbox'

module Triage
  # C3 write-back: `triage.rb answer <item-id> --text <answer> [--host <host>]`.
  # The mini is authoritative for decisions. An item that belongs to another
  # host is answered by running this same command there over SSH (bounded);
  # an item on this host's own leased inbox records the answer in the item's
  # data and acknowledges it, which resolves it.
  class Answer
    Result = Struct.new(:ok, :message, keyword_init: true)

    def initialize(inbox: LeasedInbox.new, root: Paths.root, host: Paths.host, runner: Command.method(:run),
                   ruby: 'ruby', remote_script: '$HOME/code/change-fabric/change-fabric/scripts/triage.rb')
      @inbox = inbox
      @root = root
      @host = host
      @runner = runner
      @ruby = ruby
      @remote_script = remote_script
    end

    def call(item_id, text, host: nil)
      return refuse('an answer needs --text') if text.to_s.strip.empty?
      return refuse('cf:inbox items are answered through cf:inbox, not triage') if item_id.start_with?('inbox:')

      host && host != @host ? remote(item_id, text, host) : local(item_id, text)
    end

    private

    def local(item_id, text)
      item = @inbox.fetch(item_id)
      return refuse("unknown item #{item_id}") unless item
      return refuse("#{item_id} is already resolved") if item['state'] == 'resolved'

      @inbox.upsert(kind: item['kind'], key: item_id, title: item['title'], body: item['body'].to_s,
                    data: item['data'].to_h.merge('answer' => text))
      @inbox.acknowledge(item_id, by: 'answer')
      Result.new(ok: true, message: "answered #{item_id}")
    end

    def remote(item_id, text, host)
      map = HostMap.load(Paths.hosts_file(@root))
      command = [ @ruby, "\"#{@remote_script}\"", 'answer', Shellwords.escape(item_id), '--text', Shellwords.escape(text) ].join(' ')
      argv = [ 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', map.ssh_target(host), command ]
      result = @runner.call(argv, Snapshot::PULL_TIMEOUT)
      return refuse("could not reach #{host}: #{result.err.to_s.strip[0, 120]}") unless result.ok

      Result.new(ok: true, message: "answered #{item_id} on #{host}")
    end

    def refuse(message) = Result.new(ok: false, message: message)
  end
end
