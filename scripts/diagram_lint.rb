#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "diagram_svg"
require_relative "diagram_checks"
require_relative "diagram_measure"

# Blocking lint gate for cf:diagram SVGs. Parses each file, asks an injected
# measurer for text sizes, runs the DiagramChecks list, and reports findings
# as human lines or JSON. Exit 0 means no errors, 1 means at least one error,
# 2 means a usage, read, or parse problem, and 3 means measurement needed
# Docker or browserless and neither was available.
#
#   ruby diagram_lint.rb [--json] [--no-measure] [--type TYPE] [--palette tokens.css] PATH [PATH...]
# Orchestrates parsing, measurement, and the checks for a set of files.
class DiagramLint
  NOTICE = DiagramChecks::NOTICE

  class UsageError < StandardError; end

  def initialize(measurer:, checks: DiagramChecks.all, type: nil, palette: DiagramChecks::DEFAULT_PALETTE)
    @measurer = measurer
    @checks = checks
    @type = type
    @palette = palette
  end

  def lint_file(path, doc = parse(path))
    type = @type || doc.attr("data-diagram-type")
    context = DiagramChecks::Context.new(type: type, widths: @measurer.widths(doc), measured: @measurer.measured?, palette: @palette)
    { path: path, type: type, findings: @checks.flat_map { |c| c.call(doc, context) } }
  end

  def parse(path)
    DiagramSvg::Document.new(File.read(path))
  rescue DiagramSvg::ParseError => e
    raise DiagramSvg::ParseError, "#{path}: #{e.message}"
  end

  def report(paths)
    docs = paths.map { |p| [ p, parse(p) ] }
    @measurer.prefetch(docs.map(&:last)) if @measurer.respond_to?(:prefetch)
    files = docs.map { |p, d| lint_file(p, d) }
    all = files.flat_map { |f| f[:findings] }
    {
      version: 1,
      measured: @measurer.measured?,
      files: files.map { |f| f.merge(findings: f[:findings].map(&:to_h)) },
      summary: { files: files.size, errors: all.count { |f| f.severity == "error" }, warnings: all.count { |f| f.severity == "warn" } }
    }
  end

  def self.expand(paths)
    raise UsageError, "no PATH given" if paths.empty?

    paths.flat_map do |p|
      next Dir.glob(File.join(p, "*.svg")).sort if File.directory?(p)
      raise UsageError, "cannot read #{p}" unless File.file?(p) && File.readable?(p)

      [ p ]
    end
  end

  def self.palette_from(file)
    raise UsageError, "cannot read palette #{file}" unless File.file?(file)

    File.read(file).scan(/#\h{6}\b|#\h{3}\b/).uniq
  end

  def self.human(report)
    report[:files].flat_map do |f|
      f[:findings].map { |x| "#{f[:path]}:#{x[:check]}:#{x[:severity]}: #{x[:message]} (#{x[:element]})" }
    end
  end

  def self.parse_args(argv)
    opts = { json: false, type: nil, palette: DiagramChecks::DEFAULT_PALETTE }
    rest = OptionParser.new do |o|
      o.on("--json") { opts[:json] = true }
      o.on("--no-measure") { opts[:no_measure] = true }
      o.on("--type TYPE") { |t| opts[:type] = t }
      o.on("--palette FILE") { |f| opts[:palette] = palette_from(f) }
    end.parse(argv)
    [ opts, expand(rest) ]
  rescue OptionParser::ParseError => e
    raise UsageError, e.message
  end

  def self.main(argv, out: $stdout, err: $stderr, measurer: nil)
    opts, paths = parse_args(argv)
    measurer ||= opts[:no_measure] ? DiagramMeasure::Static.new : DiagramMeasure::Browserless.new
    report = new(measurer: measurer, type: opts[:type], palette: opts[:palette]).report(paths)
    opts[:json] ? out.puts(JSON.pretty_generate(report)) : human(report).each { |line| out.puts(line) }
    report[:summary][:errors].positive? ? 1 : 0
  rescue DiagramMeasure::Unavailable => e
    err.puts("diagram_lint: #{e.message}; retry with --no-measure")
    3
  rescue UsageError, DiagramMeasure::TooLarge, DiagramSvg::ParseError, SystemCallError => e
    err.puts("diagram_lint: #{e.message}")
    2
  rescue StandardError => e
    err.puts("diagram_lint: unexpected #{e.class}: #{e.message}")
    2
  end
end

exit(DiagramLint.main(ARGV)) if $PROGRAM_NAME == __FILE__
