#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "digest"
require "optparse"
require_relative "design_config"
require_relative "design_parity"

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
  PROVENANCE_SECTIONS = [
    "Principles", "Tokens", "Typography", "Spacing and layout", "Themes",
    "Accessibility commitments", "Components", "Do and do not"
  ].freeze

  PROVENANCE_TAG = /\[(?:evidence: (?:figma:[A-Za-z0-9]+#[0-9]+[:-][0-9]+|[^\]\s#]+#[^\]\s]+)|assumption|proposal)\]/
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

      heading_name(line)
    end
  end

  def heading_name(line) = line[/\A##\s+(.+?)\s*\z/, 1]

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

      if (name = heading_name(line))
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

  # AA failures and audit errors in a color_check report, as findings. A
  # token error means the audit did not run (or rejected the tokens), so it
  # must fail the lint rather than read as a clean contrast pass.
  def contrast_findings(report)
    errors = Array(report["token_errors"]).map do |e|
      Finding.new("contrast", e["line"], "contrast audit error: #{e['message']}")
    end
    fails = Array(report["contrast"]).select { |c| c["status"] == "fail" }.map do |c|
      Finding.new("contrast", nil, "#{c['variant']}: #{c['fg']} on #{c['bg']} is #{c['ratio']} (#{c['reason']})")
    end
    errors + fails
  end

  def lint(design_md, tokens_css)
    misses = verbatim_check(design_md, tokens_css).map do |decl|
      Finding.new("verbatim", nil, "not in tokens.css: #{decl}")
    end
    required_sections(design_md) + misses + provenance_lint(design_md)
  end

  # Token drift: tokens.css is the only canon. Every other source (screens
  # copies, the storyboard hash, compiled Tailwind properties, a Figma
  # variables snapshot) is compared against it and never written back to.
  # Custom properties are read by the same line-level declaration scan lint
  # uses; any compile goes through color_compile.rb. No CSS parser here.
  module Drift
    module_function

    PROPERTY = /(--[A-Za-z][\w-]*)\s*:\s*([^;{}]+?)\s*(?:;|(?=\}))/
    DEFAULT_SCREENS = "screens"
    DEFAULT_STORYBOARD = "storyboard.json"

    DriftFinding = Struct.new(:source, :token, :expected, :actual, :severity, :message, :parity, :reason) do
      def to_h
        { source: source, token: token, expected: expected, actual: actual, severity: severity, message: message,
          parity: parity, reason: reason }
      end
      def mismatch? = severity == "error"

      def to_s
        detail = token ? "#{token}: expected #{expected.inspect}, got #{actual.inspect}" : message
        tag = parity ? " [#{parity}#{reason ? ": #{reason}" : ''}]" : ""
        "#{severity}: #{source}: #{detail}#{tag}"
      end
    end

    # Custom property name => value, last declaration wins, comments blanked.
    def properties(css)
      text = css.to_s.dup.force_encoding(Encoding::UTF_8).scrub.gsub(%r{/\*.*?\*/}m, " ")
      text.scan(PROPERTY).to_h { |name, value| [ name, value.strip ] }
    end

    # Whitespace and case only; a value that differs beyond that is drift.
    def normalize(value) = value.to_s.strip.gsub(/\s+/, " ").downcase

    def info(source, message) = DriftFinding.new(source, nil, nil, nil, "info", message)

    def compare_properties(source, canon, other, only_shared: false)
      names = only_shared ? (canon.keys & other.keys) : (canon.keys | other.keys)
      names.filter_map do |name|
        expected = canon[name]
        actual = other[name]
        next if expected && actual && normalize(expected) == normalize(actual)

        copy_mismatch(source, name, expected, actual)
      end
    end

    # A mismatch against a copy of canon: always must_match, always an error.
    def copy_mismatch(source, token, expected, actual, message = nil)
      c = DesignParity::CANON_COPY
      DriftFinding.new(source, token, expected, actual, c.severity, message, c.status, c.reason)
    end

    # A Figma mismatch: severity follows the area's parity status.
    def figma_mismatch(area, token, expected, actual, parity)
      c = DesignParity.classify(area, parity)
      DriftFinding.new("figma", token, expected, actual, c.severity, nil, c.status, c.reason)
    end

    def screens(canon_bytes, screens_dir)
      copies = screens_dir && Dir.exist?(screens_dir) ? Dir.glob(File.join(screens_dir, "**", "tokens.css")).sort : []
      return [ info("screens", "no screens/tokens.css copies found; skipped") ] if copies.empty?

      canon_sha = Digest::SHA256.hexdigest(canon_bytes)
      copies.flat_map do |copy|
        bytes = File.binread(copy)
        next [] if Digest::SHA256.hexdigest(bytes) == canon_sha

        props = compare_properties(copy, properties(canon_bytes), properties(bytes))
        props.empty? ? [ copy_mismatch(copy, nil, canon_sha, Digest::SHA256.hexdigest(bytes), "bytes differ from tokens.css") ] : props
      end
    end

    def storyboard(canon_bytes, path)
      return [ info("storyboard", "no storyboard at #{path}; skipped") ] unless path && File.exist?(path)

      recorded = JSON.parse(File.read(path))["tokens_css_sha256"]
      return [ info("storyboard", "#{path} has no tokens_css_sha256; skipped") ] if recorded.nil?

      expected = Digest::SHA256.hexdigest(canon_bytes)
      recorded == expected ? [] : [ copy_mismatch(path, "tokens_css_sha256", expected, recorded) ]
    rescue JSON::ParserError => e
      [ info("storyboard", "#{path} is not JSON (#{e.message[0, 80]}); skipped") ]
    end

    # compiler is ColorCompile.read(root, path) or a stub returning an object
    # with css and error.
    def tailwind(canon_bytes, root, input, compiler)
      return [ info("tailwind", "no Tailwind input at #{input}; skipped") ] unless input && File.exist?(input)

      result = compiler.call(root, input)
      return [ info("tailwind", "compile failed, skipped: #{result.error}") ] if result.error

      compare_properties("tailwind", properties(canon_bytes), properties(result.css), only_shared: true)
    end

    # parity responds to parity_default and parity_areas; nil means defaults.
    # A variable's area is its "area" field, else its Figma name.
    def figma(canon_bytes, path, parity = nil)
      return [ info("figma", "no Figma snapshot at #{path}; skipped") ] unless path && File.exist?(path)

      canon = properties(canon_bytes)
      Array(JSON.parse(File.read(path))["variables"]).flat_map do |var|
        token = var["token"]
        next [ info("figma", "variable #{var['name']} maps to no token") ] if token.to_s.empty?
        next [] if canon.key?(token) && normalize(canon[token]) == normalize(var["value"])

        [ figma_mismatch(var["area"] || var["name"], token, canon[token], var["value"], parity) ]
      end
    rescue JSON::ParserError => e
      [ info("figma", "#{path} is not JSON (#{e.message[0, 80]}); skipped") ]
    end

    def default_compiler
      lambda do |root, path|
        require_relative "color_compile"
        ColorCompile.read(File.expand_path(root), File.expand_path(path))
      end
    end

    # opts: tokens, screens, storyboard, figma_snapshot, tailwind (true/false/nil),
    # tailwind_input, root, parity (a DesignConfig::Config; nil means defaults).
    def run(opts, compiler: default_compiler)
      canon = File.binread(opts.fetch(:tokens))
      findings = screens(canon, opts[:screens]) + storyboard(canon, opts[:storyboard])
      if opts[:tailwind] == false
        findings << info("tailwind", "disabled; skipped")
      else
        findings += tailwind(canon, opts[:root], opts[:tailwind_input] || opts[:tokens], compiler)
      end
      findings + figma(canon, opts[:figma_snapshot], opts[:parity])
    end
  end

  module CLI
    module_function

    USAGE = "usage: design_tokens.rb lint DESIGN.md tokens.css [--json] [--contrast]"

    DRIFT_USAGE = "usage: design_tokens.rb drift [--root DIR] [--tokens PATH] [--screens DIR] [--storyboard PATH] " \
                  "[--figma-snapshot PATH] [--tailwind|--no-tailwind] [--json]"

    def run(argv, out: $stdout, err: $stderr, compiler: nil)
      return drift(argv.drop(1), out: out, err: err, compiler: compiler) if argv.first == "drift"

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

    def drift(argv, out:, err:, compiler: nil)
      opts = parse_drift(argv)
      unless opts && File.exist?(opts[:tokens])
        err.puts(opts ? "tokens.css not found: #{opts[:tokens]}" : DRIFT_USAGE)
        return 2
      end
      findings = compiler ? Drift.run(opts, compiler: compiler) : Drift.run(opts)
      if opts[:json]
        out.puts JSON.generate(tokens: opts[:tokens], findings: findings.map(&:to_h))
      else
        findings.each { |f| out.puts f }
        warnings = findings.count { |f| f.severity == "warning" }
        summary = findings.any?(&:mismatch?) ? "#{findings.count(&:mismatch?)} mismatch(es)" : "no drift"
        out.puts(warnings.zero? ? summary : "#{summary}, #{warnings} unreviewed warning(s)")
      end
      findings.any?(&:mismatch?) ? 1 : 0
    rescue DesignConfig::Error => e
      err.puts "CHANGE.md design block: #{e.message}"
      2
    end

    def parse_drift(argv)
      opts = {}
      OptionParser.new do |o|
        o.on("--root DIR") { |v| opts[:root] = v }
        o.on("--tokens PATH") { |v| opts[:tokens] = v }
        o.on("--screens DIR") { |v| opts[:screens] = v }
        o.on("--storyboard PATH") { |v| opts[:storyboard] = v }
        o.on("--figma-snapshot PATH") { |v| opts[:figma_snapshot] = v }
        o.on("--[no-]tailwind") { |v| opts[:tailwind] = v }
        o.on("--json") { opts[:json] = true }
      end.parse!(argv.dup).then { |rest| return nil unless rest.empty? }
      fill_drift_defaults(opts)
    rescue OptionParser::ParseError
      nil
    end

    def fill_drift_defaults(opts)
      root = opts[:root] ||= Dir.pwd
      config = DesignConfig.load(root)
      opts[:parity] ||= config
      opts[:tailwind] = config.tailwind unless opts.key?(:tailwind)
      opts[:tokens] ||= File.join(root, config.tokens)
      opts[:screens] ||= File.join(root, Drift::DEFAULT_SCREENS)
      opts[:storyboard] ||= File.join(root, Drift::DEFAULT_STORYBOARD)
      opts[:figma_snapshot] ||= File.join(root, config.variables_snapshot)
      opts
    end
  end
end

exit DesignTokens::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
