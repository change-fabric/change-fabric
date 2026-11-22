#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'pathname'
require_relative 'change_suite'

# `change_run.rb testcases --changed [<base-ref>]`: pick the cases a diff can
# affect, so a pull request runs the part of the suite it could have broken.
#
# The rules err toward running more, never fewer:
# - a case with no `covers` always runs (it never said what it depends on);
# - an edit to a suite file selects every case in that suite;
# - a changed path matching one of a case's `covers` globs selects that case;
# - `strict` runs every case when any case in scope lacks `covers`.
#
# Nothing here reads the environment. Every value that reaches a message (a
# base ref, a path) goes through `clip`, so a long or hostile string cannot
# flood a log or report.
module ChangeCaseSelection
  class Error < StandardError; end

  Result = Struct.new(:cases, :reasons, :changed_count, keyword_init: true) do
    def reason(item) = reasons[item.qualified_id]
  end

  CLIP = 80
  GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

  module_function

  # A value fit for a log line or finding: control characters gone, truncated.
  def clip(value, max = CLIP)
    text = value.to_s.gsub(/[[:cntrl:]]/, ' ')
    text.length > max ? "#{text[0, max]}..." : text
  end

  # Repo-relative paths changed between `base` and HEAD (`base...HEAD`).
  def changed_paths(base, repo)
    ref = base.to_s
    raise Error, "--changed base #{clip(ref).inspect} is not a usable ref" if ref.empty? || ref.start_with?('-')

    _, status = Open3.capture2e('git', '-C', repo, 'rev-parse', '--verify', '--quiet', "#{ref}^{commit}")
    raise Error, "--changed base #{clip(ref).inspect} does not resolve to a commit" unless status.success?

    out, status = Open3.capture2('git', '-C', repo, 'diff', '--name-only', '--no-renames', '-z', "#{ref}...HEAD", '--')
    raise Error, "git diff against #{clip(ref).inspect} failed" unless status.success?

    out.split("\0").reject(&:empty?)
  end

  def select(set, paths, repo:, strict: false)
    cases = set.cases
    strict_all = strict && cases.any? { |item| item.covers.nil? }
    edited = edited_suites(set, paths, repo)
    reasons = cases.to_h do |item|
      [ item.qualified_id, strict_all ? 'strict: a case lacks covers' : reason_for(item, paths, edited) ]
    end.compact
    picked = cases.select { |item| reasons.key?(item.qualified_id) }
    Result.new(cases: picked, reasons: reasons, changed_count: paths.size)
  end

  def reason_for(item, paths, edited)
    return 'no covers (always runs)' if item.covers.nil?
    return 'suite file changed' if edited.include?(item.suite)

    glob = item.covers.find { |pattern| paths.any? { |path| covered?(pattern, path) } }
    "covers #{clip(glob, 60)}" if glob
  end

  def covered?(pattern, path)
    # `dir/**` means everything beneath dir, which `dir/**/*` matches.
    pattern = "#{pattern}/*" if pattern.end_with?('/**')
    File.fnmatch?(pattern, path, GLOB_FLAGS)
  end

  # Names of suites whose own file is among the changed paths.
  def edited_suites(set, paths, repo)
    root = Pathname.new(File.realpath(repo))
    set.suites.filter_map do |suite|
      relative = Pathname.new(File.realpath(suite.path)).relative_path_from(root).to_s
      suite.name if paths.include?(relative)
    end
  end

  # One log line per selected case, capped so a large diff stays readable.
  def summary(result, total, base, cap: 20)
    lines = [ "[change] --changed #{clip(base).inspect}: #{result.cases.size} of #{total} case(s) selected " \
              "from #{result.changed_count} changed path(s)" ]
    result.cases.first(cap).each { |item| lines << "[change]   #{clip(item.qualified_id, 100)}: #{result.reason(item)}" }
    lines << "[change]   ... #{result.cases.size - cap} more" if result.cases.size > cap
    lines
  end
  private_class_method :reason_for, :covered?, :edited_suites
end
