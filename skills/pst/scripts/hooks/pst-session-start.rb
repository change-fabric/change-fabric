#!/usr/bin/env ruby
# frozen_string_literal: true
# PST SessionStart hook: expose the current session id to later Bash tool calls
# by appending CLAUDE_SESSION_ID to the harness env file, so /pst can arm itself.
require_relative 'pst_common'

sid = Pst.session_id
env = ENV['CLAUDE_ENV_FILE']
File.open(env, 'a') { |f| f.puts "CLAUDE_SESSION_ID=#{sid}" } if env && !env.empty? && !sid.empty?
