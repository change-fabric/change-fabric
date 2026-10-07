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

  def test_foreground_is_a_text_role_in_any_position
    assert ColorThemes.text_role_name?("--foreground")
    assert ColorThemes.text_role_name?("--color-foreground-muted")
    assert ColorThemes.text_role_name?("--card-foreground")
  end

  def test_bare_root_is_base
    model = build(":root { --bg: #fff; --text: #000; }")
    v = variant_for(model, "light")
    refute_nil v
    assert_equal({ "--bg" => "#fff", "--text" => "#000" }, v.decls)
    assert_includes v.contexts, ":root"
  end

  def test_html_is_also_base
    model = build("html { --bg: #fff; }")
    v = variant_for(model, "light")
    refute_nil v
    assert_includes v.contexts, "html"
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
    dark = variant_for(model, "dark")
    refute_nil dark
    assert_equal "#000", dark.decls["--bg"]
    assert_equal "#000", dark.decls["--text"], "dark inherits base --text"
  end

  def test_not_qualifier_narrows_and_names_nothing
    model = build(
      '@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #000; --text: #fff; } } ' \
      ':root[data-theme="dark"] { --bg: #000; --text: #fff; }'
    )
    dark = variant_for(model, "dark")
    refute_nil dark
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
    v = variant_for(model, "light")
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
    v = variant_for(model, "light")
    refute_nil v
    assert_equal({ "--bg" => "#fff", "--text" => "#000" }, v.decls)
    assert_equal 1, model.variants.count { |x| x.theme == "light" }, "identical light variants collapse"
  end

  def test_identical_dark_variants_collapse_into_one
    model = build(
      '@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg: #000; --text: #fff; } } ' \
      ':root[data-theme="dark"] { --bg: #000; --text: #fff; }'
    )
    dark_variants = model.variants.select { |v| v.theme == "dark" }
    assert_equal 1, dark_variants.size
    assert_equal 2, dark_variants.first.contexts.size
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
    lights = build(css).variants.select { |v| v.theme == "light" }
    texts = lights.map { |v| [ v.decls["--bg"], v.decls["--text"] ] }.sort
    assert_includes texts, [ "#000", "#000" ], "no-media state keeps base text"
    assert_includes texts, [ "#000", "#111" ], "OS light state"
    assert_includes texts, [ "#000", "#fff" ], "OS dark state"
    assert_equal lights.size, lights.map(&:contexts).uniq.size, "each state labelled distinctly"
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
end
