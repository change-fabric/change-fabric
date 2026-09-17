#!/usr/bin/env ruby
# frozen_string_literal: true

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
# may live anywhere, which is exactly how the live instance works.
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

  def self.default_root(cwd, home: Dir.home)
    assert_project!(cwd, home: home)
    File.join(home, '.claude', 'cf', 'inbox', dashed(cwd))
  end

  # Reads inbox_root: straight out of CHANGE.md's frontmatter at the repo
  # root (== cwd here). Fail-soft: any read or parse trouble, or an absent /
  # blank key, yields nil so the caller falls through to the default.
  def self.change_md_root(cwd, home: Dir.home)
    front = ChangeFrontmatter.parse_file(File.join(cwd, 'CHANGE.md'))
    raw = front['inbox_root']
    return nil if raw.to_s.strip.empty?

    expand(raw.to_s.strip, cwd, home)
  rescue StandardError
    nil
  end

  def self.expand(raw, cwd, home)
    return File.join(home, raw.delete_prefix('~/')) if raw.start_with?('~/')
    return home if raw == '~'
    return raw if raw.start_with?('/')

    File.expand_path(raw, cwd)
  end

  # Returns the rule that fired: "env" | "change_md" | "default".
  def self.root_source(cwd: Dir.pwd, home: Dir.home)
    return 'env' if env_root
    return 'change_md' unless change_md_root(cwd, home: home).nil?

    'default'
  end

  def self.env_root
    value = ENV['INBOX_ROOT']
    value && !value.strip.empty? ? value : nil
  end

  def self.root(cwd: Dir.pwd, home: Dir.home)
    return env_root if env_root

    from_change_md = change_md_root(cwd, home: home)
    return from_change_md if from_change_md

    default_root(cwd, home: home)
  end
end
