# frozen_string_literal: true

# Picks how cf:image handles text: :none (no text), :short (the model draws a
# few quoted words), or :heavy (a textless plate with HTML copy overlaid).
# Pure and deterministic: no I/O, so the table tests need nothing but Ruby.
module ImageTextMode
  MODES = %i[none short heavy].freeze
  SHORT_MAX_WORDS = 4
  SHORT_MAX_CHARS = 25
  BANNER_WORDS = /\b(banner|headline|cta|hero)s?\b/i
  # A double-quoted run, or a single-quoted run whose quotes sit outside words,
  # so the apostrophe in "don't" never opens or closes a run.
  QUOTED_RUN = /"([^"]{2,})"|(?<![[:alnum:]])'([^']{2,})'(?![[:alnum:]])/

  Result = Struct.new(:mode, :reason, :warnings, :runs, keyword_init: true)

  module_function

  def classify(prompt:, spec: nil, mode: nil)
    return explicit(mode) if mode
    return Result.new(mode: :heavy, reason: :spec, warnings: [], runs: []) if spec

    runs = quoted_runs(prompt.to_s)
    picked = pick(runs)
    Result.new(mode: picked, reason: :prompt, warnings: warnings_for(prompt.to_s, picked), runs: runs)
  end

  def quoted_runs(prompt)
    prompt.scan(QUOTED_RUN).map { |double, single| (double || single).strip }.reject(&:empty?)
  end

  def explicit(mode)
    sym = mode.to_s.strip.downcase.to_sym
    raise ArgumentError, "unknown text mode #{mode.inspect} (use none, short, or heavy)" unless MODES.include?(sym)

    Result.new(mode: sym, reason: :explicit, warnings: [], runs: [])
  end

  def pick(runs)
    return :none if runs.empty?
    return :short if runs.size == 1 && short?(runs.first)

    :heavy
  end

  def short?(run)
    run.split.size <= SHORT_MAX_WORDS && run.length <= SHORT_MAX_CHARS
  end

  def warnings_for(prompt, picked)
    return [] unless picked == :none && prompt.match?(BANNER_WORDS)

    [ 'prompt mentions banner copy but quotes no text; quote the words, pass --spec copy.json, or set --mode' ]
  end
end
