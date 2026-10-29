# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/walkthrough_cache"

class WalkthroughCacheTest < Minitest::Test
  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.rm_rf(@dir)

  def test_canonical_json_sorts_keys_without_whitespace
    assert_equal '{"a":1,"b":{"c":[2,{"d":3,"e":4}]}}',
                 WalkthroughCache.canonical_json(b: { c: [ 2, { e: 4, d: 3 } ] }, a: 1)
  end

  def test_key_is_stable_across_hash_ordering
    one = { "voice" => "v1", "text" => "hi", "settings" => { "x" => 1, "y" => 2 } }
    two = { "settings" => { "y" => 2, "x" => 1 }, "text" => "hi", "voice" => "v1" }
    assert_equal WalkthroughCache.key(one), WalkthroughCache.key(two)
    assert_match(/\A\h{64}\z/, WalkthroughCache.key(one))
    refute_equal WalkthroughCache.key(one), WalkthroughCache.key(one.merge("text" => "bye"))
  end

  def test_path_layout
    assert_equal File.join(@dir, "audio", "abc.mp3"), WalkthroughCache.path(@dir, :audio, "abc", ".mp3")
  end

  def test_fetch_writes_once_then_returns_cached
    calls = 0
    first = WalkthroughCache.fetch(@dir, "images", "k1", "png") do |tmp|
      calls += 1
      File.write(tmp, "data")
    end
    second = WalkthroughCache.fetch(@dir, "images", "k1", "png") { calls += 1 }
    assert_equal first, second
    assert_equal 1, calls
    assert_equal "data", File.read(first)
    assert_empty Dir.glob(File.join(@dir, "images", "*.tmp-*"))
  end

  def test_fetch_failure_leaves_no_entry
    assert_raises(RuntimeError) do
      WalkthroughCache.fetch(@dir, "audio", "k2", "mp3") do |tmp|
        File.write(tmp, "partial")
        raise "boom"
      end
    end
    refute File.exist?(WalkthroughCache.path(@dir, "audio", "k2", "mp3"))
    assert_empty Dir.glob(File.join(@dir, "audio", "*"))
  end

  def test_fetch_raises_when_producer_writes_nothing
    assert_raises(IOError) { WalkthroughCache.fetch(@dir, "music", "k3", "mp3") { nil } }
  end

  def test_ensure_gitignore_is_idempotent_and_appends
    expected = WalkthroughCache::GITIGNORE_LINES.join("\n")
    wt = File.join(@dir, "walkthrough", "demo")
    file = WalkthroughCache.ensure_gitignore(wt)
    WalkthroughCache.ensure_gitignore(wt)
    assert_equal "#{expected}\n", File.read(file)
    assert_equal [ ".cache/", "flats/", "*.mp4", "overview*.png" ], expected.lines.map(&:strip)

    other = File.join(@dir, "other")
    FileUtils.mkdir_p(other)
    File.write(File.join(other, ".gitignore"), "tmp/")
    WalkthroughCache.ensure_gitignore(other)
    assert_equal "tmp/\n#{expected}\n", File.read(File.join(other, ".gitignore"))
  end

  def test_ignore_file_adds_only_missing_lines
    wt = File.join(@dir, "partial")
    FileUtils.mkdir_p(wt)
    File.write(File.join(wt, ".gitignore"), ".cache/\n")
    WalkthroughCache.ensure_gitignore(wt)
    lines = File.read(File.join(wt, ".gitignore")).lines.map(&:strip)
    assert_equal 1, lines.count(".cache/")
    assert_includes lines, "flats/"
  end
end
