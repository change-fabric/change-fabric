# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{File.expand_path('../scripts', __dir__)}/color_themes"

class ColorThemesTest < Minitest::Test
  def build(css)
    ColorThemes.build(ColorCss.parse(css))
  end

  def variant_for(model, theme)
    model.variants.find { |v| v.theme == theme }
  end

  # The variant that audits one page state (marker nil is the unmarked page).
  def variant_at(model, marker, os = nil)
    state = ColorThemes::State.new(marker:, os:)
    model.variants.find { |v| v.states.include?(state) }
  end

  def test_foreground_is_a_text_role_in_any_position
    assert ColorThemes.text_role_name?("--foreground")
    assert ColorThemes.text_role_name?("--color-foreground-muted")
    assert ColorThemes.text_role_name?("--card-foreground")
  end

  def test_bare_root_is_base
    model = build(":root { --bg: #fff; --text: #000; }")
    v = variant_for(model, "default")
    refute_nil v
    assert_equal({ "--bg" => "#fff", "--text" => "#000" }, v.decls)
    assert_equal [ "marker default" ], v.contexts
  end

  def test_html_is_also_base
    model = build("html { --bg: #fff; }")
    v = variant_for(model, "default")
    refute_nil v
    assert_equal({ "--bg" => "#fff" }, v.decls)
  end

  def test_root_data_theme_attribute_names_theme
    model = build(':root { --bg: #fff; } :root[data-theme="dark"] { --bg: #000; }')
    dark = variant_for(model, "dark")
    refute_nil dark
    assert_equal "#000", dark.decls["--bg"]
  end

  def test_root_dot_class_names_theme
    model = build(":root { --bg: #fff; --text: #000; } :root.dark { --bg: #000; --text: #fff; }")
    dark = variant_for(model, "dark")
    refute_nil dark
    assert_equal({ "--bg" => "#000", "--text" => "#fff" }, dark.decls)
  end

  def test_html_dot_class_names_theme
    model = build("html { --bg: #fff; } html.dark { --bg: #000; }")
    dark = variant_for(model, "dark")
    refute_nil dark
    assert_equal "#000", dark.decls["--bg"]
  end

  def test_media_prefers_color_scheme_names_theme
    model = build(":root { --bg: #fff; --text: #000; } @media (prefers-color-scheme: dark) { :root { --bg: #000; } }")
    dark = variant_at(model, nil, "dark")
    refute_nil dark
    assert_equal "default", dark.theme
    assert_equal "#fff", variant_at(model, nil, "light").decls["--bg"]
    assert_equal "#000", dark.decls["--bg"]
    assert_equal "#000", dark.decls["--text"], "dark inherits base --text"
  end

  def test_not_qualifier_narrows_and_names_nothing
    model = build(
      '@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #000; --text: #fff; } } ' \
      ':root[data-theme="dark"] { --bg: #000; --text: #fff; }'
    )
    dark = variant_at(model, "dark", "light")
    refute_nil dark
    assert_nil variant_at(model, "light", "dark"), "the explicit light marker opts out of the OS dark block"
    assert_equal({ "--bg" => "#000", "--text" => "#fff" }, dark.decls)
  end

  def test_bare_class_custom_property_only_block_is_theme
    model = build(":root { --bg: #fff; --text: #000; } .dark { --bg: #000; --text: #fff; }")
    dark = variant_for(model, "dark")
    refute_nil dark
    assert_equal({ "--bg" => "#000", "--text" => "#fff" }, dark.decls)
  end

  def test_bare_class_with_color_scheme_decl_still_custom_property_only
    model = build(":root { --bg: #000; --text: #000; } .dark { --text: #fff; color-scheme: dark; }")
    dark = variant_for(model, "dark")
    refute_nil dark
    assert_equal "#fff", dark.decls["--text"]
  end

  def test_bare_data_theme_attribute_custom_property_only_is_theme
    model = build(':root { --bg: #000; --text: #000; } [data-theme="dark"] { --text: #fff; }')
    dark = variant_for(model, "dark")
    refute_nil dark
    assert_equal "#fff", dark.decls["--text"]
  end

  def test_bare_class_not_custom_property_only_stays_ordinary_rule
    model = build(":root { --bg: #fff; } .card { color: red; --text: #000; }")
    assert_nil variant_for(model, "card")
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported
    assert_includes unsupported.why, "not a recognized theme context"
  end

  def test_other_at_rule_is_unsupported
    model = build("@media (min-width: 40em) { :root { --text: #777; } }")
    assert_empty model.variants.select { |v| v.decls.key?("--text") }
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported
  end

  def test_layer_is_transparent
    model = build("@layer base { :root { --bg: #fff; --text: #000; } }")
    v = variant_for(model, "default")
    refute_nil v
    assert_equal({ "--bg" => "#fff", "--text" => "#000" }, v.decls)
  end

  def test_scss_nesting_is_unsupported
    sheet = ColorCss.parse(":root { .card { --text: #777; } }", dialect: :scss)
    model = ColorThemes.build(sheet)
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported
    assert_equal "nested rule", unsupported.why
  end

  def test_conflicting_theme_markers_unsupported
    model = build(
      '@media (prefers-color-scheme: dark) { :root[data-theme="light"] { --text: #fff; } }'
    )
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported
    assert_equal "conflicting theme markers", unsupported.why
  end

  def test_multiple_theme_markers_on_one_selector_unsupported
    model = build(':root[data-theme="light"].accent { --text: #000; }')
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported
    assert_equal "multiple theme markers", unsupported.why
  end

  def test_selector_list_feeds_both_base_and_theme
    model = build(':root, :root[data-theme="light"] { --bg: #fff; --text: #000; }')
    assert_equal 1, model.variants.size, "identical default and light states collapse"
    v = model.variants.first
    assert_equal "default | light", v.theme
    assert_equal({ "--bg" => "#fff", "--text" => "#000" }, v.decls)
  end

  def test_identical_dark_variants_collapse_into_one
    model = build(
      '@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #000; --text: #fff; } } ' \
      ':root[data-theme="dark"] { --bg: #000; --text: #fff; }'
    )
    dark_variants = model.variants.select { |v| v.states.any? { |st| st.marker == "dark" } }
    assert_equal 1, dark_variants.size
    states = dark_variants.first.states
    assert_includes states, ColorThemes::State.new(marker: "dark", os: "light")
    assert_includes states, ColorThemes::State.new(marker: "dark", os: "dark")
    assert_equal states.size, dark_variants.first.contexts.uniq.size, "one label per state"
  end

  def test_base_inherited_by_named_theme
    model = build(":root { --bg: #fff; --text: #000; --a: #123; } .dim { --bg: #333; }")
    dim = variant_for(model, "dim")
    refute_nil dim
    assert_equal "#000", dim.decls["--text"], "dim inherits base --text since it does not override it"
    assert_equal "#123", dim.decls["--a"]
  end

  def test_classify_root_bare_is_base
    sheet = ColorCss.parse(":root { --bg: #fff; }")
    decl = sheet.decls.first
    assert_equal [ :base, [] ], ColorThemes.classify(":root", decl)
  end

  def test_classify_data_theme_root_is_theme
    sheet = ColorCss.parse(':root[data-theme="dark"] { --bg: #000; }')
    decl = sheet.decls.first
    kind, name, = ColorThemes.classify(':root[data-theme="dark"]', decl)
    assert_equal :theme, kind
    assert_equal "dark", name
  end

  def test_selector_theme_resolved_per_os_state
    css = ":root { --bg: #fff; --text: #000; } " \
          "@media (prefers-color-scheme: dark) { :root { --bg: #000; --text: #fff; } } " \
          "@media (prefers-color-scheme: light) { :root { --text: #111; } } " \
          '[data-theme="light"] { --bg: #000; }'
    model = build(css)
    pairs = lambda do |marker, os|
      v = variant_at(model, marker, os)
      [ v.decls["--bg"], v.decls["--text"] ]
    end
    assert_equal [ "#fff", "#111" ], pairs.call(nil, "light"), "default page under OS light"
    assert_equal [ "#000", "#fff" ], pairs.call(nil, "dark"), "default page under OS dark"
    assert_equal [ "#000", "#111" ], pairs.call("light", "light"), "light marker under OS light"
    assert_equal [ "#000", "#fff" ], pairs.call("light", "dark"), "light marker under OS dark"
    labels = model.variants.flat_map(&:contexts)
    assert_equal labels.size, labels.uniq.size, "each state labelled distinctly"
  end

  def test_same_name_media_on_theme_selector_unsupported
    css = '@media (prefers-color-scheme: dark) { :root[data-theme="dark"] { --text: #fff; } }'
    model = build(css)
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported
    assert_equal "media condition on a theme selector", unsupported.why
    assert_nil variant_for(model, "dark")
  end

  def test_same_name_media_on_bare_theme_selector_unsupported
    model = build("@media (prefers-color-scheme: dark) { .dark { --text: #fff; } }")
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported
    assert_equal "media condition on a theme selector", unsupported.why
  end

  def test_same_name_media_on_theme_selector_reported_by_color_check
    require_relative "#{File.expand_path('../scripts', __dir__)}/color_check"
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tokens.css")
      File.write(path, ":root { --bg: #fff; --text: #000; } " \
                       '@media (prefers-color-scheme: dark) { :root[data-theme="dark"] { --text: #fff; } }')
      rows = ColorCheck.compute_contrast(path).select { |r| r.theme == "unsupported" }
      assert_equal 1, rows.size
      assert_equal "--text", rows.first.text_token
      refute rows.first.resolved
      assert_includes rows.first.reason, "media condition on a theme selector"
    end
  end

  def test_unrecognized_context_without_text_role_is_still_recorded
    model = build(".card .title { --surface: #eee; }")
    unsupported = model.unsupported.find { |u| u.decls.key?("--surface") }
    refute_nil unsupported
    assert_equal "not a recognized theme context", unsupported.why
  end

  def test_malformed_layer_frame_is_unsupported
    model = build("@layer a b { :root { --text: #000; } }")
    unsupported = model.unsupported.find { |u| u.decls.key?("--text") }
    refute_nil unsupported, model.inspect
    assert_includes unsupported.why, "inside @layer"
  end

  # Layer order is fixed by source position, not line: every variant puts
  # blocks and ordering statements on one line, so a line-only sort would
  # misplace each statement.
  def test_layer_order_uses_source_position_on_one_line
    cases = {
      "@layer a { :root {--bg:#fff;--text:#000} } @layer b { :root {--text:#fff} } @layer b,a;" => "#fff",
      "@layer b,a; @layer a { :root {--bg:#fff;--text:#000} } @layer b { :root {--text:#fff} }" => "#000",
      "@layer a { :root {--text:#000} } @import url(x.css) layer(b); @layer b { :root {--text:#fff} }" => "#fff",
      "@layer p { @layer a { :root {--text:#000} } @layer b { :root {--text:#fff} } @layer b, a; }" => "#fff",
      "@layer p { @layer b, a; @layer a { :root {--text:#000} } @layer b { :root {--text:#fff} } }" => "#000"
    }
    cases.each do |css, want|
      assert_equal want, variant_for(build(css), "default").decls["--text"], css
    end
  end

  # The reproduction from the theme-state-model plan: the unmarked page under
  # OS light (#000 on #fff) used to be hidden behind the explicit light
  # marker. Every page state is now audited on its own. Under OS dark the
  # :root:not([data-theme=light]) block (specificity 0,2,0) outranks the
  # bare [data-theme=dark] rule (0,1,0), so dark/dark shares default/dark.
  def test_every_page_state_audited_for_marker_and_os_sheet
    model = build(
      ":root{--text:#000;--bg:#fff}\n[data-theme=light]{--bg:#eee}\n" \
      "[data-theme=dark]{--text:#fff;--bg:#000}\n" \
      "@media (prefers-color-scheme: dark){:root:not([data-theme=light]){--text:#ccc;--bg:#111}}\n"
    )
    got = model.variants.map { |v| [ v.states.map { |st| [ st.marker, st.os ] }, v.decls["--text"], v.decls["--bg"] ] }
    expected = [
      [ [ [ nil, "light" ] ], "#000", "#fff" ],
      [ [ [ nil, "dark" ], [ "dark", "dark" ] ], "#ccc", "#111" ],
      [ [ [ "light", "light" ], [ "light", "dark" ] ], "#000", "#eee" ],
      [ [ [ "dark", "light" ] ], "#fff", "#000" ]
    ]
    assert_equal expected.sort_by(&:inspect), got.sort_by(&:inspect)
    assert_equal "default", variant_at(model, nil, "light").theme
    assert_equal "light", variant_at(model, "light", "dark").theme
  end

  # A theme named only inside :not(...) must still be audited, for every
  # exclusion form: class, data-theme attr, and inside a scheme media block.
  def test_excluded_only_theme_names_are_audited
    {
      ":root { --bg:#000; --text:#000 } :root:not(.dark) { --bg:#fff }" => "dark",
      ':root { --bg:#000; --text:#000 } :root:not([data-theme="dim"]) { --bg:#fff }' => "dim",
      ":root { --text:#000 } @media (prefers-color-scheme: dark) { :root:not(.hc) { --bg:#fff } }" => "hc"
    }.each do |css, name|
      model = build(css)
      v = variant_at(model, name) || variant_at(model, name, "dark")
      refute_nil v, "#{name} state missing for #{css}"
      refute_equal "#fff", v.decls["--bg"], css
    end
  end
end
