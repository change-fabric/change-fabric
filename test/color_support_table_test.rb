# frozen_string_literal: true

require "tmpdir"
require_relative "test_helpers"
require_relative "#{File.expand_path('../scripts', __dir__)}/color_check"

# Executable form of the support table in skills/color/SKILL.md. One fixture
# per listed form: a Supported form must resolve (a resolved contrast row, or
# a scan finding); an Unsupported form must come out unsupported, unresolved
# or exempt, with a reason; a form the table names in neither column must
# come out unresolved. The accounting tests then check that no custom
# property and no color-shaped literal is ever silently dropped.
class ColorSupportTableTest < Minitest::Test
  BASE = ":root { --bg: #ffffff; --text: #111111; }\n"

  def contrast(css)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tokens.css")
      File.write(path, css)
      ColorCheck.compute_contrast(path)
    end
  end

  def rows_for(css, token)
    contrast(css).select { |r| r.text_token == token }
  end

  def assert_resolved(css, token = "--text", theme: nil)
    rows = rows_for(css, token)
    rows = rows.select { |r| r.theme == theme } if theme
    refute_empty rows, "no row for #{token} in #{css.inspect}"
    rows.each { |r| assert r.resolved, "#{token} unresolved (#{r.reason}) in #{css.inspect}" }
  end

  def assert_not_resolved(css, token = "--text")
    rows = rows_for(css, token).reject(&:resolved)
    refute_empty rows, "#{token} resolved or missing in #{css.inspect}"
    rows.each { |r| refute_empty r.reason.to_s, "empty reason in #{css.inspect}" }
  end

  def assert_unsupported_context(css, token = "--text")
    rows = rows_for(css, token).select { |r| r.theme == "unsupported" }
    refute_empty rows, "#{token} not reported unsupported in #{css.inspect}"
    rows.each { |r| refute_empty r.reason.to_s }
  end

  def classes(path, text)
    ColorScan.classify_all(path, text)
  end

  # --- Theme contexts: Supported -------------------------------------------

  SUPPORTED_THEME_CONTEXTS = {
    "bare :root" => [ BASE, "default" ],
    "bare html" => [ "html { --bg: #fff; --text: #111; }", "default" ],
    ":root[data-theme=X]" => [ "#{BASE}:root[data-theme=\"dark\"] { --bg: #000; --text: #eee; }", "dark" ],
    "html.X" => [ "#{BASE}html.dark { --bg: #000; --text: #eee; }", "dark" ],
    ":root:not(.X)" => [ ":root:not(.dark) { --bg: #fff; --text: #111; }", "default" ],
    "bare .X custom-property-only" => [ "#{BASE}.dark { --bg: #000; --text: #eee; }", "dark" ],
    "bare [data-theme=X] custom-property-only" => [ "#{BASE}[data-theme=dark] { --bg: #000; --text: #eee; }", "dark" ],
    "@media prefers-color-scheme dark" => [ "#{BASE}@media (prefers-color-scheme: dark) { :root { --bg: #000; --text: #eee; } }", "default" ],
    "@media prefers-color-scheme light" => [ "@media (prefers-color-scheme: light) { :root { --bg: #fff; --text: #111; } }", "default" ],
    ":root[data-theme=light]" => [ "#{BASE}:root[data-theme=\"light\"] { --bg: #fff; --text: #000; }", "light" ],
    "@layer" => [ "@layer base { :root { --bg: #fff; --text: #111; } }", "default" ]
  }.freeze

  def test_supported_theme_contexts_resolve
    SUPPORTED_THEME_CONTEXTS.each do |form, (css, theme)|
      rows = rows_for(css, "--text").select { |r| r.theme == theme }
      refute_empty rows, "#{form}: no #{theme} row"
      assert rows.all?(&:resolved), "#{form}: #{rows.map(&:reason).inspect}"
    end
  end

  # Every page state (unmarked default, each marker, each OS scheme) times
  # every text-role token live in it is covered by exactly one contrast row,
  # and every unsupported context's text role by exactly one unsupported row.
  STATE_REPRO = ":root{--text:#000;--bg:#fff}\n[data-theme=light]{--bg:#eee}\n" \
                "[data-theme=dark]{--text:#fff;--bg:#000}\n" \
                "@media (prefers-color-scheme: dark){:root:not([data-theme=light]){--text:#ccc;--bg:#111}}\n"

  def assert_state_coverage(css)
    sheet = ColorCss.parse(css)
    rows = contrast(css)
    ColorThemes.state_names(sheet).each do |state, names|
      names.select { |n| ColorThemes.text_role_name?(n) }.each do |role|
        hits = rows.select { |r| r.text_token == role && r.states.include?(state) }
        assert_equal 1, hits.size, "#{state.inspect} #{role}: #{hits.size} rows for #{css.inspect}"
      end
    end
    ColorThemes.build(sheet).unsupported.each do |uns|
      uns.decls.each_key.select { |n| ColorThemes.text_role_name?(n) }.each do |role|
        hits = rows.select { |r| r.theme == "unsupported" && r.context == uns.label && r.text_token == role }
        assert_equal 1, hits.size, "unsupported #{uns.label} #{role} in #{css.inspect}"
      end
    end
  end

  def test_every_page_state_and_text_role_yields_exactly_one_row
    fixtures = SUPPORTED_THEME_CONTEXTS.values.map(&:first) + UNSUPPORTED_THEME_CONTEXTS.values + [ STATE_REPRO ]
    fixtures.each { |css| assert_state_coverage(css) }
  end

  # --- Theme contexts: Reported as unsupported ------------------------------

  UNSUPPORTED_THEME_CONTEXTS = {
    "other selector with a text role" => "#{BASE}.card p { --text: #222; }",
    "other @media" => "#{BASE}@media print { :root { --text: #000; } }",
    "@supports" => "#{BASE}@supports (color: red) { :root { --text: #000; } }",
    "@container" => "#{BASE}@container (min-width: 1px) { :root { --text: #000; } }",
    "@scope" => "#{BASE}@scope (.a) { :root { --text: #000; } }",
    "conflicting theme markers" => "#{BASE}@media (prefers-color-scheme: dark) { :root[data-theme=light] { --text: #000; } }",
    "media condition on a theme selector" => "#{BASE}@media (prefers-color-scheme: dark) { :root[data-theme=dark] { --text: #000; } }"
  }.freeze

  def test_unsupported_theme_contexts_are_reported
    UNSUPPORTED_THEME_CONTEXTS.each_value { |css| assert_unsupported_context(css) }
  end

  def test_scss_nesting_is_reported_unsupported
    sheet = ColorCss.parse(".a { .b { --text: #000; } }", dialect: :scss)
    model = ColorThemes.build(sheet)
    assert(model.unsupported.any? { |u| u.decls.key?("--text") && !u.why.to_s.empty? })
  end

  # --- Color values ----------------------------------------------------------

  SUPPORTED_VALUES = [
    "#000", "#000f", "#000000", "#000000ff",
    "rgb(0, 0, 0)", "rgba(0, 0, 0, 1)", "rgb(0 0 0)", "rgb(0 0 0 / 1)",
    "hsl(0, 0%, 0%)", "hsla(0, 0%, 0%, 1)", "hsl(0 0% 0%)",
    "black", "rebeccapurple", "#000 !important"
  ].freeze

  def test_supported_color_values_resolve
    SUPPORTED_VALUES.each { |v| assert_resolved(":root { --bg: #fff; --text: #{v}; }") }
  end

  def test_transparent_resolves
    assert_resolved(":root { --bg: #fff; --text: #000; --x-text: transparent; }", "--x-text")
  end

  UNSUPPORTED_VALUES = [
    "oklch(0.2 0 0)", "oklab(0.2 0 0)", "lab(20 0 0)", "lch(20 0 0)", "hwb(0 0% 100%)",
    "color(srgb 0 0 0)", "rgb(from #fff r g b)", "rgb(calc(0) 0 0)", "inherit"
  ].freeze

  def test_unsupported_color_values_are_unresolved
    UNSUPPORTED_VALUES.each { |v| assert_not_resolved(":root { --bg: #fff; --text: #{v}; }") }
  end

  # --- Value functions -------------------------------------------------------

  SUPPORTED_FUNCTIONS = [
    "var(--ink-base)", "var(--missing, #000)",
    "color-mix(in srgb, #000 80%, #fff)", "color-mix(in srgb, #000, #fff 20%)",
    "color-mix(in srgb, #000 80%, #fff 20%)"
  ].freeze

  def test_supported_value_functions_resolve
    SUPPORTED_FUNCTIONS.each { |v| assert_resolved(":root { --ink-base: #000; --bg: #fff; --text: #{v}; }") }
  end

  UNSUPPORTED_FUNCTIONS = [
    "color-mix(in oklch, #000, #fff)", "light-dark(#000, #fff)", "currentColor"
  ].freeze

  def test_unsupported_value_functions_are_unresolved
    UNSUPPORTED_FUNCTIONS.each { |v| assert_not_resolved(":root { --bg: #fff; --text: #{v}; }") }
  end

  # --- Neither column: unresolved, never guessed ----------------------------

  def test_forms_in_neither_column_are_unresolved
    assert_unsupported_context("#{BASE}@media (min-width: 40em) { :root { --text: #000; } }")
    assert_not_resolved(":root { --bg: #fff; --text: color-mix(in srgb, oklch(0.2 0 0), #fff); }")
    assert_equal [ [ "#abc", :unresolved ] ], classes("a.js", "const c = ok ? '#abc' : null;")
    assert_equal [ [ "#123", :unresolved ] ], classes("a.js", "x = ok?a:'#123';")
  end

  # --- Stray scan, CSS -------------------------------------------------------

  def test_css_declaration_values_are_findings
    [ ".a { color: #abc; }", ".a { color: rgb(1 2 3); }", ".a { color: red; }" ].each do |css|
      assert_equal [ :finding ], classes("a.css", css).map(&:last), css
    end
  end

  def test_css_apply_is_a_finding
    findings = ColorScan.findings_for("a.css", ".a { @apply bg-red-500; }", token_file: nil)
    assert_equal [ "tailwind" ], findings.map(&:kind)
  end

  def test_css_unsupported_column_is_not_a_finding
    [
      "#abc { display: block; }",
      ".a { background: url(#abc); }",
      ".a { content: \"#abcdef\"; }",
      ".a { color: transparent; border-color: currentColor; color: inherit; }",
      ".a { color: initial; color: unset; color: revert; outline: none; }"
    ].each { |css| assert_equal [], classes("a.css", css), css }
  end

  # --- Stray scan, markup and script ------------------------------------------

  def test_markup_attributes_are_findings
    {
      '<p style="color: #abc">x</p>' => "literal",
      '<path fill="#abcdef"/>' => "literal",
      '<path stroke="red"/>' => "literal",
      '<p class="text-red-500">x</p>' => "tailwind"
    }.each do |html, kind|
      assert_equal [ kind ], ColorScan.findings_for("a.html", html, token_file: nil).map(&:kind), html
    end
    assert_equal [ "tailwind" ],
                 ColorScan.findings_for("a.jsx", '<p className="bg-red-500" />', token_file: nil).map(&:kind)
  end

  def test_script_strings_that_are_one_color_are_findings
    [
      "const s = { color: '#abc' };", "const s = { backgroundColor: '#abcd' };",
      "const s = { borderColor: '#abc' };", "const s = { shadow: '#abc' };",
      "x('#abcdef');", "x('rgb(1 2 3)');", "x('rebeccapurple');",
      "<path fill={'#f00'} />"
    ].each { |js| assert_equal [ :finding ], classes("a.jsx", js).map(&:last), js }
  end

  def test_script_unsupported_column_is_exempt_or_absent
    assert_equal [ [ "#cafe", [ :exempt, :call_arg ] ] ], classes("a.js", "document.querySelector('#cafe');")
    assert_equal [ [ "#abc", [ :exempt, :non_color_key ] ] ], classes("a.js", "const o = { id: '#abc' };")
    [
      "const u = '/page#feed';",
      "const css = `.a { color: #abcdef }`;",
      "// #abcdef in a comment"
    ].each { |js| assert_equal [], classes("a.js", js), js }
    assert_equal [], classes("a.html", "<p>red #abcdef prose</p>")
    assert_equal [], classes("a.mdx", "Prose red.\n\n```js\nconst c = '#abcdef';\n```\n")
    assert_equal [], classes("a.scss", "$brand: #abcdef;").reject { |_, c| c == :finding }
    assert_equal [], classes("icon.svg", '<svg><path fill="#abcdef"/></svg>')
  end

  def test_markup_style_and_script_blocks_are_scanned
    assert_equal [ "literal" ],
                 ColorScan.findings_for("a.html", "<style>.a { color: #abcdef; }</style>", token_file: nil).map(&:kind)
    assert_equal [ "literal" ],
                 ColorScan.findings_for("a.html", "<script>x('#abcdef');</script>", token_file: nil).map(&:kind)
  end

  # --- Rule rows: Markup, CSS values, Properties, Cascade, Foreground pairing --

  def contrast_file(name, text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, text)
      ColorCheck.compute_contrast(path)
    end
  end

  def test_markup_rule_style_inside_script_string_is_not_a_style_element
    skip "lands in Phase 2: Tokenize live style elements before parsing them"
    html = '<script>var a="<style>:root{--text:#000;--bg:#fff}</style>";</script>'
    sheet = ColorCheck.style_block_sheet(html)
    assert(sheet.nil? || sheet.decls.empty?, "tokens parsed from a fake style: #{sheet&.decls.inspect}")
  end

  def test_css_values_rule_url_body_is_not_scanned
    skip "lands in Phase 2: Blank complete quoted url() values"
    assert_equal [], classes("a.css", 'a{background:url("a)#abc")}')
  end

  def test_properties_rule_three_way
    skip "lands in Phase 4: Scan named colors in every color-capable shorthand"
    assert_equal [ :finding ], classes("a.css", "a{text-decoration:underline red}").map(&:last)
    assert_equal [], classes("a.css", "a{animation-name:red}")
    assert_equal [ [ "red", :unresolved ] ], classes("a.css", "a{foo-bar:red}")
  end

  # --text sits unlayered (it always wins), so the ratio reveals which layered
  # --bg won: 1.0 against #000, 21.0 against #fff.
  def bg_ratio(name, text)
    rows = contrast_file(name, text).select { |r| r.text_token == "--text" && r.theme == "default" }
    refute_empty rows, text
    rows.first.ratio.round(1)
  end

  def test_cascade_rule_one_layer_order_per_document
    skip "lands in Phase 3: Keep anonymous layer IDs unique across style blocks"
    # Two anonymous layers stay two layers: the later one wins despite the
    # earlier block's higher specificity. Merged into one, specificity would
    # pick #fff.
    html = "<style>:root{--text:#000}@layer{html:root{--bg:#fff}}</style>" \
           "<style>@layer{:root{--bg:#000}}</style>"
    assert_in_delta 1.0, bg_ratio("a.html", html)
  end

  def test_cascade_rule_dotted_statement_registers_prefixes
    skip "lands in Phase 3: Register every prefix of dotted layer statements"
    css = ":root{--text:#000}@layer a.b;@layer c{:root{--bg:#000}}@layer a{:root{--bg:#fff}}"
    assert_in_delta 1.0, bg_ratio("tokens.css", css)
  end

  def test_foreground_pairing_rule
    skip "lands in Phase 4: Pair compound foreground roles with their matching surface"
    present = rows_for(":root{--background:#fff;--card:#000;--card-foreground:#fff}", "--card-foreground")
    assert_equal [ "--card" ], present.map(&:bg_token)
    absent = rows_for(":root{--background:#fff;--card-foreground:#000}", "--card-foreground")
    assert_equal [ "--background" ], absent.map(&:bg_token)
    assert_not_resolved(":root{--background:#fff;--card:var(--missing);--card-foreground:#000}", "--card-foreground")
  end

  def test_catch_all_unlisted_form_is_unresolved
    assert_unsupported_context("#{BASE}@container (min-width: 1px) { :root { --text: #000; } }")
  end

  # Every row of the SKILL.md support table names at least one fixture here,
  # so a new row without a fixture fails.
  ROW_FIXTURES = {
    "Theme contexts" => %i[test_supported_theme_contexts_resolve test_unsupported_theme_contexts_are_reported],
    "Color values" => %i[test_supported_color_values_resolve test_unsupported_color_values_are_unresolved],
    "Value functions" => %i[test_supported_value_functions_resolve test_unsupported_value_functions_are_unresolved],
    "Stray scan, CSS" => %i[test_css_declaration_values_are_findings test_css_unsupported_column_is_not_a_finding],
    "Stray scan, markup and script" => %i[test_markup_attributes_are_findings test_markup_style_and_script_blocks_are_scanned],
    "Markup" => %i[test_markup_rule_style_inside_script_string_is_not_a_style_element],
    "CSS values" => %i[test_css_values_rule_url_body_is_not_scanned],
    "Properties" => %i[test_properties_rule_three_way],
    "Cascade" => %i[test_cascade_rule_one_layer_order_per_document test_cascade_rule_dotted_statement_registers_prefixes],
    "Foreground pairing" => %i[test_foreground_pairing_rule]
  }.freeze

  def support_table_areas
    skill = File.read(File.expand_path("../skills/color/SKILL.md", __dir__))
    header = skill.index("| Area | Supported |")
    skill[header..].lines.drop(2).take_while { |l| l.start_with?("|") }.map { |l| l.split(" | ").first.delete_prefix("| ").strip }
  end

  def test_every_support_table_row_has_a_fixture
    areas = support_table_areas
    refute_empty areas
    areas.each do |area|
      fixtures = ROW_FIXTURES.fetch(area) { flunk "support table row #{area.inspect} has no fixture" }
      fixtures.each { |m| assert respond_to?(m), "#{area}: fixture #{m} is not defined" }
    end
  end

  # --- Accounting invariant: custom properties --------------------------------

  def all_token_fixtures
    SUPPORTED_THEME_CONTEXTS.values.map(&:first) +
      UNSUPPORTED_THEME_CONTEXTS.values +
      (SUPPORTED_VALUES + UNSUPPORTED_VALUES + UNSUPPORTED_FUNCTIONS).map { |v| ":root { --bg: #fff; --text: #{v}; }" } +
      SUPPORTED_FUNCTIONS.map { |v| ":root { --ink-base: #000; --bg: #fff; --text: #{v}; }" } +
      [ ":root { --brand: #f00; --surface: #fff; }",
        "#{BASE}@media (min-width: 40em) { :root { --text: #000; } }",
        "#{BASE}:root { --a: #000; } :root { --b: #fff; }" ]
  end

  # Each custom-property declaration lands in exactly one bucket: paired (a
  # text role with a contrast row), a plain token in a variant, or an
  # unsupported context. ColorThemes.classify decides which context it came
  # from; the test only checks that the model kept it there.
  def test_every_custom_property_lands_in_exactly_one_bucket
    all_token_fixtures.each do |css|
      sheet = ColorCss.parse(css)
      model = ColorThemes.build(sheet)
      rows = contrast(css)
      variant_names = model.variants.flat_map { |v| v.decls.keys }.uniq
      paired = rows.flat_map { |r| [ r.text_token, r.bg_token ] }.compact.uniq
      count = 0
      sheet.decls.select { |d| d.name.start_with?("--") }.each do |decl|
        decl.selectors.each do |selector|
          count += 1
          kind, label, = ColorThemes.classify(selector, decl, rule_custom_only: ColorThemes.rule_custom_only_map(sheet.decls))
          in_unsupported = %i[unsupported other].include?(kind) &&
                           model.unsupported.any? { |u| u.label == label && u.decls.key?(decl.name) }
          in_variant = !%i[unsupported other].include?(kind) && variant_names.include?(decl.name)
          buckets = [ in_unsupported, in_variant ].count(true)
          assert_equal 1, buckets, "#{decl.name} in #{selector} (#{kind}) lands in #{buckets} buckets: #{css}"
          next unless in_variant && ColorThemes.text_role_name?(decl.name)

          assert_includes paired, decl.name, "text role #{decl.name} never paired: #{css}"
        end
      end
      assert_operator count, :>, 0, css
    end
  end

  # --- Accounting invariant: color-shaped literals ----------------------------

  SCAN_FIXTURES = {
    "a.css" => ".a { color: #abc; background: rgb(1 2 3); border-color: red; }\n#x { content: '#fff'; }",
    "a.jsx" => <<~JSX,
      const a = { color: '#abc', id: '#def' };
      document.querySelector('#cafe');
      const b = ok ? '#abc' : '#123';
      const c = ['#abc', '#abcdef'];
      const d = '#a' + '#bcd';
      <path fill={'#f00'} stroke="#0f0" />;
    JSX
    "a.html" => '<p style="color: #abc" fill="red">x</p><script>const z = { color: "#fff" };</script>',
    "a.mdx" => "import x from 'y'\n\n<Box color={'#abc'} />\n",
    "a.vue" => %q(<path :fill="ok ? '#abc' : '#def'" v-bind:stroke="'#123'" :data-color="'#456'" :data-x="'#789'"/>),
    "a.svelte" => "<path fill={'#abc'} stroke={a ?? '#def'} title={'#123'}/>"
  }.freeze

  def test_every_color_literal_lands_in_exactly_one_class
    SCAN_FIXTURES.each do |path, text|
      classified = classes(path, text)
      refute_empty classified, path
      classified.each do |literal, klass|
        valid = klass == :finding || klass == :unresolved ||
                (klass.is_a?(Array) && klass.first == :exempt &&
                 (ColorScan::EXEMPT_RULES + [ :non_color_key ]).include?(klass.last))
        assert valid, "#{path}: #{literal} has no single class (#{klass.inspect})"
      end
      findings, unresolved = ColorScan.scan(path, text, token_file: nil)
      assert_equal findings.count { |f| f.kind == "literal" }, classified.count { |_, k| k == :finding }, path
      assert_equal unresolved.size, classified.count { |_, k| k == :unresolved }, path
    end
  end

  def test_jsx_fixture_classes
    got = classes("a.jsx", SCAN_FIXTURES["a.jsx"]).sort_by { |l, k| [ l, k.to_s ] }
    expected = [
      [ "#0f0", :finding ], [ "#123", :unresolved ], [ "#abc", :finding ], [ "#abc", :unresolved ],
      [ "#abc", [ :exempt, :array_elem ] ], [ "#abcdef", :finding ], [ "#bcd", [ :exempt, :concat ] ],
      [ "#cafe", [ :exempt, :call_arg ] ], [ "#def", [ :exempt, :non_color_key ] ], [ "#f00", :finding ]
    ].sort_by { |l, k| [ l, k.to_s ] }
    assert_equal expected, got
  end

  def test_bound_markup_fixture_classes
    assert_equal [ [ "#abc", :finding ], [ "#def", :finding ], [ "#123", :finding ], [ "#456", :finding ],
                   [ "#789", :unresolved ] ], classes("a.vue", SCAN_FIXTURES["a.vue"])
    assert_equal [ [ "#abc", :finding ], [ "#def", :finding ], [ "#123", :unresolved ] ],
                 classes("a.svelte", SCAN_FIXTURES["a.svelte"])
  end
end
