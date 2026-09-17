#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require_relative 'change_frontmatter'

# Resolves the inbox root for a project, mirroring CtxPaths' keying so the two
# stores stay consistent. Three-step order, first hit wins (never merged):
#
#   1. ENV["INBOX_ROOT"], the existing testability seam and documented
#      one-off override.
#   2. inbox_root: from <repo root>/CHANGE.md frontmatter, read directly
#      through ChangeFrontmatter (never ChangeConfig, so a malformed
#      change_config: block cannot block inbox resolution). A leading "~/"
#      expands against home; a relative path resolves against the repo root.
#   3. The shim default: ~/.claude/cf/inbox/<dashed-cwd>, byte-identical
#      keying to CtxPaths.dashed.
#
# The HOME_PIN invariant (copied from CtxPaths) applies only to case 3: an
# explicitly configured root (cases 1 and 2) is a deliberate human choice and
# may live anywhere, which is exactly how the live instance works. Every home
# default is the pinned expected_home, not the running Dir.home, so a session
# launched with a divergent HOME still validates the cwd against, and keys the
# default root under, the home the install was pinned to. The kwarg stays
# injectable for tests.
module InboxPaths
  HOME_PIN = File.join(__dir__, '.expected-home')

  class NotAProject < StandardError; end

  def self.expected_home = File.file?(HOME_PIN) ? File.read(HOME_PIN).strip : Dir.home

  # Absolute cwd with every '/' replaced by '-', byte-identical to
  # CtxPaths.dashed so the two stores key the same way.
  def self.dashed(cwd) = cwd.to_s.gsub('/', '-')

  def self.project_cwd?(cwd, home: expected_home)
    cwd.to_s.start_with?("#{home}/")
  end

  def self.assert_project!(cwd, home: expected_home)
    return true if project_cwd?(cwd, home: home)

    raise NotAProject, "inbox refuses a cwd outside #{home}: #{cwd}"
  end

  def self.default_root(cwd, home: expected_home)
    assert_project!(cwd, home: home)
    File.join(home, '.claude', 'cf', 'inbox', dashed(cwd))
  end

  # Walks upward from cwd looking for a CHANGE.md, so a nested working
  # directory (a subpackage, a hook invoked from deeper in the tree) still
  # finds the repo-root file instead of silently missing it. Stops at the
  # first directory that has one, or returns nil once it reaches the
  # filesystem root without finding one.
  def self.find_change_md_root(cwd)
    dir = File.expand_path(cwd)
    loop do
      return dir if File.file?(File.join(dir, 'CHANGE.md'))

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  end

  # Reads inbox_root: straight out of CHANGE.md's frontmatter, walking up
  # from cwd to find the repo root first so a nested cwd resolves the same
  # root as the repo root itself. A relative path expands against that same
  # root. Fail-soft: any read or parse trouble, or an absent / blank key,
  # yields nil so the caller falls through to the default.
  def self.change_md_root(cwd, home: expected_home)
    root = find_change_md_root(cwd) or return nil
    front = ChangeFrontmatter.parse_file(File.join(root, 'CHANGE.md'))
    raw = front['inbox_root']
    return nil if raw.to_s.strip.empty?

    expand(raw.to_s.strip, root, home)
  rescue StandardError
    nil
  end

  def self.expand(raw, cwd, home)
    return File.join(home, raw.delete_prefix('~/')) if raw.start_with?('~/')
    return home if raw == '~'
    return raw if raw.start_with?('/')

    File.expand_path(raw, cwd)
  end

  def self.env_root
    value = ENV['INBOX_ROOT']
    value && !value.strip.empty? ? value : nil
  end

  # The single three-step precedence check, first hit wins: env, then
  # CHANGE.md, then the shim default. root and root_source both read it
  # rather than re-running the precedence chain independently, so the two
  # can never disagree about which rule fired.
  def self.resolve(cwd: Dir.pwd, home: expected_home)
    return [ env_root, 'env' ] if env_root

    from_change_md = change_md_root(cwd, home: home)
    return [ from_change_md, 'change_md' ] if from_change_md

    [ default_root(cwd, home: home), 'default' ]
  end

  def self.root(cwd: Dir.pwd, home: expected_home) = resolve(cwd: cwd, home: home).first

  def self.root_source(cwd: Dir.pwd, home: expected_home) = resolve(cwd: cwd, home: home).last

  # Shared by InboxStore and InboxRoster, both of which require this file
  # already. Write-then-rename so a reader never observes a half-written file.
  def self.write_atomically(target, content)
    FileUtils.mkdir_p(File.dirname(target))
    tmp = "#{target}.tmp"
    File.write(tmp, content)
    File.rename(tmp, target)
  end
end
