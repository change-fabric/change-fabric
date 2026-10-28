# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_assumptions"

class WalkthroughAssumptionsTest < Minitest::Test
  def setup = @root = Dir.mktmpdir
  def teardown = FileUtils.rm_rf(@root)

  def board
    { "title" => "Demo", "scenes" => [
      { "id" => "one", "order" => 1, "assumptions" => [ { "id" => "A-01", "text" => "Teams share invoices" },
                                                        { "id" => "A-02", "text" => "Bulk export", "kind" => "invented_feature" } ] },
      { "id" => "two", "order" => 2, "assumptions" => [ { "id" => "A-01", "text" => "Teams share invoices" },
                                                        { "id" => "A-03", "text" => "Twice as fast", "kind" => "unsupported_claim" } ] }
    ] }
  end

  def test_render_sections
    logos = [ { slug: "examplebrand", title: "Examplebrand", guidelines: "https://example.com/brand", license: nil } ]
    md = WalkthroughAssumptions.render(board, seed: { "invoices" => [ 1, 2 ], "customers" => [ 1 ] }, logos: logos)
    assert_includes md, "role plus look-and-feel prototype (Houde and Hill, 1997)"
    assert_includes md, "- A-01: Teams share invoices (scenes: one, two)"
    assert_includes md, "## Invented features\n\n- A-02: Bulk export (scenes: one)"
    assert_includes md, "## Unsupported claims\n\n- A-03: Twice as fast (scenes: two)"
    assert_includes md, "- customers (1 records)"
    assert_includes md, "- invoices (2 records)"
    assert_includes md, "- Examplebrand (examplebrand): guidelines: https://example.com/brand; license: CC0-1.0"
    refute_match(/[\u2014\u2022\u2026\u201c\u201d]/, md)
  end

  def test_logo_with_license_field
    line = WalkthroughAssumptions.logo_line(slug: "x", title: "X", license: { "type" => "CC-BY-4.0", "url" => "https://l" })
    assert_includes line, "license: CC-BY-4.0 https://l"
    assert_includes line, "no guidelines link"
  end

  def test_empty_render
    md = WalkthroughAssumptions.render({ "title" => "T", "scenes" => [] })
    assert_includes md, "No seed data."
    assert_includes md, "None used."
  end

  def test_write_files_from_used_icons
    icons = File.join(@root, "screens", "assets", "icons")
    FileUtils.mkdir_p(icons)
    File.write(File.join(icons, "phosphor-house-regular.svg"), "<svg/>")
    File.write(File.join(icons, "simple-acmelogo.svg"), "<svg/>")
    FileUtils.mkdir_p(File.join(@root, "data"))
    File.write(File.join(@root, "data", "seed.json"), '{"orders":[]}')
    assumptions, notices = WalkthroughAssumptions.write(board, @root)
    md = File.read(assumptions)
    assert_includes md, "- orders (0 records)"
    assert_includes md, "acmelogo"
    text = File.read(notices)
    assert_includes text, "Phosphor Icons"
    assert_includes text, "acmelogo"
  end

  def test_generated_footage_section_lists_each_ai_clip
    b = board
    b["scenes"] << { "id" => "shed", "order" => 3, "kind" => "ai-broll",
                     "broll" => { "source_image" => "screens/assets/shed.png", "prompt" => "slow push in", "seconds" => 4,
                                  "model" => "gemini-omni-1.1-flash", "fallback" => "kenburns" } }
    md = WalkthroughAssumptions.render(b)
    assert_includes md, "## Generated footage"
    assert_includes md, "- shed: AI-generated video (gemini-omni-1.1-flash, 4s, SynthID watermarked) animated from screens/assets/shed.png; " \
                        "prompt: slow push in; fallback: kenburns"
    assert_includes WalkthroughAssumptions.render(board), "## Generated footage\n\nNone."
    refute_match(/[\u2014\u2022\u2026\u201c\u201d]/, md)
  end
end
