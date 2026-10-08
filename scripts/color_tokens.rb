#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'color_css'
require_relative 'color_value'

# Reads the one token file that declares a repo's palette, strictly, per the
# "Token file" grammar in skills/color/SKILL.md. Anything outside the
# grammar is an Error with a line number and the construct named; nothing is
# guessed and no cascade is modelled. Never raises.
module ColorTokens
  # Conventional token-file locations, relative to the scan root, in order.
  PATHS = %w[
    app/globals.css
    src/app/globals.css
    app/styles/tokens.css
    src/styles/tokens.css
    styles/tokens.css
    src/styles/globals.css
    styles/globals.css
    src/index.css
    app/assets/stylesheets/tokens.css
    tokens.css
  ].freeze

  # The foreground suffixes of the fixed pair rule: "--x-<suffix>" pairs with
  # "--x" when declared, else with "--background".
  FG_SUFFIXES = %w[text fg foreground ink].freeze
  FG_NAME = /\A--(.+)-(?:#{FG_SUFFIXES.join('|')})\z/.freeze
  PAGE_BACKGROUND = '--background'
  ERROR_TOKEN = '--error'
  TARGET = 4

  # Block-less statements a Tailwind entry file needs; skipped silently.
  SKIPPED_STATEMENTS = %w[@import @charset @tailwind @source @plugin @custom-variant @config].freeze
  MEDIA_SCHEME = /\A@media\s*\(\s*prefers-color-scheme\s*:\s*(light|dark)\s*\)\z/i.freeze
  DARK_ATTR = /\A\[data-theme=(?:dark|"dark"|'dark')\]\z/.freeze
  SELECTOR_HINT = 'only :root and the dark spellings are allowed'

  # line is nil for an error about locating the file rather than its contents.
  Error = Data.define(:line, :message)
  # variants: {light: {name => value}, dark: {name => value}}, dark being
  # light merged with the dark overrides. dark?: whether any dark block was
  # declared. authored: [{value:, names:}] distinct authored colors, --error
  # excluded. derived: count of var()/color-mix() declarations.
  Result = Data.define(:path, :variants, :errors, :dark, :authored, :derived, :error_token) do
    def dark? = dark
  end

  module_function

  # The token file path, or an Error naming every candidate when zero or
  # several conventional paths exist. An override is returned as given.
  def locate(root, override)
    return override if override

    found = PATHS.map { |rel| File.join(root, rel) }.select { |p| File.file?(p) }
    return found.first if found.size == 1

    if found.empty?
      Error.new(line: nil, message: "no token file found; looked for #{PATHS.join(', ')} (or pass --tokens)")
    else
      Error.new(line: nil, message: "several token files found: #{found.join(', ')}; pass --tokens to pick one")
    end
  end

  def read(path)
    text = File.read(path, encoding: 'UTF-8')
    Reader.new(path, ColorCss.parse(text)).result
  rescue StandardError => e
    empty_result(path, [ Error.new(line: nil, message: "cannot read token file #{path}: #{e.class}") ])
  end

  def empty_result(path, errors)
    Result.new(path:, variants: { light: {}, dark: {} }, errors:, dark: false, authored: [], derived: 0,
               error_token: false)
  end

  # [[fg, bg]] for every "--x-<suffix>" token, per the fixed pair rule.
  def pairs(tokens)
    tokens.each_key.filter_map do |name|
      m = FG_NAME.match(name)
      next unless m

      surface = "--#{m[1]}"
      [ name, tokens.key?(surface) ? surface : PAGE_BACKGROUND ]
    end
  end

  # One pass over a parsed sheet: classify every block, then every
  # declaration and statement by the block it sits in.
  class Reader
    def initialize(path, sheet)
      @path = path
      @sheet = sheet
      @errors = sheet.errors.map { |e| Error.new(line: e[/line (\d+)/, 1]&.to_i, message: e) }
      @kinds = {}
      @light = {}
      @dark = {}
      @dark_seen = false
      @layer_seen = false
    end

    def result
      sheet.blocks.each { |b| @kinds[b.id] = classify(b) }
      sheet.at_rule_stmts.each { |s| check_statement(s) }
      sheet.decls.each { |d| record(d) }
      check_dark_names
      authored, derived, error_token = palette
      check_palette_size(authored)
      Result.new(path: @path, variants: { light: @light.transform_values { |v| v[:value] },
                                          dark: dark_tokens },
                 errors: @errors.sort_by { |e| e.line || 0 }, dark: @dark_seen, authored:, derived:, error_token:)
    end

    private

    attr_reader :sheet

    def error(line, message)
      @errors << Error.new(line:, message:)
      :error
    end

    # A block's kind: :layer, :media_light, :media_dark (containers), :light,
    # :dark (token blocks), :error, or :skip (inside an errored block).
    def classify(block)
      parent = block.parent && @kinds[block.parent]
      return :skip if %i[error skip].include?(parent)

      prelude = block.prelude.gsub(/\s+/, ' ')
      if %i[light dark].include?(parent)
        return error(block.line, "nested block `#{prelude}` inside a token block; only --name: value is allowed")
      end

      prelude.start_with?('@') ? classify_at_rule(block, prelude, parent) : classify_rule(block, prelude, parent)
    end

    def classify_at_rule(block, prelude, parent)
      name = prelude[/\A@[\w-]+/].to_s.downcase
      case name
      when '@layer'
        return top_layer(block, prelude) if parent.nil?

        error(block.line, "nested `#{prelude}`; only one @layer wrapper is allowed")
      when '@media'
        m = MEDIA_SCHEME.match(prelude)
        unless m && !%i[media_light media_dark].include?(parent)
          return error(block.line, "`#{prelude}` is not a token block; only prefers-color-scheme media is allowed")
        end

        m[1].downcase == 'dark' ? :media_dark : :media_light
      when '@theme'
        return :light if parent.nil? || parent == :layer

        error(block.line, "`#{prelude}` is only allowed at top level")
      else
        error(block.line, "`#{name}` is not allowed in a token file")
      end
    end

    TOP_LAYER_PRELUDE = /\A@layer(?:\s+([\w-]+(?:\.[\w-]+)*))?\s*\z/.freeze

    def top_layer(block, prelude)
      return error(block.line, "second `#{prelude}`; only one @layer wrapper is allowed") if @layer_seen
      unless TOP_LAYER_PRELUDE.match?(prelude)
        return error(block.line, "`#{prelude}` is not a valid @layer wrapper; use `@layer` or a single layer name")
      end

      @layer_seen = true
      :layer
    end

    def classify_rule(block, prelude, parent)
      members = ColorCss.split_top_level(block.prelude).map(&:strip)
      variants = members.map { |sel| selector_variant(sel) }
      if (bad = members.zip(variants).find { |_, v| v.nil? })
        return error(block.line, "selector `#{bad[0].gsub(/\s+/, ' ')}` is not a token block; #{SELECTOR_HINT}")
      end
      if variants.uniq.size > 1
        return error(block.line, "selector list `#{prelude}` mixes light and dark; one variant per block")
      end

      in_media(block, prelude, parent, variants.first)
    end

    def in_media(block, prelude, parent, variant)
      return variant unless %i[media_light media_dark].include?(parent)
      return parent == :media_dark ? :dark : :light if prelude == ':root'

      error(block.line, "selector `#{prelude}` inside prefers-color-scheme media; only :root is allowed there")
    end

    # :light, :dark or nil for one selector-list member, read off its token
    # stream: a whitespace or >+~ combinator at top level is never accepted.
    def selector_variant(selector)
      return nil if combinator?(selector)

      compound = selector.gsub(/\s+/, '')
      return :light if compound.casecmp?(':root')

      rest = compound.sub(/\A:root/i, '')
      :dark if rest == '.dark' || rest.match?(DARK_ATTR)
    end

    def combinator?(selector)
      depth = 0
      quote = nil
      selector.each_char do |ch|
        if quote
          quote = nil if ch == quote
          next
        end
        case ch
        when '"', "'" then quote = ch
        when '[', '(' then depth += 1
        when ']', ')' then depth -= 1
        when /[\s>+~]/ then return true if depth.zero?
        end
      end
      false
    end

    def check_statement(stmt)
      kind = stmt.block_id && @kinds[stmt.block_id]
      return if %i[error skip].include?(kind)
      return if (kind.nil? || kind == :layer) && SKIPPED_STATEMENTS.include?(stmt.name.downcase)

      text = [ stmt.name, stmt.prelude ].reject(&:empty?).join(' ')
      error(stmt.line, "`#{text}` is not allowed in a token file; only --name: value")
    end

    def record(decl)
      kind = decl.block_id && @kinds[decl.block_id]
      return if %i[error skip].include?(kind)
      unless %i[light dark].include?(kind)
        return error(decl.line, "declaration `#{decl.name}` outside a token block")
      end
      unless decl.name.start_with?('--')
        return error(decl.line, "property `#{decl.name}` is not allowed in a token block; only --name: value")
      end

      store(kind == :light ? @light : @dark, kind, decl)
    end

    def store(table, kind, decl)
      @dark_seen = true if kind == :dark
      prior = table[decl.name]
      if prior && normalize(prior[:value]) != normalize(decl.value)
        return error(decl.line, "`#{decl.name}` is declared twice in #{kind} with different values " \
                                "(line #{prior[:line]}: #{prior[:value]}; here: #{decl.value})")
      end

      table[decl.name] ||= { value: decl.value, line: decl.line }
    end

    def check_dark_names
      @dark.each do |name, entry|
        next if @light.key?(name)

        error(entry[:line], "`#{name}` is declared in dark but not in light; dark may only redefine light names")
      end
    end

    def dark_tokens
      @light.merge(@dark.slice(*@light.keys)).transform_values { |v| v[:value] }
    end

    def palette
      authored = {}
      derived = 0
      error_token = false
      first_error_value = nil
      (@light.to_a + @dark.to_a).each do |name, entry|
        value = entry[:value]
        if name == ERROR_TOKEN
          error_token = true
          norm = color_key(value)
          first_error_value ||= norm
          next if norm == first_error_value
        end

        if authored?(value)
          slot = (authored[color_key(value)] ||= { value: value.strip, names: [], line: entry[:line] })
          slot[:names] << name unless slot[:names].include?(name)
        elsif value.match?(/\b(?:color-mix|var)\(/i)
          derived += 1
        end
      end
      [ authored.values, derived, error_token ]
    end

    def check_palette_size(authored)
      return if authored.size <= TARGET

      error(authored[TARGET][:line], "palette has #{authored.size} authored colors; target is #{TARGET} plus optional #{ERROR_TOKEN}")
    end

    # Hex, rgb()/rgba(), hsl()/hsla() and named colors that the resolver
    # actually turns into a color. Anything it reports unresolved (oklch(),
    # calc() or `none` channels, malformed arguments) is left to contrast,
    # so it never counts toward the palette.
    def authored?(value)
      ColorValue.literal?(value) && !ColorValue.resolve(value, {}).color.nil?
    end

    # Equivalent spellings (#fff, white, rgb(255 255 255)) share one key:
    # the resolved RGBA when the value is a literal, else its normalized text.
    def color_key(value)
      color = authored?(value) && ColorValue.resolve(value, {}).color
      return normalize(value) unless color

      [ color.r.round, color.g.round, color.b.round, color.a ]
    end

    # Case-folds everything but custom-property names, which CSS treats as
    # case-sensitive: var(--Ink) and var(--ink) are different references.
    def normalize(value)
      value.strip.gsub(/\s+/, ' ').gsub(/--[\w-]+|[^-]+|-/) { |t| t.start_with?('--') ? t : t.downcase }
    end
  end
end
