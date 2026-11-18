#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'shellwords'
require 'open3'
require 'json'
require 'stringio'
require_relative 'roast'
require_relative 'roast_lens'

# cf:plan step 7b's lens policy. RoastLens names the candidates and why; this
# file adds the policy: cf:simplicity always, at most MAX_ROUTED routed lenses
# in a fixed rank order, and a budget procedure that debits every charged call
# at its upper bound. Advisory only: nothing here blocks a plan.
module PlanLenses
  ALWAYS = 'cf:simplicity'
  MAX_ROUTED = 3
  CAP_USD = 0.50
  # Rank ties after reason count: clouds, then security, then wcag, then name.
  KIND_ORDER = %w[cf:aws cf:gcp cf:azure cf:security cf:wcag].freeze
  # The cull: one host `claude -p` turn on haiku with every tool off, the
  # texts on stdin. It runs on the user's Claude Code subscription, so it is
  # not debited against CAP_USD.
  CULL_COMMAND = [ 'claude', '-p', '--model', 'haiku', '--max-turns', '1', '--tools', '' ].freeze
  CULL_PROMPT = 'Below are a plan, its goal, and candidate rubric lenses. Reply with only a JSON array ' \
                'of the candidate names (for example ["cf:aws"]) whose rubric clearly applies to this plan.'
  IMAGE = /\.(png|jpe?g|webp)\z/i
  PLAN_FILES = %w[plan.md goal.md].freeze

  module_function

  # [[name, reasons]] in rank order, cf:simplicity excluded. A reason that
  # only names plan.md or goal.md themselves is the input file, not the plan's
  # content, so it never makes a candidate on its own.
  def candidates(plan_dir:, repo: nil, skills_dir: RoastLens.dir)
    texts = PLAN_FILES.filter_map do |name|
      path = File.join(plan_dir, name)
      [ name, File.read(path) ] if File.file?(path)
    end
    found = RoastLens.suggest_with_reasons(texts, skills_dir, plan_text: true, repo: repo)
    found = found.to_h { |name, why| [ name, why - PLAN_FILES.map { |f| "path #{f}" } ] }
    rank(found.reject { |name, why| name == ALWAYS || why.empty? })
  end

  def rank(found)
    found.sort_by { |name, why| [ -why.size, KIND_ORDER.index(name) || KIND_ORDER.size, name ] }
  end

  # The routed lenses to send: kept names in rank order, capped.
  def final(ranked, keep)
    kept = keep.map { |k| "cf:#{RoastLens.bare(k)}" }
    ranked.map(&:first).select { |name| kept.include?(name) }.first(MAX_ROUTED)
  end

  def lens_flags(routed) = [ ALWAYS, *routed.first(MAX_ROUTED) ].flat_map { |name| [ '--lens', name ] }

  # Shrinks a roast call until its bound fits `remaining`: routed lenses go
  # lowest rank first, then images (dark, then light, then any other, each in
  # name order). Text inputs and cf:simplicity are never removed. Returns
  # { lenses:, inputs:, bound: } or :skip when the minimum payload is over.
  def fit(lenses:, inputs:, remaining:, bound:)
    lenses = lenses.dup
    inputs = inputs.dup
    loop do
      usd = bound.call(lenses, inputs)
      return { lenses: lenses, inputs: inputs, bound: usd } if usd <= remaining + 1e-12

      routed = lenses - [ ALWAYS ]
      if routed.any? then lenses.delete(routed.last)
      elsif (image = image_order(inputs).first) then inputs.delete(image)
      else return :skip
      end
    end
  end

  def image_order(inputs)
    images = inputs.grep(IMAGE)
    dark = images.select { |p| p.end_with?('-dark.png') }.sort_by { |p| File.basename(p) }
    light = images.select { |p| p.end_with?('-light.png') }.sort_by { |p| File.basename(p) }
    dark + light + (images - dark - light).sort_by { |p| File.basename(p) }
  end

  # Ceiling per image: roast.rb fits every shot to a 2048px long edge, and
  # this is twice the per-image figure Roast.estimate uses.
  IMAGE_BOUND_TOKENS = 2 * Roast::IMAGE_TOKENS

  # Upper bound for one roast round. Input is the complete request text
  # (system prompt, user text, response schema) at one token per byte, a
  # ceiling for byte-level tokenizers, plus IMAGE_BOUND_TOKENS per shot.
  # Output is the enforced cap plus the one automatic retry at
  # RETRY_OUTPUT_TOKENS, whose input is billed again.
  def roast_bound(inputs)
    tokens = input_bound_tokens(inputs)
    model = inputs[:model] || Roast::MODEL
    raw_usd(model, tokens, Roast::MAX_OUTPUT_TOKENS) + raw_usd(model, tokens, Roast::RETRY_OUTPUT_TOKENS)
  end

  def input_bound_tokens(inputs)
    text = Roast.user_text(inputs[:brief], inputs[:history] || [], inputs[:round] || 1, inputs[:shots] || [],
                           texts: inputs[:texts] || [], transcript: inputs[:transcript], review: inputs[:review], lenses: inputs[:lenses] || [])
    text.bytesize + Roast::SYSTEM_PROMPT.bytesize + JSON.generate(Roast::SCHEMA).bytesize + ((inputs[:shots] || []).size * IMAGE_BOUND_TOKENS)
  end

  def raw_usd(model, input, output)
    rates, = Roast.price_for(model)
    long = input > Roast::LONG_CONTEXT_TOKENS
    ((input * rates[:input] * (long ? 2 : 1)) + (output * rates[:output] * (long ? 1.5 : 1))) / 1_000_000.0
  end

  # A rubric's SKILL.md in the checkout layout (skills/aws) or the installed
  # one (~/.claude/skills/cf:aws).
  def skill_file(name, skills_dir)
    bare = RoastLens.bare(name)
    [ bare, "cf:#{bare}" ].map { |d| File.join(skills_dir, d, 'SKILL.md') }.find { |f| File.file?(f) }
  end

  # { kept:, note: }. kept is the cull's answer filtered to the candidates;
  # on a missing binary, a failed call or an unreadable answer, the cull is
  # skipped and the rule-based candidates apply under the cap.
  def cull(ranked, plan_dir:, skills_dir: RoastLens.dir, runner: method(:run_claude))
    names = ranked.map(&:first)
    input = cull_input(names, plan_dir, skills_dir)
    # Same scan roast.rb runs, but before anything leaves the machine.
    unless SensitiveTerms.matched([ input ], SensitiveTerms.load).empty?
      return { kept: names.first(MAX_ROUTED), note: 'plan lenses cull skipped (sensitive term matched; nothing sent); using rule-based candidates' }
    end

    stdout, ok, why = runner.call(CULL_COMMAND, input)
    picked = ok ? parse_cull(stdout) : nil
    return { kept: names & picked, note: nil } if picked

    { kept: names.first(MAX_ROUTED), note: "plan lenses cull skipped (#{why || 'unreadable answer'}); using rule-based candidates" }
  end

  def cull_input(names, plan_dir, skills_dir)
    parts = PLAN_FILES.map { |f| "== #{f}\n#{File.read(File.join(plan_dir, f)) if File.file?(File.join(plan_dir, f))}" }
    lenses = names.map { |n| "== candidate #{n}\n#{(f = skill_file(n, skills_dir)) ? File.read(f) : ''}" }
    [ CULL_PROMPT, *parts, *lenses ].join("\n\n")
  end

  def parse_cull(text)
    list = JSON.parse(text.to_s[/\[.*\]/m].to_s)
    list.is_a?(Array) ? list.map { |n| "cf:#{RoastLens.bare(n.is_a?(Hash) ? n['name'] : n)}" } : nil
  rescue JSON::ParserError
    nil
  end

  # [stdout, ok, reason]; never raises.
  def run_claude(command, input)
    return [ '', false, 'claude not on PATH' ] unless on_path?(command.first)

    stdout, _err, status = Open3.capture3(*command, stdin_data: input)
    [ stdout, status.success?, status.success? ? nil : "claude exited #{status.exitstatus}" ]
  rescue SystemCallError => e
    [ '', false, e.class.name ]
  end

  def on_path?(bin)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, bin)) }
  end

  # What a finished call costs the ledger: its reported usage, else its bound.
  def debit(bound:, reported: nil) = reported.nil? ? bound : reported

  def remaining(debits) = CAP_USD - debits.sum

  # Exit codes: 0 ok, 2 usage or missing plan.md, 3 roast skipped.
  module Cli
    module_function

    def run(argv, out: $stdout)
      args = argv.dup
      return fit(args, out) if args.first == 'fit' && args.shift

      list(args, out)
    rescue OptionParser::ParseError, Roast::UsageError, RoastLens::UnknownLens => e
      out.puts("error: #{e.message}")
      2
    end

    def list(args, out)
      opts = { keep: nil }
      OptionParser.new do |o|
        o.on('--plan-dir DIR') { |v| opts[:plan_dir] = v }
        o.on('--repo DIR') { |v| opts[:repo] = v }
        o.on('--keep LIST') { |v| opts[:keep] = v.split(',').map(&:strip) }
        o.on('--cull') { opts[:cull] = true }
      end.parse!(args)
      plan = File.join(opts[:plan_dir].to_s, 'plan.md')
      return missing(plan, out) unless File.file?(plan)

      ranked = PlanLenses.candidates(plan_dir: opts[:plan_dir], repo: opts[:repo])
      out.puts("plan lenses always: #{ALWAYS}")
      out.puts("plan lenses candidates: #{ranked.empty? ? '(none)' : ranked.map { |n, why| "#{n} (#{why.join('; ')})" }.join(', ')}")
      opts[:keep] = [] if opts[:cull]
      if opts[:cull] && !ranked.empty?
        result = PlanLenses.cull(ranked, plan_dir: opts[:plan_dir])
        out.puts(result[:note]) if result[:note]
        opts[:keep] = result[:kept]
      end
      out.puts("plan lenses final: #{PlanLenses.lens_flags(PlanLenses.final(ranked, opts[:keep])).join(' ')}") if opts[:keep]
      0
    end

    def missing(plan, out)
      out.puts("error: #{plan} not found")
      2
    end

    # fit --remaining USD [--keep a,b,c] -- <roast.rb args>
    def fit(args, out)
      split = args.index('--')
      roast_args = split ? args[(split + 1)..] : []
      opts = { keep: [] }
      OptionParser.new do |o|
        o.on('--remaining USD', Float) { |v| opts[:remaining] = v }
        o.on('--keep LIST') { |v| opts[:keep] = v.split(',').map(&:strip) }
      end.parse!(split ? args[0...split] : args)
      raise OptionParser::MissingArgument, '--remaining' unless opts[:remaining]

      base = strip_lenses(roast_args)
      routed = opts[:keep].map { |k| "cf:#{RoastLens.bare(k)}" }.uniq.first(MAX_ROUTED)
      result = PlanLenses.fit(lenses: [ ALWAYS, *routed ], inputs: shots(base), remaining: opts[:remaining],
                              bound: ->(lenses, kept) { PlanLenses.roast_bound(inputs_for(base, lenses, kept)) })
      return skipped(out) if result == :skip

      flags = [ *PlanLenses.lens_flags(result[:lenses] - [ ALWAYS ]), *without_shots(base, result[:inputs]) ]
      out.puts("plan lenses fit: #{Shellwords.join(flags)}")
      out.puts(format('plan lenses bound: $%.4f of $%.4f remaining', result[:bound], opts[:remaining]))
      0
    end

    def skipped(out)
      out.puts('roast skipped')
      3
    end

    def strip_lenses(args)
      args.each_with_index.reject { |a, i| a == '--lens' || (i.positive? && args[i - 1] == '--lens') }.map(&:first)
    end

    def shots(args) = args.each_cons(2).select { |flag, _| flag == '--shot' }.map(&:last)

    def without_shots(args, kept)
      out = []
      args.each_with_index do |a, i|
        next if a == '--shot' && !kept.include?(args[i + 1])
        next if i.positive? && args[i - 1] == '--shot' && !kept.include?(a)

        out << a
      end
      out
    end

    # The same inputs roast.rb would build, with these lenses and shots.
    def inputs_for(base, lenses, kept)
      args = [ *without_shots(base, kept), *lenses.flat_map { |l| [ '--lens', l ] } ]
      opts = Roast::Cli.parse(args)
      Roast::Cli.inputs_for(opts, StringIO.new)
    end
  end
end

exit(PlanLenses::Cli.run(ARGV)) if $PROGRAM_NAME == __FILE__
