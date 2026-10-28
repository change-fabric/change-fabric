# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../scripts/prototype_flats"

# cf:prototype flats with browserless stubbed: no docker, no browser.
class PrototypeFlatsTest < Minitest::Test
  F = PrototypeFlats
  FLAT_NAMES = %w[01-loans-list-empty 02-loans-list 03-settings-profile-page].freeze

  # Answers a per-flat module with 1x and 2x shots, and the board module with
  # one image. Records every module posted.
  class FakeSession
    attr_reader :modules

    def initialize = @modules = []

    def run_function(code)
      @modules << code
      if code.include?("const shots")
        { "shots" => { "1x" => Base64.strict_encode64("one"), "2x" => Base64.strict_encode64("two"),
                      "thumb" => Base64.strict_encode64("thumb") },
          "blockedRequests" => [], "pageErrors" => [] }
      else
        { "png" => Base64.strict_encode64("board"), "blockedRequests" => [], "pageErrors" => [] }
      end
    end
  end

  MANIFEST = {
    "viewport" => { "w" => 1440, "h" => 900 },
    "flats" => [
      { "section" => "Loans", "screen" => "List", "state" => "empty", "html" => "screens/loans-empty.html",
        "purpose" => "Shows a first-run shelf with nothing lent.", "goal" => "Know what is out on loan",
        "requirements" => [ "TOOL-01", "TOOL-02" ] },
      { "section" => "Loans", "screen" => "List", "state" => "default", "html" => "screens/loans.html",
        "purpose" => "Lists every open loan.", "goal" => "Know what is out on loan", "requirements" => [ "TOOL-01" ] },
      { "section" => "Settings", "screen" => "Profile Page", "html" => "screens/settings.html",
        "purpose" => "Edits the lender profile.", "goal" => "Keep my details current" }
    ]
  }.freeze

  def with_root
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "screens"))
      %w[loans-empty loans settings].each { |n| File.write(File.join(root, "screens", "#{n}.html"), "<p>#{n}</p>") }
      File.write(File.join(root, "flats.json"), JSON.generate(MANIFEST))
      yield root
    end
  end

  def test_names_are_numbered_in_flow_order_and_slugged
    names = F.entries(MANIFEST).map { |e| e[:name] }
    assert_equal FLAT_NAMES, names
  end

  def test_load_rejects_bad_manifests
    with_root do |root|
      path = File.join(root, "flats.json")
      good = { "section" => "a", "screen" => "b", "html" => "screens/loans.html", "purpose" => "p", "goal" => "g" }
      [ { "flats" => [] },
        { "flats" => [ good.reject { |k, _| k == "screen" } ] },
        { "flats" => [ good.reject { |k, _| k == "purpose" } ] },
        { "flats" => [ good.reject { |k, _| k == "goal" } ] },
        { "flats" => [ good.merge("requirements" => "TOOL-01") ] },
        { "flats" => [ good.merge("html" => "screens/nope.html") ] } ].each do |bad|
        File.write(path, JSON.generate(bad))
        assert_raises(ArgumentError) { F.load_manifest(path) }
      end
      File.write(path, JSON.generate("flats" => [ good ]))
      assert_equal 1, F.load_manifest(path)["flats"].size
    end
  end

  def test_theme_module_sets_attribute_and_media_and_both_scales
    mod = F.function_module(html: "<p/>", theme: "dark", viewport: { "w" => 1440, "h" => 900 }, state: {}, prng_seed: 1)
    assert_includes mod, 'setAttribute("data-theme", theme)'
    assert_includes mod, 'const theme = "dark"'
    assert_includes mod, "prefers-color-scheme"
    assert_includes mod, "deviceScaleFactor: 1"
    assert_includes mod, "deviceScaleFactor: 2"
    assert_includes mod, "width: 1440"
  end

  def test_seed_locale_and_clock_are_inlined_ahead_of_screen_scripts
    html = "<html><head><script>app()</script></head><body></body></html>"
    [ F.function_module(html: html, theme: "light", viewport: nil, state: { "k" => "seeded" }, prng_seed: 1),
      PrototypeCapture.function_module(html: html, plan: [ { "frame" => 0 } ], range: 0...1, viewport: nil,
                                       prng_seed: 1, state: { "k" => "seeded" }) ].each do |mod|
      refute_includes mod, "evaluateOnNewDocument"
      %w[__CF_SEED__ seeded navigator __cfAdvance].each do |needle|
        assert_operator mod.index(needle), :<, mod.index("app()"), needle
      end
    end
  end

  def test_run_writes_both_themes_both_scales_and_boards
    with_root do |root|
      session = FakeSession.new
      out = F.run(session: session, root: root)
      assert_equal File.join(root, "flats"), out
      F::THEMES.each do |theme|
        FLAT_NAMES.each do |n|
          assert_equal "one", File.read(File.join(out, theme, "#{n}.png"))
          assert_equal "two", File.read(File.join(out, theme, "#{n}@2x.png"))
        end
        assert_equal "board", File.read(File.join(out, theme, "overview.png"))
      end
      themes = session.modules.grep(/const shots/).map { |m| m[/const theme = "(\w+)"/, 1] }
      assert_equal %w[light light light dark dark dark], themes
      assert_equal 8, session.modules.size
    end
  end

  def test_index_is_a_contextual_toc
    with_root do |root|
      F.run(session: FakeSession.new, root: root)
      index = File.read(File.join(root, "flats", "index.md"))
      lines = index.lines.map(&:chomp)
      assert_equal "# Flats", lines.first
      assert_includes index, "[Overview, light](light/overview.png)"
      assert_includes index, "[Overview, dark](dark/overview.png)"
      assert_operator index.index("(light/overview.png)"), :<, index.index("## Loans")
      assert_operator index.index("## Loans"), :<, index.index("## Settings")
      assert_equal 1, index.scan("## Loans").size
      assert_includes index, "### List (empty)"
      assert_includes index, "Purpose: Shows a first-run shelf with nothing lent."
      assert_includes index, "User goal: Know what is out on loan"
      assert_includes index, "Requirements: TOOL-01, TOOL-02"
      assert_includes index, "Requirements: none"
      assert_includes index, "Source: `screens/loans-empty.html`"
      assert_includes index, "[Light](light/01-loans-list-empty.png) ([2x](light/01-loans-list-empty@2x.png))"
      assert_includes index, "[Dark](dark/01-loans-list-empty.png) ([2x](dark/01-loans-list-empty@2x.png))"
      assert_includes index, "### Profile Page (default)"
    end
  end

  def test_board_html_groups_by_section_in_order_with_data_uris
    shots = F.entries(MANIFEST).map { |e| e.merge(thumb: "x") }
    html = F.board_html(shots, theme: "dark")
    assert_operator html.index("Loans"), :<, html.index("Settings")
    assert_equal 3, html.scan("data:image/jpeg;base64,").size
    assert_includes html, 'data-theme="dark"'
    assert_equal 1, html.scan(%r{<h2>Loans</h2>}).size
  end

  def test_board_embeds_small_jpeg_thumbnails_not_full_pngs
    mod = F.function_module(html: "<p/>", theme: "light", viewport: { "w" => 1440, "h" => 900 }, state: {}, prng_seed: 1)
    assert_includes mod, 'type: "jpeg"'
    assert_includes mod, "deviceScaleFactor: #{F.thumb_scale(1440)}"
    assert_in_delta 880, 1440 * F.thumb_scale(1440), 1
    with_root do |root|
      session = FakeSession.new
      F.run(session: session, root: root)
      boards = session.modules.reject { |m| m.include?("const shots") }
      boards.each do |m|
        assert_includes m, Base64.strict_encode64("thumb")
        refute_includes m, Base64.strict_encode64("one")
        assert_operator m.bytesize, :<, 10 * 1024 * 1024
      end
    end
  end

  def test_blocked_request_fails_loudly
    with_root do |root|
      bad = Object.new
      def bad.run_function(_code) = { "shots" => {}, "blockedRequests" => [ { "url" => "http://x" } ], "pageErrors" => [] }
      assert_raises(PrototypeCapture::UnsupportedContentError) { F.run(session: bad, root: root) }
    end
  end

  def test_run_ignores_flats_output_in_git
    with_root do |root|
      F.run(session: FakeSession.new, root: root)
      ignore = File.read(File.join(root, ".gitignore")).lines.map(&:strip)
      assert_includes ignore, "flats/"
    end
  end
end
