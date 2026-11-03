# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/diagram_palette"

# Covers DiagramPalette: a token file written with var() and srgb color-mix
# resolves to literal diagram roles for both themes, roles that miss their
# contrast floor fall through to the next candidate, and the token file is
# found through CHANGE.md.
class DiagramPaletteTest < Minitest::Test
  BRAND = <<~CSS
    /* four authored colors */
    :root,
    :root[data-theme="light"] {
      --cream: #f6efe0;
      --plum: #24122a;
      --lilac: #a070c8;
      --sage: #9ea39b;
      --bg: var(--cream);
      --surface: color-mix(in srgb, var(--plum) 3%, var(--cream));
      --border: color-mix(in srgb, var(--sage) 60%, var(--cream));
      --border-strong: color-mix(in srgb, var(--sage) 85%, var(--cream));
      --text: var(--plum);
      --muted: color-mix(in srgb, var(--sage) 42%, var(--plum));
      --accent: color-mix(in srgb, var(--lilac) 62%, var(--plum));
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg: var(--plum);
        --surface: color-mix(in srgb, var(--cream) 4%, var(--plum));
        --text: var(--cream);
        --muted: color-mix(in srgb, var(--sage) 70%, var(--cream));
        --accent: color-mix(in srgb, var(--lilac) 75%, var(--cream));
      }
    }
  CSS

  def with_tokens(css)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "styles.css")
      File.write(path, css)
      yield path, dir
    end
  end

  def with_brand_palette(&)
    with_tokens(BRAND) { |path, _| yield DiagramPalette.resolve(path) }
  end

  def test_resolves_var_and_color_mix_to_hex_for_both_themes
    with_brand_palette do |r|
      assert_equal "#F6EFE0", r.light["--bg"]
      assert_equal "#24122A", r.light["--ink"]
      assert_equal "#714C8C", r.light["--accent"]
      assert_equal "#24122A", r.dark["--bg"]
      assert_equal "#F6EFE0", r.dark["--ink"]
      assert_equal "#B690CE", r.dark["--accent"]
      assert_empty r.warnings
    end
  end

  def test_line_skips_a_border_too_faint_for_a_stroke
    with_brand_palette do |r|
      assert_equal r.light["--muted"], r.light["--line"]
      assert_operator DiagramPalette.contrast(r.light["--line"], r.light["--bg"]), :>=, DiagramPalette::STROKE_MIN
    end
  end

  def test_dark_inherits_light_authored_colors_and_derives_a_tint
    with_brand_palette do |r|
      refute_nil r.dark["--rule"]
      refute_equal r.light["--accent-tint"], r.dark["--accent-tint"]
      assert_includes r.css, "@media (prefers-color-scheme: dark)"
      assert_includes r.hexes, "#714C8C"
    end
  end

  def test_low_contrast_text_is_reported
    with_tokens(":root { --bg: #ffffff; --text: #dddddd; }") do |path|
      assert(DiagramPalette.resolve(path).warnings.any? { |w| w.include?("--ink on --bg") })
    end
  end

  def test_missing_ground_or_ink_is_an_error
    with_tokens(":root { --accent: #ff0000; }") do |path|
      assert_raises(DiagramPalette::Error) { DiagramPalette.resolve(path) }
    end
  end

  def test_locates_tokens_through_change_md
    with_tokens(BRAND) do |_, dir|
      FileUtils.mkdir_p(File.join(dir, "site"))
      FileUtils.mv(File.join(dir, "styles.css"), File.join(dir, "site", "styles.css"))
      File.write(File.join(dir, "CHANGE.md"), "---\nchange_config:\n  design:\n    tokens: site/styles.css\n---\n")
      assert_equal File.join(dir, "site", "styles.css"), DiagramPalette.locate(repo: dir)
    end
  end

  def test_no_token_file_locates_nothing
    Dir.mktmpdir { |dir| assert_nil DiagramPalette.locate(repo: dir) }
  end
end
