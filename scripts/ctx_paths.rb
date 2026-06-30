#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

# Resolves the .ctx store paths for a project, keyed by the absolute cwd with
# every slash turned to a dash. Devices key the store identically because they
# share one home, so a dashed cwd is byte-identical across them and a configured
# git remote lines up. This module is the single place that knows the keying
# rule, so the invariant lives in one spot; assert_home! guards it.
module CtxPaths
  # Doc classes, each its own subdirectory under the store. `archive` holds
  # compacted digests of purged docs and is not a live class.
  CLASSES = %w[truth active ephemeral].freeze
  ARCHIVE = 'archive'

  # The canonical home, pinned by install.rb (from the real home at install time)
  # into a file beside the installed scripts, so the repo carries no absolute user
  # path. Located via __dir__, the absolute install path baked into the hook
  # command, so a session launched with a wrong HOME still reads the real pin and
  # is caught. Absent (in the repo, in tests, before install) it falls back to the
  # running home, making the home-divergence check a no-op where nothing can
  # diverge. The dashed key stays stable across devices because each pins the same
  # shared home.
  HOME_PIN = File.join(__dir__, '.expected-home')

  class HomeMismatch < StandardError; end
  class NotAProject < StandardError; end

  def self.expected_home = File.file?(HOME_PIN) ? File.read(HOME_PIN).strip : Dir.home

  # Absolute cwd with every '/' replaced by '-'. '/srv/u/code/x' becomes
  # '-srv-u-code-x', matching the harness's own dashed-cwd memory keys.
  def self.dashed(cwd) = cwd.to_s.gsub('/', '-')

  def self.ctx_root(home = Dir.home) = File.join(home, '.claude', 'pst', 'ctx')

  def self.store_dir(cwd, home: Dir.home) = File.join(ctx_root(home), dashed(cwd))

  def self.index(cwd, home: Dir.home) = File.join(store_dir(cwd, home:), 'INDEX.md')

  def self.roadmap(cwd, home: Dir.home) = File.join(store_dir(cwd, home:), 'ROADMAP.md')

  def self.class_dir(klass, cwd, home: Dir.home) = File.join(store_dir(cwd, home:), klass.to_s)

  def self.meta(name, cwd, home: Dir.home) = File.join(store_dir(cwd, home:), '.ctx-meta', name.to_s)

  def self.klass?(klass) = CLASSES.include?(klass.to_s)

  # A project cwd must live under the canonical home. The store is keyed by the
  # cwd, so a cwd anywhere else (a system temp dir, an external volume) would mint
  # a junk store under the real ctx root, which it has during dogfooding. This is
  # the write-side twin of assert_home!: home guards which store, this guards
  # whether to key one at all. The home is not symlinked, so a prefix test needs
  # no realpath. Bare home is rejected: a store keys a project, not $HOME.
  def self.project_cwd?(cwd)
    cwd.to_s.start_with?("#{expected_home}/")
  end

  # Raised at the store-keying boundary (the CtxStore constructor) so no stray cwd
  # can create a store, whichever verb or caller reached it. Reads never construct
  # a store from a temp cwd in production, so this does not block them.
  def self.assert_project!(cwd)
    return true if project_cwd?(cwd)

    raise NotAProject, "ctx refuses a cwd outside #{expected_home}: #{cwd}"
  end

  # Raises unless the running home matches the pinned canonical home. Callers
  # (the SessionStart and prune hooks, the sync engine) catch this and degrade to
  # cache-only so a misconfigured device cannot silently key a divergent store.
  # `home` is injectable so the rule can be exercised in a test.
  def self.assert_home!(home = Dir.home)
    return true if home == expected_home

    raise HomeMismatch, "ctx keying expects HOME #{expected_home}, got #{home}"
  end
end
