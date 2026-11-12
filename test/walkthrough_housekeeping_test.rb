# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../scripts/walkthrough_housekeeping"

class WalkthroughHousekeepingTest < Minitest::Test
  H = WalkthroughHousekeeping
  ENV0 = {}.freeze

  def setup
    @tmp = Dir.mktmpdir
    @root = File.join(@tmp, "walkthrough", "demo")
    @cache = File.join(@root, ".cache")
    @outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p([ @cache, @outside ])
    File.binwrite(File.join(@outside, "precious.mp4"), "keep me")
    {
      "render/current/walkthrough.mp4" => "cur", "render/current-burn/walkthrough.mp4" => "burn",
      "render/old1/walkthrough.mp4" => "o" * 100, "render/old2/frame.png" => "o" * 50,
      "frames/live/000001.png" => "f", "frames/dead/000001.png" => "d" * 30,
      "stills/list/000001.png" => "s", "stills/gone/000001.png" => "g",
      "audio/a.mp3" => "a", "music/m.mp3" => "m", "images/i.png" => "i", "broll/b.mp4" => "b",
      "roasts/new.json" => "n", "roasts/old.json" => "r" * 10
    }.each do |rel, body|
      path = File.join(@cache, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
    old = Time.now - (30 * 86_400)
    File.utime(old, old, File.join(@cache, "roasts", "old.json"))
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def keep = { render: %w[current current-burn], frames: %w[live], stills: %w[list] }

  def dropped(plan) = plan.drop.map { |e| e[:path].delete_prefix("#{File.realpath(@cache)}/") }.sort

  def test_prune_keeps_current_audio_and_live_scenes_and_drops_superseded
    plan = H.plan(@root, keep: keep, env: ENV0)
    assert_equal %w[frames/dead render/old1 render/old2 roasts/old.json stills/gone], dropped(plan)
    assert_equal 100 + 50 + 30 + 10 + 1, plan.bytes
    H.apply!(plan, @root, ENV0)
    %w[render/current render/current-burn frames/live stills/list audio/a.mp3 music/m.mp3 images/i.png broll/b.mp4 roasts/new.json].each do |rel|
      assert File.exist?(File.join(@cache, rel)), rel
    end
    %w[render/old1 frames/dead stills/gone roasts/old.json].each { |rel| refute File.exist?(File.join(@cache, rel)), rel }
  end

  def test_a_nil_keep_category_keeps_all_of_it
    plan = H.plan(@root, keep: { render: nil, frames: nil, stills: %w[list] }, env: ENV0)
    assert_equal %w[roasts/old.json stills/gone], dropped(plan)
  end

  def test_retention_is_configurable
    plan = H.plan(@root, keep: keep, env: { H::RETENTION_ENV => "60" })
    refute_includes dropped(plan), "roasts/old.json"
  end

  def test_dry_run_deletes_nothing
    before = Dir.glob(File.join(@cache, "**", "*"), File::FNM_DOTMATCH).sort
    plan = H.plan(@root, keep: keep, env: ENV0)
    lines = H.describe(plan, dry_run: true)
    assert_equal before, Dir.glob(File.join(@cache, "**", "*"), File::FNM_DOTMATCH).sort
    assert_includes lines.last, "would drop 5 entries"
    assert_includes lines.last, "(dry run)"
    assert(lines.any? { |l| l.start_with?("would drop render old1 100 B") })
  end

  def test_symlink_escape_is_refused
    File.symlink(@outside, File.join(@cache, "render", "escape"))
    File.symlink(@outside, File.join(@cache, "frames", "escape"))
    File.symlink(@outside, File.join(@cache, "roasts-link"))
    plan = H.plan(@root, keep: keep, env: ENV0)
    refute(dropped(plan).any? { |p| p.include?("escape") })
    assert_equal 3, plan.refused.size
    H.apply!(plan, @root, ENV0)
    assert_equal "keep me", File.binread(File.join(@outside, "precious.mp4"))
    assert File.symlink?(File.join(@cache, "render", "escape")), "the link itself is left alone too"
  end

  def test_a_symlinked_category_is_never_walked
    FileUtils.rm_rf(File.join(@cache, "stills"))
    File.symlink(@outside, File.join(@cache, "stills"))
    plan = H.plan(@root, keep: keep, env: ENV0)
    H.apply!(plan, @root, ENV0)
    assert_equal "keep me", File.binread(File.join(@outside, "precious.mp4"))
    assert_includes plan.refused, File.join(File.realpath(@cache), "stills")
  end

  def test_a_foreign_cache_symlink_is_refused
    FileUtils.rm_rf(@cache)
    File.symlink(@outside, @cache)
    assert_raises(H::Error) { H.plan(@root, keep: keep, env: ENV0) }
    assert_equal "keep me", File.binread(File.join(@outside, "precious.mp4"))
  end

  def test_cache_root_override_links_to_a_stable_key
    ext = File.join(@tmp, "ext")
    FileUtils.rm_rf(@cache)
    env = { H::CACHE_ROOT_ENV => ext }
    notes = H.ensure_location!(@root, env)
    target = File.join(File.realpath(ext), H.cache_key(@root))
    assert_match(/\Ademo-\h{16}\z/, H.cache_key(@root))
    assert_equal target, File.realpath(@cache)
    assert_includes notes.first, target
    assert_empty H.ensure_location!(@root, env), "idempotent"
    FileUtils.mkdir_p(File.join(@cache, "render", "old"))
    plan = H.plan(@root, keep: keep, env: env)
    assert_equal %w[render/old], dropped(plan)
    assert_raises(H::Error) { H.ensure_location!(@root, { H::CACHE_ROOT_ENV => File.join(@tmp, "other") }) }
  end

  def test_override_leaves_a_real_in_tree_cache_alone
    notes = H.ensure_location!(@root, { H::CACHE_ROOT_ENV => File.join(@tmp, "ext") })
    assert_includes notes.first, "is a real dir"
    refute File.symlink?(@cache)
  end

  def test_report_sizes_each_category
    File.binwrite(File.join(@cache, "stray.tmp"), "xy")
    sizes = H.report(@root, ENV0)
    assert_equal 3 + 4 + 100 + 50, sizes["render"]
    assert_equal 1, sizes["audio"]
    assert_equal 2, sizes["other"]
  end

  def test_size_warning_threshold
    assert_nil H.size_warning(@root, ENV0)
    warning = H.size_warning(@root, { H::WARN_ENV => "0.0000001" })
    assert_includes warning, "--prune --dry-run"
    assert_includes warning, H::CACHE_ROOT_ENV
  end

  def test_deliver_writes_atomically_and_survives_the_cache
    dir = File.join(@cache, "render", "current")
    File.write(File.join(dir, "walkthrough.vtt"), "WEBVTT\n")
    paths = H.deliver(@root, "demo", File.join(dir, "walkthrough.mp4"), final: true)
    assert_equal({ mp4: File.join(@root, "demo-final.mp4"), vtt: File.join(@root, "demo-final.vtt") }, paths)
    FileUtils.rm_rf(@cache)
    assert_equal "cur", File.binread(paths[:mp4])
    assert_equal "WEBVTT\n", File.read(paths[:vtt])
    assert_equal %w[demo-final.mp4 demo-final.vtt], Dir.children(@root).sort
  end
end
