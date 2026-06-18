#!/usr/bin/env ruby
# frozen_string_literal: true
# Record or check an adversarial-review marker for a commit (rule 7 review gate,
# enforced by the merge guard). Run `mark` after completing /pst:adversarial-review
# or /pst:code-review for a PR so the merge guard will allow the merge.
#
#   pst-reviewed.rb mark [sha]    record review for sha (default: git HEAD)
#   pst-reviewed.rb check [sha]   exit 0 if recorded, 1 if not
require 'fileutils'

DIR = File.expand_path('~/.claude/pst/reviewed')

def head_sha
  `git rev-parse HEAD 2>/dev/null`.strip
end

mode = ARGV[0]
sha = ARGV[1].to_s.empty? ? head_sha : ARGV[1]
abort 'usage: pst-reviewed.rb {mark|check} [sha]' if mode.nil? || sha.empty?

path = File.join(DIR, sha)
case mode
when 'mark'
  FileUtils.mkdir_p(DIR)
  FileUtils.touch(path)
  puts "recorded review for #{sha[0, 12]}"
when 'check'
  exit(File.exist?(path) ? 0 : 1)
else
  abort 'usage: pst-reviewed.rb {mark|check} [sha]'
end
