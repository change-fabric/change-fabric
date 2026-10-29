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
    @lint_findings = {}
    @critic = { "score" => 9, "summary" => "s", "issues" => [], "thirty_second_test" => { "verdict" => "pass", "reason" => "r" }, "purpose_test" => [] }
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
      "review" => { "kind" => "explainer", "audience" => "Engineers", "purpose" => [ "State what the demo shows" ] },
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
        PrototypeUxLint.write(kw[:out_dir], PrototypeUxLint.scene_report(kw[:label], @lint_findings.fetch(kw[:label], [])))
      end,
      lint: lambda do |**kw|
        @calls[:lint] << kw[:label]
        PrototypeUxLint.scene_report(kw[:label], @lint_findings.fetch(kw[:label], [])).tap { |r| PrototypeUxLint.write(kw[:out_dir], r) }
      end,
      roast: lambda do |**kw|
        @calls[:roast] << kw[:shots].map { |s| File.basename(s) }
        @critic
      end,
      docker: lambda do |argv|
        @calls[:docker] << argv
        if argv.include?("-buildconf")
          [ "--enable-libass --enable-libx264", Status.new(true) ]
        elsif argv.include?("null")
          [ LOUDNORM_OUT, Status.new(true) ]
        elsif argv.last.end_with?("%03d.jpg")
          dir = File.dirname(argv.last.sub(%r{\A/work/}, "#{@root}/"))
          argv.join(" ").scan("eq(n").size.times { |i| File.binwrite(File.join(dir, format("%03d.jpg", i + 1)), "jpg#{i}") }
          [ "", Status.new(true) ]
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
    WalkthroughRender::Run.new(@root, **{ providers: providers, out: StringIO.new, gates: { roast: false } }.merge(opts)).call
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

  def test_final_inlines_high_quality_images_with_new_keys_and_mp4
    img = { "prompt" => "a hero", "size" => "1024x1024" }
    b = board
    b["scenes"][0]["images"] = [ img ]
    keys = %w[medium high].to_h { |q| [ q, PrototypeImagegen.asset_key(prompt: "a hero", size: "1024x1024", quality: q) ] }
    File.write(File.join(@root, "screens", "list.html"), "<html><body><img src=\"../.cache/images/#{keys['medium']}.png\"></body></html>")
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    htmls = []
    image = lambda do |**kw|
      WalkthroughCache.fetch(kw[:cache_root], :images, PrototypeImagegen.asset_key(**kw.slice(:prompt, :size, :quality)), "png") do |tmp|
        File.binwrite(tmp, "png-#{kw[:quality]}")
      end
    end
    capture = providers[:capture]
    spy = lambda do |**kw|
      htmls << [ kw[:label], kw[:html] ]
      capture.call(**kw)
    end
    ps = providers.merge(image: image, capture: spy)
    draft = run_render(providers: ps)
    final = run_render(providers: ps, final: true)

    refute_equal draft[:manifest]["manifest_hash"], final[:manifest]["manifest_hash"]
    refute_equal draft[:mp4], final[:mp4]
    assert_equal [ keys["medium"] ], draft[:manifest]["scenes"][0]["asset_keys"]
    assert_equal [ keys["high"] ], final[:manifest]["scenes"][0]["asset_keys"]
    refute_equal draft[:manifest]["scenes"][0]["frames_key"], final[:manifest]["scenes"][0]["frames_key"]
    list_html = htmls.select { |label, _| label == "list" }.map(&:last)
    assert_includes list_html.first, Base64.strict_encode64("png-medium")
    assert_includes list_html.last, Base64.strict_encode64("png-high")
    refute_includes list_html.last, Base64.strict_encode64("png-medium")
    saved = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    assert_equal [ keys["medium"] ], saved["scenes"][0]["deps"]["asset_keys"], "final leaves authored deps at draft quality"
  end

  def test_final_warns_when_a_screen_never_references_the_keyed_image
    b = board
    b["scenes"][0]["images"] = [ { "prompt" => "a hero", "size" => "1024x1024" } ]
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    File.write(File.join(@root, "screens", "list.html"), "<html><body><p>stable path only</p></body></html>")
    image = lambda do |**kw|
      WalkthroughCache.fetch(kw[:cache_root], :images, PrototypeImagegen.asset_key(**kw.slice(:prompt, :size, :quality)), "png") { |tmp| File.binwrite(tmp, "png") }
    end
    out = StringIO.new
    result = run_render(providers: providers.merge(image: image), final: true, out: out)
    assert result[:mp4], "rendering continues after the warning"
    assert_match(%r{warning: list: final image not inlined, screens/list\.html does not reference images/\h{64}\.png}, out.string)
  end

  def test_empty_mp4_from_a_failed_pass_is_not_a_cached_render
    first = run_render
    File.write(first[:mp4], "")
    @calls[:docker].clear
    second = run_render
    assert_equal 3, @calls[:docker].size
    assert_equal "mp4", File.read(second[:mp4])
  end

  def test_burned_captions_never_reuse_a_soft_render
    soft = run_render
    @calls[:docker].clear
    burned = run_render(burn_captions: true)
    assert_equal 3, @calls[:docker].size, "burn re-runs ffmpeg instead of reusing the soft mp4"
    refute_equal soft[:mp4], burned[:mp4]
    assert_equal File.join(File.dirname(soft[:mp4]) + "-burn", "walkthrough.mp4"), burned[:mp4]
    @calls[:docker].clear
    run_render(burn_captions: true)
    assert_empty @calls[:docker], "a cached burned render is reused"
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

  def test_scene_flag_recaptures_invalidated_dependents
    run_render
    File.write(File.join(@root, "data", "list.json"), JSON.generate("items" => [ { "id" => 2 } ]))
    data = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    data["scenes"][0]["store"]["seed"] = "data/list.json"
    File.write(File.join(@root, "storyboard.json"), JSON.generate(data))
    @calls.clear
    run_render(scene: "list")
    assert_equal %w[list detail], @calls[:capture], "from_scene dependent re-keyed by the new end state is recaptured"
  end

  def test_scene_flag_on_dependent_leaves_upstream_alone
    run_render
    data = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    data["scenes"][1]["store"]["patch"] = [ { "op" => "set", "path" => "/flag", "value" => true } ]
    File.write(File.join(@root, "storyboard.json"), JSON.generate(data))
    @calls.clear
    run_render(scene: "detail")
    assert_equal %w[detail], @calls[:capture]
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

  # -- gates ----------------------------------------------------------------

  def finding(rule = "empty-control")
    { "frame" => 0, "rule" => rule, "target" => "#toast", "detail" => "overlay renders no visible text" }
  end

  def test_ux_lint_report_beside_render_and_final_refusal
    @lint_findings = { "detail" => [ finding ] }
    draft = run_render
    report = JSON.parse(File.read(File.join(File.dirname(draft[:mp4]), "ux-lint.json")))
    assert_equal [ "detail" ], report["scenes"].reject { |r| r["findings"].empty? }.map { |r| r["scene"] }
    err = assert_raises(PrototypeUxLint::FindingsError) { run_render(final: true) }
    assert_includes err.message, "detail: empty-control #toast"
    assert_includes err.message, "--allow-ux-findings"
    assert run_render(final: true, gates: { roast: false, allow_ux: true })[:mp4]
  end

  def test_clean_lint_lets_final_through
    run_render
    assert run_render(final: true)[:mp4]
  end

  def test_cached_frames_without_a_lint_report_get_a_lint_only_pass
    run_render
    Dir.glob(File.join(@root, ".cache", "frames", "*", "ux-lint.json")).each { |f| File.delete(f) }
    @calls.clear
    run_render
    assert_empty @calls[:capture]
    assert_equal %w[list detail hero], @calls[:lint]
  end

  def test_draft_roast_writes_round_with_keyframes_and_estimate
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers, out: out).call
    assert File.file?(File.join(@root, "roast", "round-1.json"))
    shots = @calls[:roast].first
    assert_equal 9, shots.size
    assert_equal "001-list-start.jpg", shots.first
    log = out.string
    assert_operator log.index("roast estimate:"), :<, log.index("roast: roast/round-1.json")
  end

  def test_draft_roast_skips_over_its_ceiling_and_on_no_roast
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers, out: out, gates: { roast_max_usd: 0.0 }).call
    assert_empty @calls[:roast]
    assert_includes out.string, "spend cap reached"
    assert_includes out.string, "no earlier round on record"
    refute File.exist?(File.join(@root, "roast", "round-1.json"))
  end

  def test_draft_roast_sends_the_narration_transcript_and_records_spend
    seen = nil
    prov = providers.merge(roast: lambda do |**kw|
      seen = kw[:transcript]
      @critic
    end)
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: prov, out: out).call
    assert_includes seen, "Narration by scene:"
    assert_includes seen, "wpm]"
    assert_includes seen, "Caption cues:"
    assert_operator WalkthroughRoast.spent(File.join(@root, "roast")), :>, 0
    assert_includes out.string, "roast loop: stop: score 9, 0 open P0/P1, target 8.5 reached"
  end

  def test_unconverged_draft_says_continue_and_final_refuses_until_loop_finishes
    @critic = @critic.merge("score" => 7)
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers, out: out).call
    assert_includes out.string, "roast loop: continue:"
    err = assert_raises(WalkthroughRoast::OpenFindingsError) { run_render(final: true) }
    assert_includes err.message, "roast loop is unfinished"
    assert run_render(final: true, gates: { roast: false, allow_roast: true })[:mp4]
  end

  def test_final_requires_a_roast_on_record_unless_no_roast_or_allowed
    err = assert_raises(WalkthroughRoast::OpenFindingsError) { run_render(final: true, gates: { roast: true }) }
    assert_includes err.message, "no draft roast on record"
    assert run_render(final: true, gates: { roast: true, allow_roast: true })[:mp4]
  end

  def test_finished_loop_takes_no_further_paid_round
    WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new).call
    @calls[:roast].clear
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers, out: out).call
    assert_empty @calls[:roast]
    assert_includes out.string, "roast: loop finished"
  end

  def test_final_refuses_on_open_roast_blocker_until_rebutted_or_allowed
    @critic = @critic.merge("issues" => [ { "priority" => "P1", "screen" => "002-list-middle.jpg", "problem" => "Toast covers the CTA", "fix" => "Move it" },
                                          { "priority" => "P2", "screen" => "001-list-start.jpg", "problem" => "Tight", "fix" => "Pad" } ])
    WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new).call
    err = assert_raises(WalkthroughRoast::OpenFindingsError) { run_render(final: true) }
    assert_includes err.message, "P1 (002-list-middle.jpg): Toast covers the CTA"
    assert run_render(final: true, gates: { roast: false, allow_roast: true })[:mp4]
    File.write(File.join(@root, "roast", "round-1.response.json"),
               JSON.generate("responses" => [ { "screen" => "002-list-middle.jpg", "problem" => "Toast covers", "verdict" => "rebut", "reason" => "r" } ]))
    assert run_render(final: true)[:mp4]
  end
end
