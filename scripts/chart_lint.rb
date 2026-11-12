#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "diagram_svg"
require_relative "diagram_measure"
require_relative "diagram_palette"
require_relative "chart_checks"

# Blocking lint gate for cf:chart SVGs, the same CLI shape as
# diagram_lint.rb. Runs every shared SvgChecks check plus the ChartChecks.
# Exit 0 means no errors, 1 means at least one error, 2 means a usage, read,
# or parse problem, and 3 means measurement needed Docker or browserless and
# neither was available.
#
#   ruby chart_lint.rb [--json] [--no-measure] [--spec chart.json] [--palette tokens.css] PATH [PATH...]
class ChartLint
  class UsageError < StandardError; end

  def initialize(measurer:, checks: ChartChecks.all, palette: ChartPalette.hexes, spec: nil)
    @measurer = measurer
    @checks = checks
    @palette = palette
    @spec = spec
  end

  def lint_file(path, doc = parse(path))
    type = doc.attr("data-chart-type")
    context = ChartChecks::Context.new(type: type, widths: @measurer.widths(doc), measured: @measurer.measured?,
                                       palette: @palette, spec: @spec)
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
    SvgChecks.report(docs.map { |p, d| lint_file(p, d) }, measured: @measurer.measured?)
  end

  def self.expand(paths)
    raise UsageError, "no PATH given" if paths.empty?

    paths.flat_map do |p|
      next Dir.glob(File.join(p, "*.svg")).sort if File.directory?(p)
      raise UsageError, "cannot read #{p}" unless File.file?(p) && File.readable?(p)

      [ p ]
    end
  end

  # The token file's literals and roles, plus the series and ramp colors a
  # chart derives from those roles.
  def self.palette_from(file)
    raise UsageError, "cannot read palette #{file}" unless File.file?(file)

    literals = File.read(file).scan(/#\h{6}\b|#\h{3}\b/)
    derived = begin
      r = DiagramPalette.resolve(file)
      r.hexes + ChartPalette.hexes(light: r.light, dark: r.dark)
    rescue DiagramPalette::Error
      []
    end
    (literals + derived).uniq
  end

  def self.spec_from(file)
    raise UsageError, "cannot read spec #{file}" unless File.file?(file)

    JSON.parse(File.read(file))
  rescue JSON::ParserError => e
    raise UsageError, "spec #{file} is not JSON: #{e.message.lines.first.to_s.strip}"
  end

  def self.human(report)
    report[:files].flat_map do |f|
      f[:findings].map { |x| "#{f[:path]}:#{x[:check]}:#{x[:severity]}: #{x[:message]} (#{x[:element]})" }
    end
  end

  def self.parse_args(argv)
    opts = { json: false, palette: ChartPalette.hexes, spec: nil }
    rest = OptionParser.new do |o|
      o.on("--json") { opts[:json] = true }
      o.on("--no-measure") { opts[:no_measure] = true }
      o.on("--spec FILE") { |f| opts[:spec] = spec_from(f) }
      o.on("--palette FILE") { |f| opts[:palette] = palette_from(f) }
    end.parse(argv)
    [ opts, expand(rest) ]
  rescue OptionParser::ParseError => e
    raise UsageError, e.message
  end

  def self.main(argv, out: $stdout, err: $stderr, measurer: nil)
    opts, paths = parse_args(argv)
    measurer ||= opts[:no_measure] ? DiagramMeasure::Static.new : DiagramMeasure::Browserless.new
    report = new(measurer: measurer, palette: opts[:palette], spec: opts[:spec]).report(paths)
    opts[:json] ? out.puts(JSON.pretty_generate(report)) : human(report).each { |line| out.puts(line) }
    SvgChecks.exit_code(report)
  rescue DiagramMeasure::Unavailable => e
    err.puts("chart_lint: #{e.message}; retry with --no-measure")
    SvgChecks::EXIT_UNMEASURED
  rescue UsageError, DiagramMeasure::TooLarge, DiagramSvg::ParseError, SystemCallError => e
    err.puts("chart_lint: #{e.message}")
    SvgChecks::EXIT_USAGE
  rescue StandardError => e
    err.puts("chart_lint: unexpected #{e.class}: #{e.message}")
    SvgChecks::EXIT_USAGE
  end
end

exit(ChartLint.main(ARGV)) if $PROGRAM_NAME == __FILE__
