# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require_relative "../scripts/b_roll"

class BRollTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body) do
    def is_a?(klass) = klass == Net::HTTPSuccess ? code.start_with?("2") : super
  end

  # Scripted stub: each request is answered by the next queued response.
  class FakeHttp
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def request(req)
      @requests << req
      @responses.shift || FakeResponse.new("500", "{}")
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, ".cache")
    @still = File.join(@dir, "shed.png")
    File.binwrite(@still, "PNGDATA")
    @old_key = ENV.fetch("GEMINI_API_KEY", nil)
    ENV["GEMINI_API_KEY"] = "test-key-not-real"
    @ok_probe = ->(_path) { nil }
  end

  def teardown
    ENV["GEMINI_API_KEY"] = @old_key
    FileUtils.rm_rf(@dir)
  end

  def video_body(data: nil, uri: nil)
    item = { "type" => "video", "mime_type" => "video/mp4" }
    item["data"] = Base64.strict_encode64(data) if data
    item["uri"] = uri if uri
    JSON.generate("id" => "int-1", "status" => "completed",
                  "steps" => [ { "type" => "user_input", "content" => [] }, { "type" => "model_output", "content" => [ item ] } ])
  end

  def ok(body) = FakeResponse.new("200", body)

  def gen(http, **over)
    BRoll.generate(**{ source_image: @still, prompt: "slow push in", seconds: 4, cache_root: @cache, http: http,
                     validator: @ok_probe, sleeper: ->(_s) { } }.merge(over))
  end

  # -- model and cost ------------------------------------------------------

  def test_default_model_is_live_omni
    assert_equal "gemini-omni-1.1-flash", BRoll::MODEL unless ENV["CF_BROLL_MODEL"]
  end

  def test_retired_models_are_refused
    %w[veo-3.1-generate-preview veo-3.0-fast-generate-001 gemini-omni-flash-preview].each do |id|
      assert_raises(BRoll::RetiredModelError) { BRoll.check_model!(id) }
    end
    assert_equal "gemini-omni-1.1-flash", BRoll.check_model!("gemini-omni-1.1-flash")
  end

  def test_estimate_two_clips
    est = BRoll.estimate([ { seconds: 4 }, { seconds: 4 } ])
    assert_equal 2, est[:count]
    assert_equal 8, est[:seconds]
    assert_in_delta 0.80, est[:usd]
    assert_includes est[:line], "$0.80"
    assert_equal 0.0, BRoll.estimate([])[:usd]
  end

  # -- keys ----------------------------------------------------------------

  def key(**over)
    BRoll.asset_key(**{ source_image: @still, prompt: "p", seconds: 4, model: "gemini-omni-1.1-flash" }.merge(over))
  end

  def test_key_changes_with_each_input
    base = key
    assert_equal base, key
    refute_equal base, key(prompt: "q")
    refute_equal base, key(seconds: 5)
    refute_equal base, key(model: "gemini-omni-2")
    refute_equal base, key(resolution: "1080p")
    File.binwrite(@still, "OTHER")
    refute_equal base, key
  end

  # -- request -------------------------------------------------------------

  def test_request_shape
    req = BRoll.build_request(source_image: @still, prompt: "slow push in", seconds: 4, model: "m")
    assert_equal BRoll::INTERACTIONS_URL, req[:url]
    body = req[:body]
    assert_equal "m", body[:model]
    image, text = body[:input]
    assert_equal({ type: "image", data: Base64.strict_encode64("PNGDATA"), mime_type: "image/png" }, image)
    assert_equal "text", text[:type]
    assert_includes text[:text], "slow push in"
    assert_includes text[:text], "4 seconds"
    assert_equal({ video_config: { task: "image_to_video" } }, body[:generation_config])
    assert_equal({ type: "video", aspect_ratio: "16:9", resolution: "720p", delivery: "uri" }, body[:response_format])
  end

  def test_request_mime_follows_extension
    jpg = File.join(@dir, "a.jpg")
    File.binwrite(jpg, "J")
    assert_equal "image/jpeg", BRoll.build_request(source_image: jpg, prompt: "p", seconds: 4, model: "m")[:body][:input][0][:mime_type]
  end

  # -- generate ------------------------------------------------------------

  def test_inline_generate_caches_and_second_call_is_free
    http = FakeHttp.new(ok(video_body(data: "MP4BYTES")))
    path = gen(http)
    assert_equal "MP4BYTES", File.binread(path)
    assert_equal 1, http.requests.size
    assert_equal "test-key-not-real", http.requests[0]["x-goog-api-key"]
    again = gen(FakeHttp.new)
    assert_equal path, again
  end

  def test_uri_delivery_polls_then_downloads
    http = FakeHttp.new(ok(video_body(uri: "https://generativelanguage.googleapis.com/v1beta/files/abc123")),
                        ok('{"state":"PROCESSING"}'), ok('{"state":"ACTIVE"}'), ok("DOWNLOADED"))
    path = gen(http)
    assert_equal "DOWNLOADED", File.binread(path)
    assert_equal [ "POST", "GET", "GET", "GET" ], http.requests.map(&:method)
    assert_includes http.requests[1].path, "/v1beta/files/abc123"
    assert_includes http.requests[3].path, "abc123:download?alt=media"
    refute File.exist?(File.join(@cache, "broll", "#{key(prompt: 'slow push in')}.pending.json"))
  end

  def test_interrupted_job_resumes_without_a_second_post
    first = FakeHttp.new(ok(video_body(uri: "https://generativelanguage.googleapis.com/v1beta/files/abc123")),
                         FakeResponse.new("503", "{}"))
    assert_raises(BRoll::RequestError) { gen(first) }
    pending = Dir.glob(File.join(@cache, "broll", "*.pending.json"))
    assert_equal 1, pending.size
    assert_equal "int-1", JSON.parse(File.read(pending.first))["interaction_id"]
    second = FakeHttp.new(ok('{"state":"ACTIVE"}'), ok("DOWNLOADED"))
    path = gen(second)
    assert_equal "DOWNLOADED", File.binread(path)
    assert_equal %w[GET GET], second.requests.map(&:method)
    assert_empty Dir.glob(File.join(@cache, "broll", "*.pending.json"))
  end

  def test_poll_timeout_and_failed_state_are_named
    uri = "https://generativelanguage.googleapis.com/v1beta/files/abc123"
    stuck = FakeHttp.new(ok(video_body(uri: uri)), *Array.new(4) { ok('{"state":"PROCESSING"}') })
    assert_raises(BRoll::PollTimeoutError) { gen(stuck, poll_interval: 5, poll_timeout: 15) }
    failed = FakeHttp.new(ok('{"state":"FAILED"}'))
    assert_raises(BRoll::GenerationFailedError) { gen(failed, poll_interval: 5, poll_timeout: 15) }
  end

  def test_http_error_names_status_and_leaks_no_key
    err = assert_raises(BRoll::RequestError) { gen(FakeHttp.new(FakeResponse.new("400", '{"error":"bad"}'))) }
    assert_includes err.message, "400"
    refute_includes err.message, "test-key-not-real"
  end

  def test_missing_key_is_named_and_makes_no_call
    ENV.delete("GEMINI_API_KEY")
    http = FakeHttp.new
    assert_raises(WalkthroughEnv::MissingKeyError) { gen(http) }
    assert_empty http.requests
  end

  def test_response_without_video_is_an_error
    body = JSON.generate("steps" => [ { "type" => "model_output", "content" => [ { "type" => "text", "text" => "no" } ] } ])
    assert_raises(BRoll::RequestError) { gen(FakeHttp.new(ok(body))) }
  end

  def test_failed_validation_caches_nothing
    bad = ->(_path) { raise BRoll::ProbeError, "no video stream" }
    assert_raises(BRoll::ProbeError) { gen(FakeHttp.new(ok(video_body(data: "x"))), validator: bad) }
    assert_empty Dir.glob(File.join(@cache, "broll", "*.mp4"))
  end

  def test_retired_model_makes_no_call
    http = FakeHttp.new
    assert_raises(BRoll::RetiredModelError) { gen(http, model: "veo-3.1-generate-preview") }
    assert_empty http.requests
  end

  # -- budget --------------------------------------------------------------

  def test_ceiling_blocks_before_any_call_and_cache_hits_are_free
    budget = BRoll::Budget.new(0.30)
    http = FakeHttp.new
    assert_raises(BRoll::CeilingError) { gen(http, budget: budget) }
    assert_empty http.requests
    assert_in_delta 0.0, budget.spent

    budget = BRoll::Budget.new(1.0)
    gen(FakeHttp.new(ok(video_body(data: "x"))), budget: budget)
    assert_in_delta 0.40, budget.spent
    gen(FakeHttp.new, budget: budget)
    assert_in_delta 0.40, budget.spent, 0.0001
  end

  # -- probe ---------------------------------------------------------------

  def test_probe_validation
    good = { "streams" => [ { "codec_type" => "video", "width" => 1280, "height" => 720 } ], "format" => { "duration" => "4.04" } }
    assert_nil BRoll.check_probe!(good)
    assert_raises(BRoll::ProbeError) { BRoll.check_probe!("streams" => [ { "codec_type" => "audio" } ], "format" => { "duration" => "4" }) }
    assert_raises(BRoll::ProbeError) { BRoll.check_probe!(good.merge("format" => { "duration" => "0.0" })) }
    assert_raises(BRoll::ProbeError) { BRoll.check_probe!({}) }
  end

  def test_probe_argv_uses_ffprobe_entrypoint_in_pinned_image
    runner = lambda do |argv|
      @argv = argv
      [ JSON.generate("streams" => [ { "codec_type" => "video", "width" => 640, "height" => 360 } ], "format" => { "duration" => "4" }),
        Struct.new(:success?).new(true) ]
    end
    probe = File.join(@dir, "clip.mp4")
    File.binwrite(probe, "x")
    BRoll.probe!(probe, docker: runner)
    joined = @argv.join(" ")
    assert_includes joined, "--entrypoint ffprobe"
    assert_includes joined, ChangeDocker::FFMPEG_IMAGE
    assert_includes @argv, "--network"
    assert_includes @argv, "none"
  end

  # -- fallback chain ------------------------------------------------------

  def test_fallback_on_named_failure_never_raises
    res = BRoll.generate_or_fallback(fallback: "kenburns", source_image: @still, prompt: "p", seconds: 4, cache_root: @cache,
                                     http: FakeHttp.new(FakeResponse.new("500", "{}")), validator: @ok_probe)
    assert_equal "kenburns", res[:mode]
    assert_nil res[:path]
    assert_includes res[:reason], "500"
  end

  def test_fallback_when_key_missing_or_ceiling
    ENV.delete("GEMINI_API_KEY")
    res = BRoll.generate_or_fallback(fallback: "static", source_image: @still, prompt: "p", seconds: 4, cache_root: @cache,
                                     http: FakeHttp.new, validator: @ok_probe)
    assert_equal "static", res[:mode]
    ENV["GEMINI_API_KEY"] = "k"
    res = BRoll.generate_or_fallback(fallback: "kenburns", source_image: @still, prompt: "p", seconds: 4, cache_root: @cache,
                                     http: FakeHttp.new, validator: @ok_probe, budget: BRoll::Budget.new(0.01))
    assert_equal "kenburns", res[:mode]
  end

  def test_success_reports_generated_mode
    res = BRoll.generate_or_fallback(fallback: "kenburns", source_image: @still, prompt: "p", seconds: 4, cache_root: @cache,
                                     http: FakeHttp.new(ok(video_body(data: "V"))), validator: @ok_probe)
    assert_equal "generated", res[:mode]
    assert_equal "V", File.binread(res[:path])
  end

  def test_mode_for_reads_the_cache
    args = { source_image: @still, prompt: "p", seconds: 4, model: BRoll::MODEL }
    assert_equal "kenburns", BRoll.mode_for(@cache, "kenburns", **args)
    gen(FakeHttp.new(ok(video_body(data: "V"))), prompt: "p")
    assert_equal "generated", BRoll.mode_for(@cache, "kenburns", **args)
  end

  def test_frames_key_depends_on_mode_geometry_and_count
    base = { mode: "kenburns", source_sha: "s", viewport: { "w" => 640, "h" => 360 }, fps: 30, frames: 90 }
    k = BRoll.frames_key(**base)
    assert_equal k, BRoll.frames_key(**base)
    refute_equal k, BRoll.frames_key(**base, mode: "static")
    refute_equal k, BRoll.frames_key(**base, frames: 91)
    refute_equal k, BRoll.frames_key(**base, viewport: { "w" => 1280, "h" => 720 })
    refute_equal k, BRoll.frames_key(**base, mode: "generated", clip_key: "c1")
  end

  # -- ffmpeg argv ---------------------------------------------------------

  def frame_args(mode)
    BRoll.frame_args(mode: mode, input: "/work/in", out_dir: "/work/out", width: 640, height: 360, fps: 30, frames: 90)
  end

  def test_generated_clip_is_normalized_silent_and_held
    argv = frame_args("generated")
    joined = argv.join(" ")
    assert_includes argv, "-an"
    assert_includes joined, "scale=640:360:force_original_aspect_ratio=decrease"
    assert_includes joined, "pad=640:360"
    assert_includes joined, "fps=30"
    assert_includes joined, "tpad=stop_mode=clone"
    assert_includes joined, "-frames:v 90"
    assert_equal "/work/out/%06d.png", argv.last
  end

  def test_kenburns_and_static_argv
    ken = frame_args("kenburns").join(" ")
    assert_includes ken, "zoompan"
    assert_includes ken, "d=90"
    assert_includes ken, "-frames:v 90"
    stat = frame_args("static").join(" ")
    assert_includes stat, "-loop 1"
    refute_includes stat, "zoompan"
    assert_raises(ArgumentError) { frame_args("bogus") }
  end

  def test_make_frames_runs_docker_and_writes_cursor_stub
    runs = []
    docker = lambda do |argv|
      runs << argv
      out = File.join(@dir, "out")
      FileUtils.mkdir_p(out)
      File.binwrite(File.join(out, "000001.png"), "png")
      [ "", Struct.new(:success?).new(true) ]
    end
    out = File.join(@dir, "out")
    BRoll.make_frames(mode: "static", input: @still, out_dir: out, work: @dir, width: 640, height: 360, fps: 30, frames: 30, docker: docker)
    assert_equal 1, runs.size
    assert_includes runs[0], ChangeDocker::FFMPEG_IMAGE
    assert_equal [], JSON.parse(File.read(File.join(out, "cursor.json")))
  end

  def test_make_frames_failure_is_named
    docker = ->(_argv) { [ "boom", Struct.new(:success?).new(false) ] }
    assert_raises(BRoll::FfmpegError) do
      BRoll.make_frames(mode: "static", input: @still, out_dir: File.join(@dir, "o"), work: @dir, width: 64, height: 36, fps: 30, frames: 3, docker: docker)
    end
  end
end
