# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/walkthrough_render"

class WalkthroughRenderTest < Minitest::Test
  LOUDNORM_OUT = "{\n \"input_i\" : \"-20.0\", \"input_tp\" : \"-2.0\", \"input_lra\" : \"5.0\",\n" \
                 " \"input_thresh\" : \"-30.0\", \"target_offset\" : \"0.1\"\n}\n"
  Status = Struct.new(:ok) do
    def success? = ok
  end

  def setup
    @root = Dir.mktmpdir
    @old_env = ENV["CF_SECRETS_ENV"]
    ENV["CF_SECRETS_ENV"] = File.join(@root, "no-such.env")
    FileUtils.mkdir_p(File.join(@root, "screens"))
    FileUtils.mkdir_p(File.join(@root, "data"))
    %w[list detail hero].each { |n| File.write(File.join(@root, "screens", "#{n}.html"), "<html><body>#{n}</body></html>") }
    File.write(File.join(@root, "data", "seed.json"), JSON.generate("items" => [ { "id" => 1 } ]))
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(board))
    @calls = Hash.new { |h, k| h[k] = [] }
  end

  def teardown
    ENV["CF_SECRETS_ENV"] = @old_env
    FileUtils.rm_rf(@root)
  end

  def scene(id, order, html, extra = {})
    { "id" => id, "order" => order, "title" => id, "screen" => { "html" => "screens/#{html}.html" },
      "narration" => { "text" => "Scene #{id} speaks.", "measured_ms" => 0 },
      "assumptions" => [ { "id" => "A-0#{order}", "text" => "x" } ],
      "interactions" => [ { "t_ms" => 0, "op" => "move", "target" => "#a", "duration_ms" => 100 } ],
      "timing" => { "min_ms" => 1000, "pad_ms" => 200, "transition" => { "type" => "cut", "ms" => 0 } } }.merge(extra)
  end

  def board
    { "schema_version" => 1, "slug" => "demo", "title" => "Demo", "fps" => 30,
      "viewport" => { "w" => 640, "h" => 360, "dpr" => 1 },
      "voice" => { "voice_id" => "v1", "model" => "eleven_multilingual_v2", "output_format" => "mp3_44100_128" },
      "music" => { "model" => "music_v1", "prompt" => "calm", "gain_db" => -18 },
      "scenes" => [
        scene("list", 1, "list", "store" => { "seed" => "data/seed.json" }),
        scene("detail", 2, "detail", "store" => { "seed" => "data/seed.json", "from_scene" => "list" },
              "timing" => { "min_ms" => 1000, "pad_ms" => 200, "transition" => { "type" => "fade", "ms" => 300 } }),
        scene("hero", 3, "hero", "hero_still" => true)
      ] }
  end

  def alignment(text)
    chars = text.chars
    { "characters" => chars, "character_start_times_seconds" => chars.each_index.map { |i| i * 0.05 },
      "character_end_times_seconds" => chars.each_index.map { |i| (i + 1) * 0.05 } }
  end

  def providers
    {
      tts: lambda do |**kw|
        @calls[:tts] << kw[:text]
        key = ElevenLabs.audio_key(**kw.slice(:text, :voice_id, :model, :output_format, :settings))
        path = WalkthroughCache.fetch(kw[:cache_root], :audio, key, "mp3") do |tmp|
          File.binwrite(tmp, "mp3")
          File.write(WalkthroughCache.path(kw[:cache_root], :audio, key, "alignment.json"), JSON.generate(alignment(kw[:text])))
        end
        { key: key, audio: path, measured_ms: kw[:text].length * 50 }
      end,
      music: lambda do |**kw|
        @calls[:music] << kw[:length_ms]
        key = ElevenLabs.music_key(kw.slice(:prompt, :composition_plan, :model), kw[:length_ms])
        WalkthroughCache.fetch(kw[:cache_root], :music, key, "mp3") { |tmp| File.binwrite(tmp, "music") }
      end,
      image: ->(**kw) { @calls[:image] << kw[:prompt] },
      browser: lambda do |&blk|
        @calls[:browser] << true
        blk.call(:session)
      end,
      capture: lambda do |**kw|
        @calls[:capture] << kw[:label]
        FileUtils.mkdir_p(kw[:out_dir])
        File.binwrite(File.join(kw[:out_dir], "000001.png"), "png")
        File.write(File.join(kw[:out_dir], "cursor.json"), JSON.generate([ { "frame" => 1, "x" => 3, "y" => 4, "down" => false } ]))
        File.write(File.join(kw[:out_dir], "end-state.json"), JSON.generate(kw[:state].merge("seen" => kw[:label])))
      end,
      docker: lambda do |argv|
        @calls[:docker] << argv
        if argv.include?("-buildconf")
          [ "--enable-libass --enable-libx264", Status.new(true) ]
        elsif argv.include?("null")
          [ LOUDNORM_OUT, Status.new(true) ]
        elsif argv.last.end_with?("%06d.png")
          File.binwrite(File.join(File.dirname(argv.last.sub(%r{\A/work/}, "#{@root}/")), "000001.png"), "png")
          [ "", Status.new(true) ]
        else
          out = argv.last.sub(%r{\A/work/}, "#{@root}/")
          File.binwrite(out, "mp4")
          [ "", Status.new(true) ]
        end
      end
    }
  end

  def run_render(**opts)
    WalkthroughRender::Run.new(@root, **{ providers: providers, out: StringIO.new }.merge(opts)).call
  end

  def test_full_render_order_and_outputs
    result = run_render
    assert_equal %w[list detail hero], @calls[:capture], "from_scene dependency captured before its dependent"
    assert_equal 3, @calls[:tts].size
    assert_equal 1, @calls[:music].size
    assert_equal 1, @calls[:browser].size
    assert_equal 3, @calls[:docker].size
    pass2 = @calls[:docker].last
    assert_equal %w[docker run --rm --network none], pass2.first(5)
    assert_includes pass2, ChangeDocker::FFMPEG_IMAGE
    assert_includes pass2.join(" "), "source=#{@root}\",target=/work"
    assert_includes pass2.join(" "), "linear=true"
    dir = File.join(@root, ".cache", "render", result[:manifest]["manifest_hash"])
    assert_equal File.join(dir, "walkthrough.mp4"), result[:mp4]
    assert_match(/\A1\n00:00:00,000 --> /, File.read(File.join(dir, "captions.srt")))
    assert File.file?(File.join(dir, "cursor.png"))
    detail_state = JSON.parse(File.read(File.join(@root, ".cache", "frames",
                                                  result[:manifest]["scenes"][1]["frames_key"], "end-state.json")))
    assert_equal "detail", detail_state["seen"]
    saved = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    assert_equal "Scene list speaks.".length * 50, saved["scenes"][0]["narration"]["measured_ms"]
  end

  def test_empty_mp4_from_a_failed_pass_is_not_a_cached_render
    first = run_render
    File.write(first[:mp4], "")
    @calls[:docker].clear
    second = run_render
    assert_equal 3, @calls[:docker].size
    assert_equal "mp4", File.read(second[:mp4])
  end

  def test_image_model_is_part_of_the_cache_key
    b = board
    b["scenes"][0]["images"] = [ { "prompt" => "a hero", "model" => "custom-image-model" } ]
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    image = lambda do |**kw|
      @calls[:image] << kw[:model]
      key = PrototypeImagegen.asset_key(**kw.slice(:prompt, :size, :quality, :refs, :model))
      WalkthroughCache.fetch(kw[:cache_root], :images, key, "png") { |tmp| File.binwrite(tmp, "png") }
    end
    run_render(providers: providers.merge(image: image))
    assert_equal [ "custom-image-model" ], @calls[:image]
    @calls.clear
    run_render(providers: providers.merge(image: image))
    assert_empty @calls[:image], "a cached model-keyed image is not regenerated"
  end

  def test_everything_cached_makes_no_provider_or_docker_call
    first = run_render
    @calls.clear
    second = run_render
    assert_empty @calls, "a cached run touches no provider, browser, or docker"
    assert_equal first[:manifest]["manifest_hash"], second[:manifest]["manifest_hash"]
  end

  def test_same_manifest_yields_identical_argv
    run_render
    pass2 = @calls[:docker].last
    FileUtils.rm_rf(File.join(@root, ".cache", "render"))
    @calls.clear
    run_render
    assert_equal pass2, @calls[:docker].last
    assert_empty @calls[:capture]
  end

  def test_scene_flag_regenerates_only_that_scene
    run_render
    data = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    data["scenes"][2]["narration"]["text"] = "The hero now says more words here."
    File.write(File.join(@root, "storyboard.json"), JSON.generate(data))
    @calls.clear
    run_render(scene: "hero")
    assert_equal [ "The hero now says more words here." ], @calls[:tts]
    assert_equal %w[hero], @calls[:capture]
  end

  def test_missing_cache_at_assembly_is_hard_error
    run_render
    data = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    data["scenes"][2]["narration"]["text"] = "Changed hero line."
    File.write(File.join(@root, "storyboard.json"), JSON.generate(data))
    err = assert_raises(WalkthroughRender::MissingCacheError) { run_render(scene: "list") }
    assert_match(/hero/, err.message)
  end

  def test_estimate_only_spends_nothing
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers, out: out).call(estimate_only: true)
    assert_empty @calls
    assert_match(/ElevenLabs estimate: narration \$0\.00/, out.string)
    assert_match(/OpenAI estimate: 0 image/, out.string)
  end

  # -- ai-broll scenes -----------------------------------------------------

  def write_broll_board
    FileUtils.mkdir_p(File.join(@root, "screens", "assets"))
    File.binwrite(File.join(@root, "screens", "assets", "shed.png"), "PNG")
    b = board
    b["scenes"] << { "id" => "shed", "order" => 4, "title" => "Shed", "kind" => "ai-broll",
                     "broll" => { "source_image" => "screens/assets/shed.png", "prompt" => "slow push in", "seconds" => 4,
                                  "model" => "gemini-omni-1.1-flash", "fallback" => "kenburns" },
                     "narration" => { "text" => "Shed scene speaks.", "measured_ms" => 0 },
                     "assumptions" => [ { "id" => "A-09", "text" => "generated" } ],
                     "timing" => { "min_ms" => 1000, "pad_ms" => 200, "transition" => { "type" => "fade", "ms" => 300 } } }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
  end

  def broll_provider(mode)
    lambda do |**kw|
      @calls[:broll] << kw.slice(:prompt, :seconds, :model, :fallback)
      @budgets = (@budgets || []) << kw[:budget]
      if mode == "generated"
        key = BRoll.asset_key(**kw.slice(:source_image, :prompt, :seconds, :model))
        { mode: "generated", path: WalkthroughCache.fetch(kw[:cache_root], :broll, key, "mp4") { |tmp| File.binwrite(tmp, "mp4") } }
      else
        { mode: kw[:fallback], path: nil, reason: "boom" }
      end
    end
  end

  def test_broll_clip_is_normalized_and_enters_the_timeline_without_capture
    write_broll_board
    result = run_render(providers: providers.merge(broll: broll_provider("generated")))
    assert_equal %w[list detail hero], @calls[:capture], "an ai-broll scene is never captured"
    assert_equal [ { prompt: "slow push in", seconds: 4, model: "gemini-omni-1.1-flash", fallback: "kenburns" } ], @calls[:broll]
    shed = result[:manifest]["scenes"].last
    assert File.file?(File.join(@root, ".cache", "frames", shed["frames_key"], "cursor.json"))
    norm = @calls[:docker].find { |argv| argv.join(" ").include?("tpad=stop_mode=clone") }
    assert norm, "the clip is normalized in the pinned FFmpeg container"
    assert_includes norm, ChangeDocker::FFMPEG_IMAGE
    assert_includes norm, "-an"
    pass2 = @calls[:docker].last.join(" ")
    assert_includes pass2, "/work/.cache/frames/#{shed['frames_key']}/%06d.png"
    assert_includes pass2, "xfade", "its transition is honored like any other scene"
    assert_equal 4, result[:manifest]["scenes"].size
    assert_match(/\A\h{64}\z/, shed["broll_key"])
  end

  def test_failed_generation_falls_back_to_kenburns_and_still_renders
    write_broll_board
    result = run_render(providers: providers.merge(broll: broll_provider("fallback")))
    assert @calls[:docker].any? { |argv| argv.join(" ").include?("zoompan") && argv.join(" ").include?("screens/assets/shed.png") }
    assert File.file?(result[:mp4])
    shed = result[:manifest]["scenes"].last
    assert File.file?(File.join(@root, ".cache", "frames", shed["frames_key"], "000001.png"))
  end

  def test_cached_broll_rerun_calls_nothing
    write_broll_board
    first = run_render(providers: providers.merge(broll: broll_provider("generated")))
    @calls.clear
    second = run_render(providers: providers.merge(broll: broll_provider("generated")))
    assert_empty @calls
    assert_equal first[:manifest]["manifest_hash"], second[:manifest]["manifest_hash"]
  end

  def test_estimate_includes_uncached_broll_and_spends_nothing
    write_broll_board
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers.merge(broll: broll_provider("generated")), out: out).call(estimate_only: true)
    assert_empty @calls
    assert_includes out.string, "Google estimate: 1 b-roll clip(s), 4s at 720p, about $0.40"
  end

  def test_ceiling_is_shared_and_scene_flag_skips_other_scenes
    write_broll_board
    run_render(providers: providers.merge(broll: broll_provider("generated")), max_usd: 0.25)
    assert_in_delta 0.25, @budgets.first.ceiling
    @calls.clear
    run_render(scene: "list", providers: providers.merge(broll: broll_provider("generated")))
    assert_empty @calls[:broll]
  end

  def test_preflight_rejects_image_without_libass
    bad = providers.merge(docker: ->(_argv) { [ "--enable-libx264", Status.new(true) ] })
    err = assert_raises(WalkthroughRender::FfmpegError) do
      WalkthroughRender::Run.new(@root, providers: bad, out: StringIO.new).call
    end
    assert_match(/lacks libass/, err.message)
  end
end
