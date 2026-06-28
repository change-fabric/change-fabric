#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

# Resolves the .ctx store paths for a project, keyed by the absolute cwd with
# every slash turned to a dash. Both Macs key the store identically because both
# run under /Users/pst, so a dashed cwd is byte-identical across devices and the
# NAS git remote lines up. This module is the single place that knows the keying
# rule, so the invariant lives in one spot; assert_home! guards it.
module CtxPaths
  # Both devices share this home, so the dashed key is stable across them. A
  # divergent home would silently key a separate store and desync, which is why
  # assert_home! is loud rather than best-effort.
  EXPECTED_HOME = '/Users/pst'

  # Doc classes, each its own subdirectory under the store. `archive` holds
  # compacted digests of purged docs and is not a live class.
  CLASSES = %w[truth active ephemeral].freeze
  ARCHIVE = 'archive'

  class HomeMismatch < StandardError; end

  # Absolute cwd with every '/' replaced by '-'. '/Users/pst/code/x' becomes
  # '-Users-pst-code-x', matching the harness's own dashed-cwd memory keys.
  def self.dashed(cwd) = cwd.to_s.gsub('/', '-')

  def self.ctx_root(home = Dir.home) = File.join(home, '.claude', 'pst', 'ctx')

  def self.store_dir(cwd, home: Dir.home) = File.join(ctx_root(home), dashed(cwd))

  def self.index(cwd, home: Dir.home) = File.join(store_dir(cwd, home:), 'INDEX.md')

  def self.roadmap(cwd, home: Dir.home) = File.join(store_dir(cwd, home:), 'ROADMAP.md')

  def self.class_dir(klass, cwd, home: Dir.home) = File.join(store_dir(cwd, home:), klass.to_s)

  def self.meta(name, cwd, home: Dir.home) = File.join(store_dir(cwd, home:), '.ctx-meta', name.to_s)

  def self.klass?(klass) = CLASSES.include?(klass.to_s)

  # Raises unless the running home matches the one both devices share. Callers
  # (the SessionStart and prune hooks, the sync engine) catch this and degrade to
  # cache-only so a misconfigured device cannot silently key a divergent store.
  # `home` is injectable so the rule can be exercised in a test.
  def self.assert_home!(home = Dir.home)
    return true if home == EXPECTED_HOME

    raise HomeMismatch, "ctx keying expects HOME #{EXPECTED_HOME}, got #{home}"
  end
end
