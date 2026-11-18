#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'shellwords'
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
  # The haiku cull's rates per million tokens and its output cap.
  CULL_RATES = { input: 1.0, output: 5.0 }.freeze
  CULL_OUTPUT_TOKENS = 2000
  CULL_PROMPT = 'Return a JSON list of the candidate rubric lenses that clearly apply to this plan, ' \
                'each with a one-line reason. Drop any whose rubric does not apply.'
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

  # Upper bound for one roast round: full input priced at the call's model,
  # plus the enforced output cap, plus the one automatic retry roast.rb may
  # make at RETRY_OUTPUT_TOKENS (its input billed again).
  def roast_bound(inputs)
    tokens = Roast.estimate(**inputs.slice(:brief, :shots, :history, :texts, :transcript, :review, :lenses, :model))[:tokens]
    model = inputs[:model] || Roast::MODEL
    raw_usd(model, tokens, Roast::MAX_OUTPUT_TOKENS) + raw_usd(model, tokens, Roast::RETRY_OUTPUT_TOKENS)
  end

  def raw_usd(model, input, output)
    rates, = Roast.price_for(model)
    long = input > Roast::LONG_CONTEXT_TOKENS
    ((input * rates[:input] * (long ? 2 : 1)) + (output * rates[:output] * (long ? 1.5 : 1))) / 1_000_000.0
  end

  # Upper bound for the haiku cull: the prompt, the plan files and every
  # candidate SKILL.md, counted as Roast.estimate counts chars, plus its cap.
  def cull_bound(candidates:, files:, skills_dir: RoastLens.dir)
    skills = candidates.filter_map { |name| skill_file(name, skills_dir) }
    chars = CULL_PROMPT.size + [ *files, *skills ].sum { |f| File.file?(f) ? File.size(f) : 0 }
    ((chars / 4 * CULL_RATES[:input]) + (CULL_OUTPUT_TOKENS * CULL_RATES[:output])) / 1_000_000.0
  end

  # A rubric's SKILL.md in the checkout layout (skills/aws) or the installed
  # one (~/.claude/skills/cf:aws).
  def skill_file(name, skills_dir)
    bare = RoastLens.bare(name)
    [ bare, "cf:#{bare}" ].map { |d| File.join(skills_dir, d, 'SKILL.md') }.find { |f| File.file?(f) }
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
      end.parse!(args)
      plan = File.join(opts[:plan_dir].to_s, 'plan.md')
      return missing(plan, out) unless File.file?(plan)

      ranked = PlanLenses.candidates(plan_dir: opts[:plan_dir], repo: opts[:repo])
      out.puts("plan lenses always: #{ALWAYS}")
      out.puts("plan lenses candidates: #{ranked.empty? ? '(none)' : ranked.map { |n, why| "#{n} (#{why.join('; ')})" }.join(', ')}")
      unless ranked.empty?
        files = PLAN_FILES.map { |f| File.join(opts[:plan_dir], f) }
        out.puts(format('plan lenses cull bound: $%.4f', PlanLenses.cull_bound(candidates: ranked.map(&:first), files: files)))
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
