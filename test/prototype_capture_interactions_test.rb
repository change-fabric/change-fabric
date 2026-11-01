# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/prototype_capture"
require_relative "../scripts/walkthrough_storyboard"

# key, dblclick, and pixel-delta scroll ops, plus asset_path containment.
class PrototypeCaptureInteractionsTest < Minitest::Test
  def write(dir, name, body)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  def test_key_chord_normalizes_aliases_and_orders_modifiers_first
    assert_equal [ "Enter" ], PrototypeCapture.key_chord("Enter")
    assert_equal %w[Control c], PrototypeCapture.key_chord("Control+c")
    assert_equal %w[Control Shift Escape], PrototypeCapture.key_chord("Ctrl+Shift+Esc")
    assert_equal [ "+" ], PrototypeCapture.key_chord("+")
    assert_equal %w[Control +], PrototypeCapture.key_chord("Control++")
    [ "", "Banana", "Enter+c", "Control+Nope" ].each do |bad|
      assert_raises(ArgumentError, bad) { PrototypeCapture.key_chord(bad) }
    end
  end

  def test_schedule_places_key_dblclick_and_scroll_on_their_frames
    plan = PrototypeCapture.schedule([
      { "t_ms" => 0, "op" => "scroll", "target" => "#doc", "dy" => 480 },
      { "t_ms" => 100, "op" => "dblclick", "target" => "#file" },
      { "t_ms" => 200, "op" => "key", "keys" => "Control+S", "target" => "#editor" },
      { "t_ms" => 200, "op" => "key", "keys" => "Enter" },
      { "t_ms" => 300, "op" => "scroll", "target" => "#row" }
    ], 20)
    assert_equal({ "target" => "#doc", "dy" => 480 }, plan[0]["scroll"])
    assert_equal "#file", plan[3]["dblclick"]
    assert_equal [ { "keys" => %w[Control S], "target" => "#editor" }, { "keys" => [ "Enter" ] } ], plan[6]["key"]
    assert_equal({ "target" => "#row" }, plan[9]["scroll"])
  end

  def test_function_module_dispatches_new_ops_through_real_input
    mod = PrototypeCapture.function_module(html: "<p>hi</p>", plan: [ { "frame" => 0 } ], range: 0...1,
                                           viewport: nil, prng_seed: 1, state: {})
    [ "clickCount: 2", "page.keyboard.down(m)", "page.keyboard.press(", "page.keyboard.up(m)",
      "el.scrollBy({ left: s.dx || 0, top: s.dy || 0, behavior: \"instant\" })",
      "scrollIntoView({ block: s.block || \"center\", behavior: \"instant\" })" ].each { |needle| assert_includes mod, needle }
  end

  def test_storyboard_validates_new_op_shapes
    ok = [ { "t_ms" => 0, "op" => "key", "keys" => "Enter" },
           { "t_ms" => 10, "op" => "dblclick", "target" => "#a" },
           { "t_ms" => 20, "op" => "scroll", "target" => "#a", "dx" => 0, "dy" => -120 } ]
    assert_empty WalkthroughStoryboard.interaction_errors(ok)
    bad = [ { "t_ms" => 0, "op" => "key", "keys" => "Hyper+Q" },
            { "t_ms" => 10, "op" => "dblclick" },
            { "t_ms" => 20, "op" => "scroll", "target" => "#a", "dy" => 1.5 } ]
    errs = WalkthroughStoryboard.interaction_errors(bad)
    assert(errs.any? { |e| e.include?("interaction 0") && e.include?("not a modifier") })
    assert(errs.any? { |e| e.include?("target is required for dblclick") })
    assert(errs.any? { |e| e.include?("scroll dy must be an integer") })
  end

  def test_asset_path_rejects_refs_outside_the_slug_dir
    Dir.mktmpdir do |base|
      slug = File.join(base, "slug")
      write(base, "secret.txt", "nope")
      write(slug, "tokens.css", ":root{}")
      write(slug, "assets/a.svg", "<svg/>")
      screens = File.join(slug, "screens")
      ok = write(slug, "screens/ok.html", "<link rel='stylesheet' href='../tokens.css'><img src='../assets/a.svg'>")
      assert_includes PrototypeCapture.inline_screen(ok), "<style>:root{}</style>"
      escape = write(slug, "screens/bad.html", "<img src='../../secret.txt'>")
      err = assert_raises(PrototypeCapture::UnsupportedContentError) { PrototypeCapture.inline_screen(escape) }
      assert_includes err.message, "resolves outside"
      File.symlink(File.join(base, "secret.txt"), File.join(slug, "link.txt"))
      assert_raises(PrototypeCapture::UnsupportedContentError) { PrototypeCapture.asset_path(screens, "../link.txt") }
      css = write(slug, "screens/css.html", "<div style=\"background:url(../../secret.txt)\"></div>")
      assert_raises(PrototypeCapture::UnsupportedContentError) { PrototypeCapture.inline_screen(css) }
      assert_equal File.join(slug, "tokens.css"), PrototypeCapture.asset_path(screens, "../tokens.css", slug)
    end
  end
end
