#!/usr/bin/env ruby
# frozen_string_literal: true

require 'shellwords'

# Shared "run git in a directory, return trimmed stdout or nil on any failure"
# helper. Extracted because contributors_team.rb and telemetry_emit.rb each
# shelled out to git with this exact backtick-plus-Shellwords-escape
# incantation; now it lives in one place.
module ShellGit
  module_function

  def run(dir, *args)
    return nil if dir.to_s.empty?

    out = `git -C #{Shellwords.escape(dir)} #{args.map { |a| Shellwords.escape(a) }.join(' ')} 2>/dev/null`
    return nil unless $?.success?

    out.strip
  rescue StandardError
    nil
  end
end
