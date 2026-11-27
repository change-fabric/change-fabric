#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'

# A pass marker per git tree, so a tree whose full suite already ran green is
# not run again by the pre-commit hook or the stage 1 push gate.
#
# The key is the tree hash plus the Ruby build and the tree's Gemfile.lock
# blob: the pre-commit hook passes the staged tree (`git write-tree`), the push
# gate the pushed commit's tree. The working directory never enters the key,
# so an unstaged edit cannot borrow a pass. A marker is written only after a
# full green run whose working tree held exactly that tree (see clean?).
#
#   ruby scripts/suite_pass_cache.rb hit TREE      exit 0 on a pass, 1 otherwise
#   ruby scripts/suite_pass_cache.rb record TREE   writes the marker if clean
module SuitePassCache
  DEFAULT_DIR = File.join(Dir.home, '.claude', 'cf', 'state', 'suite-pass')

  module_function

  def dir = ENV.fetch('CF_SUITE_PASS_DIR', DEFAULT_DIR)

  def key(root, tree)
    lock = git(root, 'rev-parse', "#{tree}:Gemfile.lock") || 'none'
    Digest::SHA256.hexdigest([ tree, RUBY_DESCRIPTION, lock ].join("\n"))
  end

  def hit?(root, tree)
    return false unless tree_id?(tree)

    File.file?(File.join(dir, key(root, tree)))
  end

  # Records a pass for `tree` only when the working directory the suite just
  # ran in matched it exactly: no tracked change against the tree and no
  # untracked file. Returns true when a marker was written.
  def record(root, tree)
    return false unless tree_id?(tree) && clean?(root, tree)

    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, key(root, tree)), "#{tree}\n")
    true
  end

  def clean?(root, tree)
    tracked = system('git', '-C', root, 'diff', '--quiet', tree, '--', out: File::NULL, err: File::NULL)
    tracked && git(root, 'ls-files', '--others', '--exclude-standard').to_s.empty?
  end

  def tree_id?(tree) = tree.to_s.match?(/\A\h{40,64}\z/)

  def git(root, *args)
    out, status = Open3.capture2e('git', '-C', root, *args)
    status.success? ? out.strip : nil
  rescue SystemCallError
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  action, tree = ARGV
  root = Dir.pwd
  case action
  when 'hit' then exit(SuitePassCache.hit?(root, tree) ? 0 : 1)
  when 'record' then exit(SuitePassCache.record(root, tree) ? 0 : 1)
  else
    warn 'usage: suite_pass_cache.rb hit|record TREE'
    exit 2
  end
end
