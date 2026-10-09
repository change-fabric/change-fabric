#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'color_css'
require_relative 'color_value'

# Reads the one token file that declares a repo's palette, strictly, per the
# "Token file" grammar in skills/color/SKILL.md. Anything outside the
# grammar is an Error with a line number and the construct named; nothing is
# guessed. The only cascade modelled is the CSS Cascade 5 sort between a
# light and a dark declaration of one name: !important, then layer origin,
# then selector specificity, then source order. Never raises.
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
  DERIVED_FUNCTIONS = %w[var color-mix].freeze

  # Block-less statements a Tailwind entry file needs; skipped silently.
  SKIPPED_STATEMENTS = %w[@import @charset @tailwind @source @plugin @custom-variant @config].freeze
  # Matched against an ASCII-lowercased prelude, never with /i: Ruby's /i
  # folds Unicode (U+212A KELVIN SIGN to k, U+017F LONG S to s), while CSS
  # keywords are ASCII case-insensitive only.
  MEDIA_SCHEME = /\A@media#{ColorCss::WS_SRC}*\(#{ColorCss::WS_SRC}*prefers-color-scheme#{ColorCss::WS_SRC}*:#{ColorCss::WS_SRC}*(light|dark)#{ColorCss::WS_SRC}*\)\z/.freeze
  # Matched against canonical_selector's output: the attribute name is ASCII
  # case-insensitive, the value (a class name or string) is not. Spelled
  # per letter, never (?i:), which folds U+212A and U+017F as well.
  DARK_ATTR = /\A\[[dD][aA][tT][aA]-[tT][hH][eE][mM][eE]=(?:dark|"dark")\]\z/.freeze
  SELECTOR_HINT = 'only :root and the dark spellings are allowed'
  # An @theme block compiles to `:root, :host`: one pseudo-class.
  THEME_SPECIFICITY = [ 0, 1, 0 ].freeze
  # The independent ways a dark block activates, as the error names them.
  MECHANISMS = { media: "prefers-color-scheme media", class: ".dark class",
                 attribute: "data-theme attribute" }.freeze

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
      @light_plain = {}
      @light_media = Set.new
      @dark = {}
      @dark_seen = false
      @layer_seen = false
      @theme_seen = false
      @theme_id = nil
      @theme_default_line = nil
      @theme_names = []
      @import_lines = []
      @theme_reset_all = false
      @layers = {}
      @layer_of = {}
      @specificity = {}
      @mechanisms = {}
      @dark_by = Hash.new { |h, k| h[k] = {} }
    end

    def result
      sheet.blocks.each { |b| @kinds[b.id] = classify(b) }
      sheet.at_rule_stmts.each { |s| check_statement(s) }
      sheet.decls.each_with_index { |d, order| record(d, order) }
      check_theme_default
      check_dark_names
      check_light_media_names
      dark = dark_tokens
      authored, derived, error_token = palette
      check_palette_size(authored)
      Result.new(path: @path, variants: { light: @light.transform_values { |v| v[:value] }, dark: },
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
      @layer_of[block.id] = @layer_of[block.parent] if block.parent
      parent = block.parent && @kinds[block.parent]
      return :skip if %i[error skip].include?(parent)

      prelude = block.prelude.gsub(ColorCss::WS_RUN, ' ')
      if %i[light dark].include?(parent)
        return error(block.line, "nested block `#{prelude}` inside a token block; only --name: value is allowed")
      end

      unglued(block, prelude) do
        prelude.start_with?('@') ? classify_at_rule(block, prelude, parent) : classify_rule(block, prelude, parent)
      end
    end

    # A comment between two tokens is a boundary that reads as whitespace,
    # and the prelude already carries that space (@layer/**/base is
    # "@layer base"). When that reading is not a token block either, the
    # comment split one token (@la/**/yer, :ro/**/ot), so the error says so
    # instead of naming the split halves.
    def unglued(block, prelude)
      mark = @errors.size
      kind = yield
      return kind unless block.glued && kind == :error

      @errors.slice!(mark..)
      error(block.line, "`#{prelude}` joins two tokens across a comment; CSS reads them apart")
    end

    # Matches on the prelude's canonical identifiers (@m\65 dia is @media,
    # d\61rk is dark); messages quote the prelude as written.
    def classify_at_rule(block, prelude, parent)
      canonical = ColorCss.canonical_idents(prelude)
      name = canonical[AT_NAME].to_s.downcase(:ascii)
      case name
      when '@layer'
        return top_layer(block, prelude, canonical) if parent.nil?

        error(block.line, "nested `#{prelude}`; only one @layer wrapper is allowed")
      when '@media'
        m = MEDIA_SCHEME.match(canonical.downcase(:ascii))
        unless m && !%i[media_light media_dark].include?(parent)
          return error(block.line, "`#{prelude}` is not a token block; only prefers-color-scheme media is allowed")
        end

        m[1] == "dark" ? :media_dark : :media_light
      when '@theme'
        return error(block.line, "`#{prelude}` is only allowed at top level") unless parent.nil? || parent == :layer

        theme(block, prelude, canonical)
      else
        error(block.line, "`#{name}` is not allowed in a token file")
      end
    end

    # @theme options that may join static, spelled exactly as Tailwind
    # compares them (lowercase, no escapes). Without static Tailwind emits
    # only the variables it detects in use, which this checker cannot see,
    # so static is required. default yields to any other theme value, and
    # with no @import the one block has no other (check_theme_default).
    # reference emits none.
    THEME_OPTIONS = %w[static inline default].freeze

    # One @theme static block, light. Tailwind emits every @theme block's
    # variables together at the first block's position, so a second block
    # would sit in the cascade somewhere other than where it is written: an
    # error, as is a block without static or with any option besides
    # static, inline and default.
    def theme(block, prelude, canonical)
      return error(block.line, "second `#{prelude}`; only one @theme block is allowed, since Tailwind " \
                               "emits every @theme at the first one's position") if @theme_seen

      options = ColorCss.strip_ws(prelude.sub(AT_NAME, "")).split(ColorCss::WS_RUN)
      if (bad = options.find { |o| !THEME_OPTIONS.include?(o) })
        return error(block.line, "`#{prelude}` has option `#{bad}`; Tailwind reads only static, inline and " \
                                 "default, spelled exactly so (reference emits no variables)")
      end
      unless options.include?('static')
        return error(block.line, "`#{prelude}` may omit variables Tailwind does not detect in use; " \
                                 "write `@theme static` so every audited variable is emitted")
      end

      @theme_seen = true
      @theme_id = block.id
      @theme_default_line = block.line if options.include?('default')
      note_specificity(block.id, light: THEME_SPECIFICITY)
      :light
    end

    # An at-rule's name as written, escapes and non-ASCII included.
    AT_NAME = /\A@#{ColorCss::IDENT_UNIT}+/.freeze
    # What follows "@layer" in a wrapper: nothing, or one layer name, a
    # dot-separated run of identifiers (base, theme.base, café).
    TOP_LAYER_PRELUDE = /\A(?:#{ColorCss::WS_SRC}+#{ColorCss::IDENT_SRC}(?:\.#{ColorCss::IDENT_SRC})*)?#{ColorCss::WS_SRC}*\z/.freeze

    def top_layer(block, prelude, canonical)
      return error(block.line, "second `#{prelude}`; only one @layer wrapper is allowed") if @layer_seen
      unless TOP_LAYER_PRELUDE.match?(canonical.sub(AT_NAME, ""))
        return error(block.line, "`#{prelude}` is not a valid @layer wrapper; use `@layer` or a single layer name")
      end
      if (reserved = layer_segments(canonical).find { |s| ColorValue::CSS_WIDE_KEYWORDS.include?(s.downcase(:ascii)) })
        return error(block.line, "`#{prelude}` names a layer `#{reserved}`, a CSS-wide keyword; browsers drop the whole rule")
      end

      @layer_seen = true
      @layer_of[block.id] = (@layers[layer_key(block, canonical)] ||= @layers.size)
      :layer
    end

    # A named layer is one layer wherever it is opened; each anonymous
    # @layer block is its own.
    def layer_key(block, canonical)
      name = ColorCss.strip_ws(canonical.sub(AT_NAME, ""))
      name.empty? ? [ :anonymous, block.id ] : name
    end

    # The dot-separated segments of a wrapper's layer name, escapes resolved.
    # CSS-wide keywords are reserved in every segment; a rule naming one is
    # invalid at parse time.
    def layer_segments(canonical)
      ColorCss.strip_ws(canonical.sub(AT_NAME, "")).split('.')
    end

    def classify_rule(block, prelude, parent)
      members = ColorCss.split_top_level(block.prelude).map { |m| ColorCss.strip_ws(m) }
      mechanisms = members.map { |sel| selector_mechanism(sel) }
      variants = mechanisms.map { |m| m && (m == :light ? :light : :dark) }
      if (bad = members.zip(variants).find { |_, v| v.nil? })
        return error(block.line, "selector `#{bad[0].gsub(ColorCss::WS_RUN, ' ')}` is not a token block; #{SELECTOR_HINT}")
      end
      if variants.uniq.size > 1
        return error(block.line, "selector list `#{prelude}` mixes light and dark; one variant per block")
      end

      note_specificity(block.id, members.zip(mechanisms).each_with_object({}) do |(sel, m), by|
        by[m] = [ by[m], specificity(sel) ].compact.max
      end)
      kind = in_media(block, prelude, parent, variants.first)
      @mechanisms[block.id] = parent == :media_dark ? [ :media ] : mechanisms.uniq if kind == :dark
      kind
    end

    # A block's specificity, kept per activation mechanism: a browser that
    # activates one mechanism matches only that mechanism's members of a
    # selector list, so :root.dark, [data-theme=dark] applies at (0,2,0)
    # under the class and (0,1,0) under the attribute. With every mechanism
    # active at once (:all, the merged dark table) every member matches,
    # so the block applies with the most specific one.
    def note_specificity(block_id, by_mechanism)
      @specificity[block_id] = by_mechanism.merge(all: by_mechanism.values.max)
    end

    # The specificity block_id applies with under mechanism; a mechanism
    # none of its members names (a :root inside dark media is :media) falls
    # back to the whole list.
    def specificity_of(block_id, mechanism = :all)
      by = @specificity.fetch(block_id)
      by.fetch(mechanism) { by.fetch(:all) }
    end

    # A :root inside light media is noted in @light_media: it applies only
    # while the system prefers light, which a dark mechanism other than
    # media does not control (see dark_table).
    def in_media(block, prelude, parent, variant)
      return variant unless %i[media_light media_dark].include?(parent)

      @light_media << block.id if variant == :light && parent == :media_light
      return parent == :media_dark ? :dark : :light if variant == :light

      error(block.line, "selector `#{prelude}` inside prefers-color-scheme media; only :root is allowed there")
    end

    # :light, or the dark activation mechanism (:class for .dark and
    # :root.dark, :attribute for [data-theme=dark] and its :root form), or
    # nil, for one selector-list member, read off its token stream: a
    # whitespace or >+~ combinator at top level is never accepted. A :root
    # inside dark media is the third mechanism, :media (classify_rule).
    def selector_mechanism(selector)
      return nil if combinator?(selector)

      compound = canonical_selector(selector)
      folded = compound.downcase(:ascii)
      return :light if folded == ":root"

      rest = folded.start_with?(":root") ? compound[5..] : compound
      return :class if rest == ".dark"

      :attribute if rest.match?(DARK_ATTR)
    end

    # A quoted string or an escape outside one: spans whose whitespace and
    # quotes are content, so compact_selector and normalize leave them alone.
    QUOTED = /(#{ColorCss::ESCAPE}|"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?)/m

    # The selector as CSS reads it, for comparison only: escaped identifiers
    # decoded to one canonical spelling (ColorCss.canonical_idents, so
    # :r\6f ot is :root and [d\61ta-theme] is [data-theme]), quoted strings
    # to one canonical spelling (ColorCss.canonical_strings, so "d\61rk" and
    # 'dark' are "dark"), then compacted. An escape that decodes to a
    # delimiter stays escaped (.\2e dark is the class ".dark"), so it never
    # reads as selector structure.
    def canonical_selector(selector)
      compact_selector(ColorCss.canonical_strings(ColorCss.canonical_idents(selector)))
    end

    # Drops only syntactic spacing around [ ] = outside quoted strings, so
    # `[ data-theme = "dark" ]` compacts but `"d a r k"` and `da rk` keep theirs.
    BRACKET_SPACE = /#{ColorCss::WS_SRC}*([\[\]=])#{ColorCss::WS_SRC}*/.freeze

    def compact_selector(selector)
      ColorCss.strip_ws(selector).split(QUOTED).each_with_index.map do |part, i|
        i.odd? ? part : part.gsub(BRACKET_SPACE, "\\1")
      end.join
    end

    def combinator?(selector)
      top_level_chars(selector).any? { |ch| ch.match?(/[ \t\n\r\f>+~]/) }
    end

    # Selector specificity (ids, classes/attributes/pseudo-classes, types)
    # of one accepted compound, read off its canonical token stream: each
    # top-level `#` is an id, each `.`, `:` and `[` a class-level simple
    # selector. :root, .dark and [data-theme=dark] are (0,1,0); :root.dark
    # and :root[data-theme=dark] are (0,2,0).
    def specificity(selector)
      top_level_chars(canonical_selector(selector)).each_with_object([ 0, 0, 0 ]) do |ch, counts|
        case ch
        when "#" then counts[0] += 1
        when ".", ":", "[" then counts[1] += 1
        end
      end
    end

    # The selector's characters outside brackets, parentheses, quoted
    # strings and escapes; an opening bracket is yielded at the depth it
    # opens from. An escape (\ , \>, \[, \") is part of a compound, never
    # a combinator, bracket or quote.
    def top_level_chars(selector)
      return enum_for(__method__, selector) unless block_given?

      depth = 0
      i = 0
      while i < selector.length
        ch = selector[i]
        case ch
        when "\\" then i = ColorCss.skip_escape(selector, i)
          next
        when '"', "'" then i = ColorCss.skip_string(selector, i)
          next
        end
        depth -= 1 if ch == "]" || ch == ")"
        yield ch if depth.zero?
        depth += 1 if ch == "[" || ch == "("
        i += 1
      end
    end

    def check_statement(stmt)
      kind = stmt.block_id && @kinds[stmt.block_id]
      return if %i[error skip].include?(kind)

      name = ColorCss.canonical_idents(stmt.name).downcase(:ascii)
      @import_lines << stmt.line if name == '@import'
      return if (kind.nil? || kind == :layer) && SKIPPED_STATEMENTS.include?(name)

      text = [ stmt.name, stmt.prelude ].reject(&:empty?).join(' ')
      error(stmt.line, "`#{text}` is not allowed in a token file; only --name: value")
    end

    # An imported stylesheet may declare its own @theme values, which an
    # @theme default block yields to, and the checker cannot see them. A
    # global reset (--*: initial) in the block clears every theme value
    # before it, so default is safe when every @import sits on a line above
    # the block (a shared line cannot be ordered, so it does not count).
    def check_theme_default
      return unless @theme_default_line && @import_lines.any?
      return if @theme_reset_all && @import_lines.all? { |l| l < @theme_default_line }

      error(@theme_default_line, "`@theme default` yields to any theme value an @import declares, which this " \
                                 "checker cannot see; drop default, or start the block with `--*: initial` " \
                                 "below every @import")
    end

    def record(decl, order)
      kind = decl.block_id && @kinds[decl.block_id]
      return if %i[error skip].include?(kind)
      unless %i[light dark].include?(kind)
        return error(decl.line, "declaration `#{decl.name}` outside a token block")
      end
      return namespace_reset(decl) if decl.name.end_with?('*')
      unless decl.name.start_with?('--')
        return error(decl.line, "property `#{decl.name}` is not allowed in a token block; only --name: value")
      end

      @theme_names << decl.name if decl.block_id == @theme_id
      store(kind == :light ? @light : @dark, kind, decl, order)
    end

    # A Tailwind namespace reset (--*: initial, --color-*: initial) inside
    # @theme drops Tailwind's own defaults and declares no token. It also
    # drops any theme name above it in its namespace, so one after such a
    # name is an error rather than a cascade the checker would have to model.
    def namespace_reset(decl)
      unless decl.block_id == @theme_id
        return error(decl.line, "`#{decl.name}` is a Tailwind namespace reset, only allowed inside @theme")
      end
      unless ColorCss.strip_ws(decl.value) == 'initial' && !decl.important
        return error(decl.line, "`#{decl.name}` must be exactly `initial`; it resets a Tailwind namespace")
      end

      prefix = decl.name.delete_suffix('*')
      cleared = @theme_names.find { |n| n.start_with?(prefix) }
      return error(decl.line, "`#{decl.name}: initial` clears `#{cleared}` declared above it; put resets first") if cleared

      @theme_reset_all = true if decl.name == '--*'
    end

    # A value holding a malformed var() (ColorValue.malformed_var) is
    # invalid at parse time, so the browser ignores the declaration: it is
    # an error and never enters the table. An equal-valued redeclaration
    # keeps whichever declaration sorts highest, since that one is what
    # competes with the other variant.
    def store(table, kind, decl, order)
      @dark_seen = true if kind == :dark
      if (bad = ColorValue.malformed_var(decl.value))
        return error(decl.line, "`#{decl.name}` has a malformed `#{bad}`; CSS ignores the whole declaration")
      end

      prior = table[decl.name]
      if prior && !same_value?(prior[:value], decl.value)
        return error(decl.line, "`#{decl.name}` is declared twice in #{kind} with different values " \
                                "(line #{prior[:line]}: #{prior[:value]}; here: #{decl.value})")
      end

      origin = { important: decl.important, layer: decl.block_id && @layer_of[decl.block_id],
                 specificity: specificity_of(decl.block_id), order: }
      keep(table, decl, origin)
      keep(@light_plain, decl, origin) if kind == :light && !@light_media.include?(decl.block_id)
      return unless kind == :dark

      @mechanisms.fetch(decl.block_id).each do |m|
        keep(@dark_by[m], decl, origin.merge(specificity: specificity_of(decl.block_id, m)))
      end
    end

    def keep(table, decl, origin)
      entry = (table[decl.name] ||= { value: decl.value, line: decl.line, **origin })
      entry.merge!(origin) if (cascade_key(origin) <=> cascade_key(entry)).positive?
    end

    def check_dark_names
      @dark.each do |name, entry|
        next if @light.key?(name)

        error(entry[:line], "`#{name}` is declared in dark but not in light; dark may only redefine light names")
      end
    end

    # Light is graded with light media active. Unless dark media takes over
    # whenever the system prefers dark, light also shows under a dark
    # preference, where light media is inactive, so a name declared only
    # there would be missing from light. (Light media cannot otherwise
    # change light: a redeclaration with another value is already an error.)
    def check_light_media_names
      return if @dark_by.key?(:media)

      (@light.keys - @light_plain.keys).each do |name|
        error(@light[name][:line], "`#{name}` is declared only inside prefers-color-scheme: light, so light " \
                                   "under a dark system preference lacks it; declare it on :root as well")
      end
    end

    # The dark variant. Each activation mechanism applies on its own, so
    # when a file uses several, each one's dark table is built alone and
    # they must agree; otherwise there is no single dark palette to grade.
    def dark_tokens
      tables = @dark_by.to_h { |mechanism, overrides| [ mechanism, dark_table(mechanism, overrides) ] }
      check_mechanisms_agree(tables)
      tables.values.first || over_light(@dark, @light)
    end

    # One mechanism's dark table. Dark media activates only under a dark
    # system preference, where light media is inactive, so it builds on
    # @light_plain. A class or attribute activates under either preference:
    # light media may then be active or not, so both tables are built and
    # must agree, else the dark palette depends on the system preference.
    def dark_table(mechanism, overrides)
      plain = over_light(overrides, @light_plain)
      return plain if mechanism == :media

      active = over_light(overrides, @light)
      name = (active.keys | plain.keys).find { |n| !same_value?(active[n], plain[n]) }
      if name
        error(@light[name][:line], "dark under #{MECHANISMS[mechanism]} differs at `#{name}` with " \
                                   "prefers-color-scheme: light active or not; a light media declaration " \
                                   "outranks the dark one only while the system prefers light")
      end
      active
    end

    # base (a light table) with overrides applied per the cascade. A dark
    # override of a name base lacks, but light declares elsewhere, still
    # applies.
    def over_light(overrides, base)
      base.merge(overrides.slice(*@light.keys)) { |_, light, dark| applied(light, dark) }.transform_values { |v| v[:value] }
    end

    def check_mechanisms_agree(tables)
      (first, base), *rest = tables.to_a
      rest.each do |mechanism, table|
        name = (base.keys | table.keys).find { |n| !same_value?(base[n], table[n]) }
        next unless name

        line = [ first, mechanism ].filter_map { |m| @dark_by[m][name]&.dig(:line) }.min
        return error(line, "dark under #{MECHANISMS[first]} and under #{MECHANISMS[mechanism]} differ at " \
                           "`#{name}`; each activates alone, so dark must give the same palette under every mechanism")
      end
    end

    # The entry the cascade applies on the dark root element when a dark
    # declaration competes with a light one for the same name: the higher
    # cascade_key wins. Source order breaks every tie, so there is no
    # default winner.
    def applied(light, dark)
      (cascade_key(light) <=> cascade_key(dark)).positive? ? light : dark
    end

    # The full CSS Cascade 5 sort of an entry, as a comparable array:
    # importance and layer (cascade_rank), then selector specificity, then
    # source order, later winning.
    def cascade_key(entry)
      [ *cascade_rank(entry), entry[:specificity], entry[:order] ]
    end

    # CSS Cascade 5 order of an entry's origin, as a comparable pair. Priority
    # first: !important beats normal. Then layer (an index by first
    # appearance, nil when unlayered): for normal declarations unlayered
    # beats layered and a later layer beats an earlier one; for !important
    # ones the order reverses, layered beats unlayered and earlier beats later.
    def cascade_rank(entry)
      position = entry[:layer] || Float::INFINITY
      entry[:important] ? [ 1, -position ] : [ 0, position ]
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
          slot = (authored[color_key(value)] ||= { value: ColorCss.strip_ws(value), names: [], line: entry[:line] })
          slot[:names] << name unless slot[:names].include?(name)
        elsif ColorCss.function_tokens(value).any? { |t| DERIVED_FUNCTIONS.include?(t.name) }
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

    # Whether two table values (nil when the name is absent) are the same
    # CSS value in every grammar a token may be substituted into. A value
    # that is one identifier compares exactly (a CSS-wide keyword ASCII
    # case-insensitively): blue, BLUE and #00f are one color but distinct
    # animation-name values. Any other value matches on its canonical token
    # sequence (normalize), or on the color it names, since a hash or color
    # function is only valid where a color is (#FFF, #fff, rgb(255 255 255)).
    def same_value?(one, other)
      return one.nil? && other.nil? if one.nil? || other.nil?

      exact = [ one, other ].map { |v| whole_ident(v) }
      return exact.first == exact.last if exact.any?
      return true if normalize(one) == normalize(other)

      colors = [ one, other ].map { |v| standalone_color(v) }
      colors.none?(&:nil?) && colors.map { |c| color_key_of(c) }.uniq.size == 1
    end

    WHOLE_IDENT = /\A#{ColorCss::IDENT_SRC}\z/.freeze

    # The identifier a whole value is, escapes canonicalized, or nil; a
    # CSS-wide keyword is ASCII-lowercased.
    def whole_ident(value)
      text = ColorCss.canonical_idents(ColorCss.strip_ws(value))
      return nil unless WHOLE_IDENT.match?(text)

      ColorValue::CSS_WIDE_KEYWORDS.include?(text.downcase(:ascii)) ? text.downcase(:ascii) : text
    end

    # Equivalent color spellings (#fff, white, rgb(255 255 255), transparent
    # and TRANSPARENT) share one palette key: the resolved RGBA whenever the
    # value names a supported color on its own, whether or not it counts
    # toward the palette (authored?), else its normalized text.

    def color_key(value)
      color = standalone_color(value)
      color ? color_key_of(color) : normalize(value)
    end

    def color_key_of(color)
      [ color.r, color.g, color.b, color.a ].map { |c| channel_key(c) }
    end

    # The color a value names with nothing substituted, or nil. A value with
    # any var() is never keyed by color: var(--x, red) is not red once --x
    # is declared.
    def standalone_color(value)
      return nil if ColorCss.function_tokens(value).any? { |t| t.name == "var" }

      ColorValue.resolve(value, {}).color
    end

    # Keys on the exact channel value with no rounding, so any two colors the
    # resolver keeps distinct stay distinct (rgb(0.0000001 0 0) vs
    # rgb(0.0000002 0 0)). Rational makes 255, 255.0 and -0.0/0 compare equal.
    def channel_key(channel)
      channel.to_r
    end

    # The value as a canonical token sequence. Escapes in every identifier
    # outside strings are decoded and written back in one canonical spelling
    # (ColorCss.canonical_idents), so var(--\69 nk) and var(--ink) agree,
    # and every quoted string is decoded and re-quoted one way
    # (ColorCss.canonical_strings), so "Inter", 'Inter' and "\49 nter"
    # agree. Then identifiers are ASCII-lowercased under
    # ColorValue.case_folds: function names and numeric tokens always (VAR(,
    # 10DEG, 1E3), a color or CSS-wide keyword when it is the whole value
    # (currentColor, INHERIT), and otherwise a bare identifier only as a
    # color function's own argument (Light-Dark(RED, Blue), oklch(from RED
    # l c NONE)). So `1s RED` and `1s red` stay distinct (RED may name
    # keyframes), as does Foo(RED) nested in color-mix(), and so do
    # FadeIn, url(/A.png) contents, var(--Ink) names, string contents and
    # non-ASCII code points. Comments are already blanked to whitespace by
    # the parser, and whitespace outside strings is canonicalized by CSS
    # token semantics.
    def normalize(value)
      text = ColorCss.canonical_strings(ColorCss.canonical_idents(ColorCss.strip_ws(value)))
      ColorCss.downcase_keywords(text, ColorValue.case_folds(text)).split(QUOTED).each_with_index.map do |part, i|
        i.odd? ? part : insignificant_space_dropped(part)
      end.join
    end

    # Whitespace directly inside ( and ), and around a comma or slash, is a
    # separate whitespace token no value grammar reads, so var( --ink ) and
    # var(--ink), or rgb(0 , 0) and rgb(0,0), agree. Any other run of
    # whitespace separates tokens, so it collapses to one space but stays.
    def insignificant_space_dropped(text)
      text.gsub(ColorCss::WS_RUN, " ").gsub(/\( /, "(").gsub(/ \)/, ")").gsub(%r{ ?([,/]) ?}, "\\1")
    end
  end
end
