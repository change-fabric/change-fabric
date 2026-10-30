# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_assumptions"
require_relative "../scripts/walkthrough_environment"
require_relative "../scripts/walkthrough_storyboard"

# The environment kind: the committed desktop fixture validates and matches
# the generator, fixed ids follow the kit contract, drift and stale screens
# fail validation, seeds follow desktop.schema.json, and the kit version is
# frames_key material.
class WalkthroughEnvironmentTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/walkthrough/desktop", __dir__)
  KIT = File.expand_path("../skills/prototype/fixtures/desktop", __dir__)

  def setup
    @root = Dir.mktmpdir
    FileUtils.cp_r("#{FIXTURE}/.", @root)
  end

  def teardown = FileUtils.rm_rf(@root)

  def board = WalkthroughStoryboard.load(File.join(@root, "storyboard.json"))

  def scene(id) = board["scenes"].find { |s| s["id"] == id }

  def errs = WalkthroughStoryboard.validate(board, root: @root)

  def screen(id) = File.read(File.join(@root, "screens", "#{id}.html"))

  def test_fixture_validates_and_is_current
    assert_empty WalkthroughStoryboard.validate(WalkthroughStoryboard.load(File.join(FIXTURE, "storyboard.json")), root: FIXTURE)
    board["scenes"].each { |s| assert_equal WalkthroughEnvironment.screen(s, @root), screen(s["id"]), s["id"] }
  end

  def test_fixture_covers_the_install_beats
    ids = board["scenes"].to_h { |s| [ s["id"], WalkthroughEnvironment.ids_in(screen(s["id"])) ] }
    assert_includes ids["download"], "docs-download-northwind-agent-win-zip"
    assert_includes ids["download"], "docs-content"
    assert_includes ids["extract"], "explorer-extract"
    assert_includes ids["extract"], "explorer-xfile-config-json"
    assert_includes ids["edit-config"], "editor-text"
    assert_includes ids["edit-config"], "editor-saved"
    assert_match(/data-cfd-caret="&quot;api_key&quot;: &quot;"/, screen("edit-config"))
    assert_includes ids["install"], "elevate-yes"
    assert_includes ids["install"], "services-svc-northwind-agent-status"
    assert_match(/data-cfd-service="northwind-agent" data-cfd-status="Running"/, screen("install"))
    assert_match(/data-cf-slot="docs-content"><article/, screen("download"))
  end

  def test_fixed_ids_and_visibility
    html = screen("install")
    %w[desktop taskbar taskbar-clock win-explorer win-explorer-title win-explorer-min win-explorer-close task-explorer
       explorer-file-install-northwind-service-bat term-lines term-line-4 elevate-no].each do |id|
      assert_includes WalkthroughEnvironment.ids_in(html), id
    end
    assert_match(/id="win-elevate"[^>]* hidden/, html, "a window outside environment.open renders hidden")
    refute_match(/id="win-explorer"[^>]* hidden/, html)
    assert_match(/id="win-explorer" class="cfd-win cfd-focus"/, html)
    assert_match(/data-cfd-open="elevate"/, html)
    assert_includes html, "cf desktop kit v#{WalkthroughEnvironment.version}"
  end

  def test_drift_and_stale_screens_fail
    path = File.join(@root, "screens", "install.html")
    original = screen("install")
    File.write(path, original.sub('id="elevate-yes"', 'id="allow"'))
    assert(errs.any? { |e| e.include?("drifted from the desktop kit ids (missing: elevate-yes; extra: allow)") }, errs.inspect)
    File.write(path, original.sub("9:46 AM", "9:47 AM"))
    assert(errs.any? { |e| e.include?("screens/install.html is stale") }, errs.inspect)
    File.delete(path)
    assert(errs.any? { |e| e.include?("does not exist; run walkthrough_environment.rb") }, errs.inspect)
    WalkthroughEnvironment.write_screens(board, @root)
    assert_empty errs
  end

  def test_spec_and_seed_validation
    base = scene("install")
    {
      "environment has unknown keys: theme" => base.merge("environment" => { "theme" => "dark" }),
      "environment.open names unknown windows: ghost" => base.merge("environment" => { "open" => [ "ghost" ] }),
      "environment.focus \"term\" must be an open window" => base.merge("environment" => { "open" => [ "explorer" ], "focus" => "term" }),
      "is not a browser content slot" => base.merge("environment" => { "slots" => { "explorer-content" => "screens/partials/docs.html" } }),
      "an environment scene needs store.seed" => base.merge("store" => {}),
      "store.seed must be inside the walkthrough directory" => base.merge("store" => { "seed" => "../x.json" })
    }.each do |want, s|
      got = WalkthroughEnvironment.errors(s, @root)
      assert(got.any? { |e| e.include?(want) }, "#{want}: #{got}")
    end
    seed = JSON.parse(File.read(File.join(@root, "data", "install.json")))
    seed["windows"] << { "id" => "Bad", "type" => "dock", "title" => "", "x" => -1, "y" => 0, "w" => 1, "h" => 1 }
    seed["windows"][1]["then"] = "nowhere"
    got = WalkthroughEnvironment.seed_errors(seed)
    [ "id must match", "type must be one of", "title is required", "x must be a non-negative integer", "then must name a window" ].each do |want|
      assert(got.any? { |e| e.include?(want) }, "#{want}: #{got}")
    end
  end

  def test_schema_matches_the_validator
    schema = JSON.parse(File.read(File.join(KIT, "desktop.schema.json")))
    assert_equal WalkthroughEnvironment::WINDOW_TYPES, schema.dig("properties", "windows", "items", "properties", "type", "enum")
    assert_equal WalkthroughEnvironment::SEED_KEYS.sort, schema["properties"].keys.sort
    Dir[File.join(FIXTURE, "data", "*.json")].each do |path|
      seed = JSON.parse(File.read(path))
      assert_empty WalkthroughEnvironment.seed_errors(seed), path
      seed["windows"].each { |w| assert_empty w.keys - schema.dig("properties", "windows", "items", "properties").keys, path }
    end
  end

  def test_kit_version_is_frames_key_material
    keys = WalkthroughStoryboard.recompute_keys(board, @root)
    refute_nil keys["install"]["frames_key"]
    real = WalkthroughEnvironment.method(:version)
    WalkthroughEnvironment.define_singleton_method(:version) { "999" }
    refute_equal keys["install"]["frames_key"], WalkthroughStoryboard.recompute_keys(board, @root)["install"]["frames_key"]
  ensure
    WalkthroughEnvironment.define_singleton_method(:version, real) if real
  end

  def test_unknown_kind_message_lists_environment
    got = WalkthroughStoryboard.kind_errors({ "kind" => "desk" }, @root)
    assert_match(/environment/, got.join)
  end

  def test_simulated_ui_lists_environment_scenes
    lines = WalkthroughAssumptions.simulated_ui(board)
    assert_equal 4, lines.size
    assert(lines.all? { |l| l.include?("simulated desktop environment (neutral desktop kit v") })
    assert_includes WalkthroughEnvironment.simulated_line(scene("install"), @root), "file-explorer, elevation-prompt, terminal, services-list"
  end

  def test_kit_is_neutral_and_self_contained
    css = File.read(File.join(KIT, "desktop.css"))
    js = File.read(File.join(KIT, "wm.js"))
    refute_match(/Date\.now|new Date|performance\.now|setInterval/, js, "wm.js reads no clock and only paces with setTimeout")
    refute_match(%r{https?://}, css + js)
    refute_match(/windows 1[01]|segoe|aero|fluent/i, css + Dir[File.join(KIT, "templates", "*.html")].map { |f| File.read(f) }.join)
  end
end
