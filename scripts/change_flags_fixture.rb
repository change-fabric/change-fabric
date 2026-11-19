#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'change_flags_protocol'

# The `kind: fixture` cf.flags/1 adapter. It keeps one JSON state file per
# adapter (default: under the system temp dir), applies requests through
# ChangeFlagsProtocol.apply, and is what tests and dogfood dry runs use. It
# holds no credentials and never touches a real flag service.
#
# With `known:` set, a flag outside that list answers `unknown_flag`;
# otherwise a flag springs into existence (off) on first touch.
class ChangeFlagsFixture
  def self.default_path = File.join(Dir.tmpdir, 'cf-flags-fixture.json')

  def initialize(path = self.class.default_path, known: nil)
    @path = path
    @known = known
  end

  # One request hash in, one reply hash out. State is persisted per flag and env.
  def call(request)
    return ChangeFlagsProtocol.apply(ChangeFlagsProtocol.initial_state, request).first unless request.is_a?(Hash) && ChangeFlagsProtocol.request_errors(request).empty?

    key = "#{request['flag']}@#{request['env']}"
    return unknown(request) if @known && !@known.include?(request['flag'])

    store = load_store
    reply, store[key] = ChangeFlagsProtocol.apply(store[key] || ChangeFlagsProtocol.initial_state, request)
    save_store(store)
    reply
  end

  # Test hook: simulate an adapter outage for one flag and env.
  def set_outage(flag, env, down)
    key = "#{flag}@#{env}"
    store = load_store
    store[key] = (store[key] || ChangeFlagsProtocol.initial_state).merge('outage' => down)
    save_store(store)
  end

  private

  def unknown(request)
    reply = ChangeFlagsProtocol.reply_for(ChangeFlagsProtocol.initial_state, request,
                                          error: ChangeFlagsProtocol.error('unknown_flag', "#{request['flag']} is not a known flag"))
    reply
  end

  def load_store
    File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
  rescue JSON::ParserError
    {}
  end

  def save_store(store)
    FileUtils.mkdir_p(File.dirname(@path))
    tmp = "#{@path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.pretty_generate(store))
    File.rename(tmp, @path)
  end
end

if $PROGRAM_NAME == __FILE__
  # As a standalone adapter: one request on stdin, one reply on stdout.
  request = begin
    JSON.parse($stdin.read)
  rescue JSON::ParserError
    nil
  end
  puts JSON.generate(ChangeFlagsFixture.new(ENV.fetch('CF_FLAGS_FIXTURE_PATH', ChangeFlagsFixture.default_path)).call(request))
end
