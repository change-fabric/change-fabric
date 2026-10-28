#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# Lints a DESIGN.md against its companion tokens.css for cf:design. Ruby never
# parses CSS here: the css fences are found by a markdown fence scan, the
# verbatim check is a plain line-inclusion test, and contrast is delegated to
# color_check.rb, whose Chromium oracle is the only CSS parser in the toolkit.
module DesignTokens
  module_function

  REQUIRED_SECTIONS = [
    "Problem and users",
    "Principles",
    "Tokens",
    "Typography",
    "Spacing and layout",
    "Themes",
    "Accessibility commitments",
    "Components",
    "Do and do not",
    "Open questions"
  ].freeze

  # Sections whose every content line must carry a provenance tag.
  PROVENANCE_SECTIONS = REQUIRED_SECTIONS[1..8].freeze

  PROVENANCE_TAG = /\[(?:evidence: [^\]\s#]+#[^\]\s]+|assumption|proposal)\]/
  DECLARATION = /\A--?[A-Za-z][\w-]*\s*:/
  FENCE = /\A\s*(```|~~~)/
  COLOR_CHECK = File.expand_path("color_check.rb", __dir__)

  Finding = Struct.new(:kind, :line, :message) do
    def to_h = { kind: kind, line: line, message: message }
    def to_s = line ? "#{kind}: line #{line}: #{message}" : "#{kind}: #{message}"
  end

  # Bodies of every ```css fence in the markdown, in order.
  def css_fences(design_md)
    blocks = []
    current = nil
    design_md.each_line do |raw|
      line = raw.chomp
      if current
        if line.strip.start_with?("```")
          blocks << current.join("\n")
          current = nil
        else
          current << line
        end
      elsif line.strip.match?(/\A```css\s*\z/)
        current = []
      end
    end
    blocks
  end

  # Declaration lines inside css fences that do not appear verbatim in tokens.css.
  def verbatim_check(design_md, tokens_css)
    css_fences(design_md)
      .flat_map { |block| block.lines.map(&:strip) }
      .grep(DECLARATION)
      .reject { |decl| tokens_css.include?(decl) }
      .uniq
  end

  # Level-two heading names present in the doc.
  def sections(design_md)
    in_fence = false
    design_md.each_line.filter_map do |line|
      in_fence = !in_fence if line.match?(FENCE)
      next if in_fence

      line[/\A##\s+(.+?)\s*\z/, 1]
    end
  end

  def required_sections(design_md)
    present = sections(design_md)
    (REQUIRED_SECTIONS - present).map { |name| Finding.new("section", nil, "missing section: ## #{name}") }
  end

  # Content lines in Principles through Do and do not that carry no provenance tag.
  def provenance_lint(design_md)
    lines = design_md.lines.map(&:chomp)
    findings = []
    section = nil
    in_fence = false
    lines.each_with_index do |line, idx|
      if line.match?(FENCE)
        in_fence = !in_fence
        next
      end
      next if in_fence

      if (name = line[/\A##\s+(.+?)\s*\z/, 1])
        section = name
        next
      end
      next unless PROVENANCE_SECTIONS.include?(section)
      next if exempt?(line, lines[idx + 1])
      next if line.match?(PROVENANCE_TAG)

      findings << Finding.new("provenance", idx + 1, "untagged line in #{section}: #{line.strip[0, 60]}")
    end
    findings
  end

  def exempt?(line, next_line)
    stripped = line.strip
    return true if stripped.empty?
    return true if stripped.start_with?("#")
    return true if table_separator?(stripped)

    stripped.start_with?("|") && next_line && table_separator?(next_line.strip)
  end

  def table_separator?(stripped)
    stripped.start_with?("|") && stripped.match?(/\A\|[\s:|-]+\|?\z/) && stripped.include?("-")
  end

  def contrast_argv(tokens_path, bin: COLOR_CHECK)
    [ RbConfig.ruby, bin, "--tokens", tokens_path, "--json" ]
  end

  # Runs color_check.rb (Chromium via docker) and returns its parsed JSON report.
  # The runner is injectable so tests never shell out.
  def contrast(tokens_path, bin: COLOR_CHECK, runner: ->(argv) { Open3.capture3(*argv) })
    stdout, stderr, = runner.call(contrast_argv(tokens_path, bin: bin))
    JSON.parse(stdout)
  rescue JSON::ParserError
    raise "color_check.rb produced no JSON report: #{stderr.to_s.strip[0, 200]}"
  end

  # AA failures in a color_check report, as findings.
  def contrast_findings(report)
    Array(report["contrast"]).select { |c| c["status"] == "fail" }.map do |c|
      Finding.new("contrast", nil, "#{c['variant']}: #{c['fg']} on #{c['bg']} is #{c['ratio']} (#{c['reason']})")
    end
  end

  def lint(design_md, tokens_css)
    misses = verbatim_check(design_md, tokens_css).map do |decl|
      Finding.new("verbatim", nil, "not in tokens.css: #{decl}")
    end
    required_sections(design_md) + misses + provenance_lint(design_md)
  end

  module CLI
    module_function

    USAGE = "usage: design_tokens.rb lint DESIGN.md tokens.css [--json] [--contrast]"

    def run(argv, out: $stdout, err: $stderr)
      command, design, tokens, *flags = argv
      unless command == "lint" && design && tokens && (flags - %w[--json --contrast]).empty?
        err.puts USAGE
        return 2
      end
      findings = DesignTokens.lint(File.read(design), File.read(tokens))
      findings += DesignTokens.contrast_findings(DesignTokens.contrast(tokens)) if flags.include?("--contrast")
      if flags.include?("--json")
        out.puts JSON.generate(findings: findings.map(&:to_h))
      else
        findings.each { |f| out.puts f }
        out.puts(findings.empty? ? "clean" : "#{findings.size} finding(s)")
      end
      findings.empty? ? 0 : 1
    end
  end
end

exit DesignTokens::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
