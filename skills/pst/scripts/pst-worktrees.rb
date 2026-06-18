#!/usr/bin/env ruby
# frozen_string_literal: true
# Deterministically list git worktrees that are likely prunable: branch merged
# into the default branch, or tracked upstream gone. Read-only, never prunes.
# Rule 3 uses this so "prompt before pruning" fires reliably instead of relying
# on the model noticing.
#
#   pst-worktrees.rb [repo_dir]   (defaults to cwd)
#
# Exit 0 with a list (or "no prunable worktrees"); exit 2 if not a git repo.
require 'open3'

repo = ARGV[0] || Dir.pwd

def sh(*argv, dir:)
  out, st = Open3.capture2e(*argv, chdir: dir)
  [out, st.success?]
end

list, ok = sh('git', 'worktree', 'list', '--porcelain', dir: repo)
unless ok
  warn "not a git repo (or git error): #{repo}"
  exit 2
end

head, = sh('git', 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD', dir: repo)
default = head.strip.sub(%r{^origin/}, '')
default = 'main' if default.empty?

main_path, = sh('git', 'rev-parse', '--show-toplevel', dir: repo)
main_path = main_path.strip

merged_out, = sh('git', 'branch', '--merged', default, dir: repo)
merged = merged_out.lines.map { |l| l.delete('*').strip }
vv, = sh('git', 'branch', '-vv', dir: repo)
gone = vv.lines.select { |l| l.include?(': gone]') }
         .map { |l| l.delete('*').strip.split(/\s+/).first }

worktrees = []
cur = {}
list.each_line do |raw|
  line = raw.strip
  if line.empty?
    worktrees << cur unless cur.empty?
    cur = {}
  elsif line.start_with?('worktree ')
    cur[:path] = line.sub('worktree ', '')
  elsif line.start_with?('branch ')
    cur[:branch] = line.sub('branch ', '').sub(%r{^refs/heads/}, '')
  elsif line == 'detached'
    cur[:detached] = true
  end
end
worktrees << cur unless cur.empty?

prunable = []
worktrees.each do |w|
  next unless w[:path]
  next if w[:path] == main_path

  reason =
    if w[:detached] then 'detached HEAD'
    elsif w[:branch].nil? then 'no branch'
    elsif merged.include?(w[:branch]) then "branch '#{w[:branch]}' merged into #{default}"
    elsif gone.include?(w[:branch]) then "branch '#{w[:branch]}' upstream gone"
    end
  prunable << "#{w[:path]}  (#{reason})" if reason
end

if prunable.empty?
  puts 'no prunable worktrees'
else
  puts "prunable worktrees (#{prunable.size}):"
  prunable.each { |p| puts "  #{p}" }
end
