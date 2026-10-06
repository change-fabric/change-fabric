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
end
