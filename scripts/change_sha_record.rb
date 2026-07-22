#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

# Shared file-backed-by-(sha[, profile]) storage for change-fabric's two
# cross-session records: ChangeGateStore (a run's pass/fail) and
# ChangeOverrideStore (a human-authorized merge-gate override). Both need the
# same key scoping (a record for one profile's head must never satisfy a
# different profile or a later commit, so the key itself expires the moment
# the head SHA moves) and the same fail-soft JSON read/write; only the
# payload shape and the accessor each store exposes differ.
class ChangeShaRecord
  def initialize(sha, profile: nil)
    @sha = sha.to_s
    @profile = profile.to_s.empty? ? nil : profile.to_s
  end

  def read
    return nil unless recordable? && File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    nil
  end

  private

  def recordable? = !@sha.empty?

  def write(payload)
    return unless recordable?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload))
  end

  def path
    File.join(Dir.home, '.claude', 'pst', 'change', "#{@profile ? "#{@sha}__#{@profile}" : @sha}#{extension}")
  end

  # Subclasses override when more than one kind of record can exist for the
  # same (sha, profile) and must not collide on the same path.
  def extension = ''
end
