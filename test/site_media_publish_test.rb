# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/site_media_publish"

class SiteMediaPublishTest < Minitest::Test
  SRT = "1\n00:00:00,000 --> 00:00:01,500\nHello there.\n\n2\n00:00:01,600 --> 00:00:02,400\nGeneral text.\n"
  ALIGNMENT = {
    "characters" => "Hi you".chars,
    "character_start_times_seconds" => [ 0.0, 0.1, 0.2, 0.3, 0.4, 0.5 ],
    "character_end_times_seconds" => [ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6 ]
  }.freeze

  # Records every call (with the bytes, since derived files live in a temp
  # dir that is gone once publish returns); `present` lists keys the bucket already holds.
  class FakeUploader
    attr_reader :puts_made

    def initialize(present: [])
      @present = present
      @puts_made = []
    end

    def exists?(key) = @present.include?(key)

    def put(path, key, content_type:, cache_control:)
      @puts_made << { body: File.read(path), key: key, content_type: content_type, cache_control: cache_control }
    end
  end

  PROBER = ->(_path) { { duration_ms: 2000, width: 64, height: 36 } }

  def setup
    @dir = Dir.mktmpdir("site-media-test")
    @manifest = File.join(@dir, "manifest.json")
    File.write(@manifest, JSON.pretty_generate("version" => 1, "base" => "/media/", "slots" => {}))
    @video = fixture("final.mp4", "video-bytes")
    @poster = fixture("poster.jpg", "poster-bytes")
    @audio = fixture("sample.mp3", "audio-bytes")
    @srt = fixture("narration.srt", SRT)
    @alignment = fixture("sample.alignment.json", JSON.generate(ALIGNMENT))
  end

  def teardown = FileUtils.rm_rf(@dir)

  def fixture(name, body)
    path = File.join(@dir, name)
    File.write(path, body)
    path
  end

  def video_opts = { slot: "clip", video: @video, poster: @poster, srt: @srt, title: "A clip" }
  def audio_opts = { slot: "sample", audio: @audio, alignment: @alignment, srt: @srt, title: "A sample" }

  def run_publish(opts, uploader: FakeUploader.new)
    SiteMediaPublish.publish(opts, uploader: uploader, prober: PROBER, manifest_path: @manifest, io: StringIO.new)
  end

  def hash12(body) = Digest::SHA256.hexdigest(body)[0, 12]

  def test_names_files_by_the_first_twelve_hex_of_their_sha256
    entry = run_publish(video_opts)
    assert_equal "#{hash12('video-bytes')}.mp4", entry["src"]
    assert_equal "#{hash12('poster-bytes')}.jpg", entry["poster"]
    assert_equal "#{hash12(WalkthroughCaptions.vtt(SRT))}.vtt", entry["vtt"]
    assert_equal 2000, entry["duration_ms"]
    assert_equal [ 64, 36 ], [ entry["width"], entry["height"] ]
    assert_equal "Hello there. General text.", entry["transcript"]
  end

  def test_uploads_each_file_with_its_type_and_immutable_cache_then_writes_the_manifest
    uploader = FakeUploader.new
    entry = run_publish(video_opts, uploader: uploader)
    types = uploader.puts_made.to_h { |call| [ File.extname(call[:key]), call[:content_type] ] }
    assert_equal({ ".mp4" => "video/mp4", ".vtt" => "text/vtt; charset=utf-8", ".jpg" => "image/jpeg" }, types)
    assert(uploader.puts_made.all? { |call| call[:cache_control] == "public, max-age=31536000, immutable" })
    assert(uploader.puts_made.all? { |call| call[:key].start_with?("media/") })
    assert_equal entry, JSON.parse(File.read(@manifest))["slots"]["clip"]
  end

  def test_audio_writes_vtt_and_word_spans_from_the_alignment
    uploader = FakeUploader.new
    entry = run_publish(audio_opts, uploader: uploader)
    words = uploader.puts_made.find { |call| call[:key].end_with?(".json") }
    vtt = uploader.puts_made.find { |call| call[:key].end_with?(".vtt") }
    assert_equal "application/json", words[:content_type]
    assert_equal "audio/mpeg", uploader.puts_made.find { |call| call[:key].end_with?(".mp3") }[:content_type]
    assert_equal({ "text" => "Hi", "start_ms" => 0, "end_ms" => 200 }, JSON.parse(words[:body]).first)
    assert_equal "WEBVTT\n\n", vtt[:body][0, 8]
    assert_nil entry["width"]
    assert_nil entry["poster"]
  end

  def test_a_file_over_its_size_guard_fails_before_any_upload
    File.write(@poster, "x" * (60 * 1024 + 1))
    uploader = FakeUploader.new
    error = assert_raises(SiteMediaPublish::Error) { run_publish(video_opts, uploader: uploader) }
    assert_match(/poster .* over the 61440 byte guard/, error.message)
    assert_empty uploader.puts_made
  end

  def test_skips_a_key_the_bucket_already_holds
    uploader = FakeUploader.new(present: [ "media/#{hash12('video-bytes')}.mp4" ])
    run_publish(video_opts, uploader: uploader)
    refute(uploader.puts_made.any? { |call| call[:key].end_with?(".mp4") })
    assert_equal 2, uploader.puts_made.size
  end

  def test_dry_run_uploads_nothing_and_leaves_the_manifest_alone
    before = File.read(@manifest)
    uploader = FakeUploader.new
    io = StringIO.new
    SiteMediaPublish.publish(video_opts.merge(dry_run: true), uploader: uploader, prober: PROBER,
                                                              manifest_path: @manifest, io: io)
    assert_empty uploader.puts_made
    assert_equal before, File.read(@manifest)
    assert_match %r{would upload media/[0-9a-f]{12}\.mp4}, io.string
  end

  def test_bucket_reads_site_bucket_like_deploy_sh_and_falls_back_to_terraform
    assert_equal "from-env", SiteMediaPublish.bucket(env: { "SITE_BUCKET" => "from-env" }, runner: ->(*) { flunk })
    seen = nil
    runner = lambda do |argv, env|
      seen = [ argv, env ]
      [ "from-tf\n", Struct.new(:success?).new(true) ]
    end
    assert_equal "from-tf", SiteMediaPublish.bucket(env: {}, runner: runner)
    assert_equal %w[output -raw site_bucket], seen[0].last(3)
    assert_equal({ "AWS_PROFILE" => "personal" }, seen[1])
    deploy = File.read(File.join(SiteMediaPublish::INFRA, "deploy.sh"))
    assert_includes deploy, 'bucket="$SITE_BUCKET"'
    assert_includes deploy, "output -raw site_bucket"
  end

  def test_deploy_sh_excludes_media_from_both_syncs
    deploy = File.read(File.join(SiteMediaPublish::INFRA, "deploy.sh"))
    assert_equal 2, deploy.scan('--exclude "media/*"').size
  end
end
