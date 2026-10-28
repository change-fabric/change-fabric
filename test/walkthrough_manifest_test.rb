# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/walkthrough_manifest"

class WalkthroughManifestTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "screens"))
    File.write(File.join(@root, "screens", "a.html"), "<html><body>a</body></html>")
  end

  def teardown = FileUtils.rm_rf(@root)

  def scene(id, order, measured)
    { "id" => id, "order" => order, "title" => id, "screen" => { "html" => "screens/a.html" },
      "narration" => { "text" => id, "measured_ms" => measured },
      "assumptions" => [ { "id" => "A-0#{order}", "text" => "x" } ],
      "timing" => { "min_ms" => 1000, "pad_ms" => 0 } }
  end

  def board
    { "schema_version" => 1, "slug" => "demo", "title" => "Demo", "fps" => 30,
      "voice" => { "voice_id" => "v1", "model" => "eleven_multilingual_v2", "output_format" => "mp3_44100_128" },
      "music" => { "model" => "music_v1", "prompt" => "calm", "gain_db" => -18 },
      "scenes" => [ scene("one", 1, 2000), scene("two", 2, 500) ] }
  end

  def test_build_contents
    m = WalkthroughManifest.build(board, @root)
    assert_equal 1, m["schema_version"]
    assert_equal ChangeDocker::BROWSERLESS_IMAGE, m["images"]["browserless"]
    assert_equal ChangeDocker::FFMPEG_IMAGE, m["images"]["ffmpeg"]
    assert_equal ChangeDocker::NODE_IMAGE, m["images"]["node"]
    assert_equal ChangeDocker::PHOSPHOR_PKG[:integrity], m["icons"]["phosphor"]["integrity"]
    assert_equal ChangeDocker::SIMPLE_ICONS_PKG[:version], m["icons"]["simple_icons"]["version"]
    assert_equal "eleven_multilingual_v2", m["models"]["voice"]
    assert_equal "music_v1", m["models"]["music"]
    assert_equal [ [ "one", 0, 60, 2000 ], [ "two", 60, 30, 1000 ] ],
                 m["scenes"].map { |s| s.values_at("id", "start_frame", "frames", "duration_ms") }
    assert_equal({ "fps" => 30, "total_frames" => 90, "total_ms" => 3000 }, m["timeline"])
    assert_match(/\A\h{64}\z/, m["scenes"][0]["frames_key"])
    assert_equal WalkthroughManifest.music_key(board, 3000), m["music_key"]
    assert_equal WalkthroughManifest.manifest_hash(m), m["manifest_hash"]
  end

  def test_manifest_hash_stable_across_key_ordering
    m = WalkthroughManifest.build(board, @root)
    reversed = m.to_a.reverse.to_h.transform_values { |v| v.is_a?(Hash) ? v.to_a.reverse.to_h : v }
    assert_equal WalkthroughManifest.manifest_hash(m), WalkthroughManifest.manifest_hash(reversed)
    assert_equal m["manifest_hash"], WalkthroughManifest.build(JSON.parse(JSON.generate(board)), @root)["manifest_hash"]
  end

  def test_timeline_change_changes_music_key_and_hash
    a = WalkthroughManifest.build(board, @root)
    b2 = board
    b2["scenes"][1]["narration"]["measured_ms"] = 5000
    b = WalkthroughManifest.build(b2, @root)
    refute_equal a["music_key"], b["music_key"]
    refute_equal a["manifest_hash"], b["manifest_hash"]
    assert_equal a["scenes"][0], b["scenes"][0]
  end

  def test_write
    path = WalkthroughManifest.write(WalkthroughManifest.build(board, @root), @root)
    assert_equal "manifest.json", File.basename(path)
    assert_equal 1, JSON.parse(File.read(path))["schema_version"]
  end
end
