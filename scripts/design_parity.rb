#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "design_config"

# Per-area parity for cf:design drift. An area (a route, a component name, or
# a named area label) is classified against change_config.design.parity.areas
# in order: the first glob that matches wins, otherwise parity.default. Status
# maps to severity: must_match is an error, intentional is info carrying its
# recorded reason, unreviewed is a warning that never fails.
module DesignParity
  STATUSES = %w[must_match intentional unreviewed].freeze
  SEVERITY = { "must_match" => "error", "intentional" => "info", "unreviewed" => "warning" }.freeze
  FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

  Result = Data.define(:status, :reason) do
    def severity = DesignParity.severity(status)
  end

  # Copies of canon (screens copies, storyboard hash, compiled Tailwind) are not
  # design choices, so they are always must_match.
  CANON_COPY = Result.new(status: "must_match", reason: "copy of tokens.css canon")

  module_function

  # config responds to parity_default and parity_areas (DesignConfig::Config);
  # nil means the DesignConfig defaults.
  def classify(finding_area, config = nil)
    config ||= DesignConfig.from_hash(nil)
    area = finding_area.to_s
    rule = Array(config.parity_areas).find { |a| matches?(a.match, area) }
    return Result.new(status: rule.status, reason: rule.reason) if rule

    Result.new(status: config.parity_default, reason: nil)
  end

  def matches?(pattern, area)
    return false if area.empty? || pattern.to_s.empty?

    File.fnmatch(pattern.to_s, area, FNMATCH_FLAGS) || (!area.start_with?("/") && File.fnmatch(pattern.to_s, area))
  end

  def severity(status)
    SEVERITY.fetch(status) { raise ArgumentError, "unknown parity status: #{status.inspect}" }
  end
end
