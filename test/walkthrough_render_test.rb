# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/walkthrough_render"
require_relative "support/png_fixture"
require_relative "enroll_helpers"

class WalkthroughRenderTest < Minitest::Test
  include EnrollHelpers

  LOUDNORM_OUT = "{\n \"input_i\" : \"-20.0\", \"input_tp\" : \"-2.0\", \"input_lra\" : \"5.0\",\n" \
                 " \"input_thresh\" : \"-30.0\", \"target_offset\" : \"0.1\"\n}\n"
  EBUR128_OUT = File.read(File.join(__dir__, "fixtures", "walkthrough", "loudness", "compliant.txt"))
  Status = Struct.new(:ok) do
    def success? = ok
  end

  def setup
    @root = Dir.mktmpdir
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
      # The disk preflight never depends on the machine running the tests.
      free_bytes: ->(_root) { 1 << 50 },
      docker: lambda do |argv|
        # Share copies are tracked apart so render call counts stay exact.
        if argv.last.end_with?("-share.mp4")
          (@share_calls ||= []) << argv
          File.binwrite(argv.last.sub(%r{\A/work/}, "#{@root}/"), "share")
          return [ "", Status.new(true) ]
        end
        @calls[argv.include?("ebur128=peak=true") ? :loudness : :docker] << argv
        if argv.include?("-buildconf")
          [ "--enable-libass --enable-libx264", Status.new(true) ]
        elsif argv.include?("ebur128=peak=true")
          [ @ebur128_queue&.shift || @ebur128_out || EBUR128_OUT, Status.new(true) ]
        elsif argv.include?("null")
          [ LOUDNORM_OUT, Status.new(true) ]
        elsif argv.last.end_with?("%03d.jpg")
          dir = File.dirname(argv.last.sub(%r{\A/work/}, "#{@root}/"))
          argv.join(" ").scan("eq(n").size.times { |i| File.binwrite(File.join(dir, format("%03d.jpg", i + 1)), "jpg#{i}") }
          [ "", Status.new(true) ]
        elsif argv.last.end_with?("%06d.png")
          File.binwrite(File.join(File.dirname(argv.last.sub(%r{\A/work/}, "#{@root}/")), "000001.png"), "png")
          [ "", Status.new(true) ]
        elsif argv.last.include?("ffprobe")
          [ @probe_out.to_s, Status.new(true) ]
        else
          out = argv.last.sub(%r{\A/work/}, "#{@root}/")
          File.binwrite(out, "mp4")
          [ "", Status.new(true) ]
        end
      end
    }
  end

  def scene_input(text, offset_ms, step: 0.05)
    chars = text.chars
    align = { "characters" => chars, "character_start_times_seconds" => chars.each_index.map { |i| i * step },
              "character_end_times_seconds" => chars.each_index.map { |i| (i + 1) * step } }
    { alignment: align, offset_ms: offset_ms }
  end

  def parse_srt(srt)
    srt.split("\n\n").map do |blk|
      _, times, *lines = blk.split("\n")
      a, b = times.split(" --> ").map { |t| h, m, s, ms = t.split(/[:,]/).map(&:to_i); (((h * 60) + m) * 60 + s) * 1000 + ms }
      { start_ms: a, end_ms: b, text: lines.join(" ") }
    end
  end

  def test_captions_never_straddle_a_scene_and_never_overlap
    run = WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new, gates: { roast: false })
    inputs = [ scene_input("First scene ends here", 0), scene_input("Second scene starts", 500) ]
    cues = parse_srt(run.send(:captions, inputs))
    texts = cues.map { |c| c[:text] }
    assert_equal [ "First scene ends here", "Second scene starts" ], texts, "no cue mixes words from two scenes"
    cues.each_cons(2) { |a, b| assert_operator b[:start_ms], :>=, a[:end_ms] }
  end

  def run_render(**opts)
    WalkthroughRender::Run.new(@root, **{ providers: providers, out: StringIO.new, gates: { roast: false } }.merge(opts)).call
  end

  def anchor_board(word)
    b = board
    b["scenes"][0]["interactions"] = [ { "at" => { "word" => word }, "op" => "move", "target" => "#a", "duration_ms" => 100 } ]
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
  end

  # "Scene list speaks." at 50 ms a character: "speaks" starts at 550 ms,
  # snapped to frame 17 at 30 fps.
  def test_word_anchor_resolves_after_narration_and_stays_authored
    anchor_board("speaks")
    run_render
    saved = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    op = saved["scenes"][0]["interactions"].first
    assert_equal({ "word" => "speaks" }, op["at"])
    refute op.key?("t_ms"), "the authored board keeps at, not the resolved t_ms"
    assert_equal [], WalkthroughStoryboard.stale(saved, @root)
    assert_equal 567, WalkthroughStoryboard.resolved_copy(saved, File.join(@root, ".cache"))["scenes"][0]["interactions"][0]["t_ms"]
  end

  def test_missing_anchor_word_fails_before_any_paid_image_or_music_call
    anchor_board("shouts")
    err = assert_raises(WalkthroughStoryboard::ValidationError) { run_render }
    assert_includes err.message, '"shouts" is not in the narration'
    assert_equal 3, @calls[:tts].size
    assert_empty @calls[:music]
    assert_empty @calls[:image]
    assert_equal %w[list detail hero], @calls[:capture], "only the free silent cut captured, before the anchor failed"
  end

  # A zoom with no focus still frames the scene, centred (issue #311).
  def test_camera_zoom_without_focus_is_applied
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["scenes"][0]["camera"] = { "zoom" => 1.5 }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    run_render
    log = @calls[:docker].map { |a| a.join(" ") }.join("\n")
    assert_includes log, "scale=960:540:flags=lanczos,setsar=1[s0]", "the frame is scaled onto the 1.5x stage"
    assert_includes log, ",crop=640:360:160:90,"
  end

  # Only a focus-less camera changes the render key: a mp4 cached before
  # centred framing must not be reused, a focused or camera-less one may.
  def test_camera_material_tags_only_focusless_zoom
    run = WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new, gates: { roast: false })
    { nil => [], { "zoom" => 1.5, "focus" => { "x" => 1, "y" => 2 } } => nil, { "zoom" => 1.5 } => "centred-zoom" }.each do |cam, tag|
      b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
      b["scenes"].each { |s| s.delete("camera") }
      b["scenes"][0]["camera"] = cam if cam
      run.instance_variable_set(:@board, b)
      material = run.send(:camera_material)
      next assert_equal([], material) if cam.nil?
      tag ? assert_equal(tag, material.dig(0, 0, 2)) : assert_nil(material.dig(0, 0, 2))
    end
  end

  # A narration offset absorbed by timing.min_ms moves no frame or audio
  # key, so it must move the roast content key itself.
  def test_audio_timing_moves_the_content_key_only_when_set
    run = WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new, gates: { roast: false })
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    run.instance_variable_set(:@board, b)
    assert_equal [], run.send(:audio_timing_material)
    before = run.send(:content_key, %w[k])
    b["scenes"][0]["narration_start"] = 4.0
    refute_equal before, run.send(:content_key, %w[k])
  end

  # narration_start shifts the voice, the captions, and the duck spans; the
  # sfx rides from its scene start and ducks duck_lead before each line.
  def test_narration_start_and_sfx_shift_the_mix
    FileUtils.mkdir_p(File.join(@root, "sfx"))
    File.binwrite(File.join(@root, "sfx", "riser.wav"), "RIFF")
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["scenes"][0]["narration_start"] = 4.0
    b["scenes"][0]["sfx"] = { "file" => "sfx/riser.wav", "gain_db" => -17, "duck_db" => -10 }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    result = run_render
    first = result[:manifest]["scenes"][0]
    line_ms = "Scene list speaks.".length * 50
    assert_equal 4000 + line_ms + 200, first["duration_ms"], "the scene grows to fit the offset plus the line"
    assert first.key?("sfx_sha256")
    log = @calls[:docker].last.join(" ")
    assert_includes log, "adelay=delays=4000:all=1", "narration starts 4 s into the scene"
    assert_includes log, "/work/sfx/riser.wav"
    assert_includes log, "atrim=duration=#{format('%.3f', first['duration_ms'] / 1000.0)},adelay=delays=0:all=1,volume='pow(10,(-10.00*"
    assert_includes log, "-10.00*clip(min((t-3.600)/0.300,", "the sfx duck lands 100 ms before the voice"
    assert_includes log, "volume=-17.0dB"
    dir = File.dirname(result[:mp4])
    assert_match(/\A1\n00:00:04,000 --> /, File.read(File.join(dir, "captions.srt")), "captions shift by the offset")
  end

  def test_sfx_starting_past_its_scene_is_dropped
    FileUtils.mkdir_p(File.join(@root, "sfx"))
    File.binwrite(File.join(@root, "sfx", "riser.wav"), "RIFF")
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["scenes"][0]["sfx"] = { "file" => "sfx/riser.wav", "start" => 59.0 }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    run_render
    refute_includes @calls[:docker].last.join(" "), "/work/sfx/riser.wav"
  end

  def test_full_render_order_and_outputs
    log = StringIO.new
    result = run_render(out: log)
    assert_equal %w[list detail hero] * 2, @calls[:capture], "silent cut, then the narrated draft; from_scene dependency first"
    assert_equal 3, @calls[:tts].size
    assert_equal 1, @calls[:music].size
    assert_equal 2, @calls[:browser].size, "one session for the silent cut, one for the draft"
    assert_equal 7, @calls[:docker].size, "silent cut: buildconf, pass 1, pass 2; draft: buildconf, audio probe, pass 1, pass 2"
    pass2 = @calls[:docker].last
    assert_equal %w[docker run --rm --name], pass2.first(4)
    assert_includes pass2.join(" "), "--network none"
    assert_includes pass2, ChangeDocker::FFMPEG_IMAGE
    assert_includes pass2.join(" "), "source=#{@root}\",target=/work"
    assert_includes pass2.join(" "), "volume=+4.00dB,#{WalkthroughFfmpeg::LIMITER}"
    refute_includes pass2.join(" "), "loudnorm"
    assert_includes log.string, "loudness: measured I -20.0 LUFS, LRA 5.0 LU"
    key = WalkthroughCache.key([ result[:manifest]["manifest_hash"], {}, { level: WalkthroughFfmpeg::LEVEL_VERSION }, { music_outro: 2500 } ])
    dir = File.join(@root, ".cache", "render", key)
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

  def test_loudness_gate_runs_on_every_mix_and_refuses_only_a_final
    out = StringIO.new
    run_render(out: out)
    assert_match(/loudness gate: pass: integrated -16\.2 LUFS/, out.string)
    run_render
    assert_equal 1, @calls[:loudness].size, "the grade is cached by the MP4 hash"

    @ebur128_out = File.read(File.join(__dir__, "fixtures", "walkthrough", "loudness", "over_peak.txt"))
    FileUtils.rm_f(Dir.glob(File.join(@root, ".cache", "render", "*", WalkthroughLoudness::CACHE)))
    out = StringIO.new
    assert run_render(out: out)[:mp4], "a draft logs the failure and goes on"
    assert_match(/loudness gate: fail: true peak -0\.8 dBTP/, out.string)
    err = assert_raises(WalkthroughLoudness::LoudnessError) { run_render(final: true, gates: { roast: false, allow_ux: true }) }
    assert_includes err.message, "-16 +/- 1 LUFS"
  end

  # AAC overshoot left a master at -0.8 dBTP behind a -3 dBTP limiter; pass 2
  # reruns with the ceiling lowered by the overshoot and the master passes.
  def test_master_over_the_peak_gate_rerenders_with_a_lower_ceiling
    over = File.read(File.join(__dir__, "fixtures", "walkthrough", "loudness", "over_peak.txt"))
    run_render
    FileUtils.rm_rf(File.join(@root, ".cache", "render"))
    @calls[:docker].clear
    @ebur128_queue = [ over ]
    out = StringIO.new
    run_render(out: out)
    pass2s = @calls[:docker].select { |a| a.join(" ").include?("alimiter") && !a.include?("null") }
    assert_equal 2, pass2s.size, "one rerun after the over-peak master"
    assert_includes pass2s.first.join(" "), WalkthroughFfmpeg::LIMITER
    assert_includes pass2s.last.join(" "), "alimiter=limit=#{WalkthroughFfmpeg.limit(-4.7)}:"
    assert_match(/master true peak -0\.8 dBTP over -2\.0 after AAC; re-rendering with limiter ceiling -4\.7 dBTP/, out.string)
    assert_match(/loudness gate: pass: integrated -16\.2 LUFS, true peak/, out.string)
  end

  def test_final_reports_the_craft_gate_and_never_spends_on_it
    out = StringIO.new
    result = run_render(final: true, gates: { roast: false, allow_ux: true }, out: out)
    refute result[:craft][:approved]
    assert_match(/craft gate: not approved: no craft roast round/, out.string)
    assert_match(/roast\.rb --video \S+-final\.mp4 .*--estimate-only/, out.string)
    assert File.file?(File.join(@root, "roast", WalkthroughCraft::BRIEF))
    assert_empty @calls[:roast]

    master = result[:deliverable][:mp4]
    critic = { "score" => 9, "issues" => [], "craft" => { "version" => 1, "master_sha256" => WalkthroughCraft.sha256(master) } }
    File.write(File.join(@root, "roast", "round-1.video.json"), JSON.generate(critic))
    out = StringIO.new
    assert run_render(final: true, gates: { roast: false, allow_ux: true }, out: out)[:craft][:approved], out.string
    assert_nil run_render[:craft], "a draft is exempt"
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
    assert_equal 4, @calls[:docker].size
    assert_equal "mp4", File.read(second[:mp4])
  end

  def test_failed_pass_two_leaves_no_cached_mp4_and_the_next_run_reassembles
    real = providers[:docker]
    failing = providers.merge(docker: lambda do |argv|
      next real.call(argv) unless argv.last.end_with?("walkthrough.mp4")

      File.binwrite(argv.last.sub(%r{\A/work/}, "#{@root}/"), "partial")
      [ "boom", Status.new(false) ]
    end)
    assert_raises(WalkthroughRender::FfmpegError) { run_render(providers: failing) }
    assert_empty Dir.glob(File.join(@root, ".cache", "render", "*", "walkthrough.mp4")), "a failed assembly is never a cache hit"
    result = run_render
    assert_equal "mp4", File.read(result[:mp4])
  end

  def test_zero_byte_pass_two_output_is_not_kept
    real = providers[:docker]
    empty = providers.merge(docker: lambda do |argv|
      next real.call(argv) unless argv.last.end_with?("walkthrough.mp4")

      File.binwrite(argv.last.sub(%r{\A/work/}, "#{@root}/"), "")
      [ "", Status.new(true) ]
    end)
    assert_raises(WalkthroughRender::MissingCacheError) { run_render(providers: empty) }
    assert_empty Dir.glob(File.join(@root, ".cache", "render", "*", "walkthrough.mp4"))
  end

  def test_burned_captions_never_reuse_a_soft_render
    soft = run_render
    @calls[:docker].clear
    burned = run_render(burn_captions: true)
    assert_equal 4, @calls[:docker].size, "burn re-runs ffmpeg instead of reusing the soft mp4"
    refute_equal soft[:mp4], burned[:mp4]
    assert_equal File.join(File.dirname(soft[:mp4]) + "-burn", "walkthrough.mp4"), burned[:mp4]
    @calls[:docker].clear
    run_render(burn_captions: true)
    assert_empty @calls[:docker], "a cached burned render is reused"
  end

  # QA-L7-3: a silent board writes an empty SRT; it renders with burned
  # captions on and no captions key, the empty track skipped cleanly.
  def test_silent_board_renders_without_a_caption_track
    b = board
    b["scenes"].each { |s| s.delete("narration") }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    result = run_render(burn_captions: true)
    assert_empty @calls[:tts]
    assert_equal "", File.read(File.join(File.dirname(result[:mp4]), "captions.srt")).strip
    pass2 = @calls[:docker].last.join(" ")
    refute_includes pass2, "captions.srt", "neither a subtitle input nor a burn filter for an empty SRT"
    refute_includes pass2, "subtitles="
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

  # A cached capture laid out at the browser's 800x600 default instead of
  # the board's 640x360 viewport is stale: it is recaptured, not reused.
  def test_a_wrong_size_cached_capture_is_recaptured
    first = run_render
    entry = first[:manifest]["scenes"].first
    File.binwrite(File.join(@root, ".cache", "frames", entry["frames_key"], "000001.png"), PngFixture.png(800, 600))
    @calls.clear
    run_render
    assert_equal [ entry["id"] ], @calls[:capture]
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

  def test_low_disk_refuses_before_any_paid_call
    run = WalkthroughRender::Run.new(@root, providers: providers.merge(free_bytes: ->(_) { 1024 }), out: StringIO.new, gates: { roast: false })
    assert_raises(WalkthroughHousekeeping::NoSpaceError) { run.call }
    assert_empty @calls
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

  def test_silent_cut_takes_the_free_broll_fallback_and_never_generates
    write_broll_board
    out = StringIO.new
    run_render(out: out, providers: providers.merge(broll: broll_provider("generated")))
    assert_equal 1, @calls[:broll].size, "only the narrated draft asks for the clip"
    assert_includes out.string, "shed: b-roll kenburns fallback (the silent cut never generates)"
    assert_match(/draft-01: silent; first cut, 4 scenes/, draft_lines(out.string).first)
  end

  def test_broll_clip_is_normalized_and_enters_the_timeline_without_capture
    write_broll_board
    result = run_render(providers: providers.merge(broll: broll_provider("generated")))
    assert_equal %w[list detail hero] * 2, @calls[:capture], "an ai-broll scene is never captured (silent cut, then draft)"
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

  def test_failed_broll_overlay_leaves_no_completion_marker_and_retries
    write_broll_board
    File.binwrite(File.join(@root, "screens", "assets", "title.png"), "PNG")
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["scenes"].last["broll"]["overlay"] = "screens/assets/title.png"
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    base = providers
    overlay = ->(ok) { base.merge(docker: lambda do |argv|
      if argv.join(" ").include?("filter_complex overlay")
        @calls[:overlay] << ok
        next [ ok ? "" : "overlay boom", Status.new(ok) ]
      end

      base[:docker].call(argv)
    end, broll: broll_provider("generated")) }
    assert_raises(WalkthroughRender::FfmpegError) { run_render(providers: overlay.call(false)) }
    markers = Dir.glob(File.join(@root, ".cache", "frames", "*", "cursor.json"))
    assert(markers.none? { |m| File.read(m) == "[]" }, "a failed overlay leaves no b-roll completion marker")
    @calls.clear
    run_render(providers: overlay.call(true))
    assert_equal [ true, true ], @calls[:overlay], "the next render retries the overlay (silent cut fallback, then the clip) instead of a cache hit"
  end

  def test_broll_overlay_path_with_spaces_is_shell_escaped
    write_broll_board
    File.binwrite(File.join(@root, "screens", "assets", "title overlay.png"), "PNG")
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["scenes"].last["broll"]["overlay"] = "screens/assets/title overlay.png"
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    base = providers
    scripts = []
    docker = lambda do |argv|
      next scripts.push(argv.last) && [ "", Status.new(true) ] if argv.join(" ").include?("filter_complex overlay")

      base[:docker].call(argv)
    end
    run_render(providers: base.merge(docker: docker, broll: broll_provider("generated")))
    assert_includes scripts.first, "title\\ overlay.png"
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
    run_render(providers: providers.merge(broll: broll_provider("generated")), max_usd: 5.0)
    assert_in_delta 5.0, @budgets.first.ceiling
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

  def test_draft_roast_through_real_critique_is_scanned_for_sensitive_terms
    terms = File.join(@root, "terms.txt")
    File.write(terms, "narration by scene")
    ENV["CF_SENSITIVE_TERMS_FILE"] = terms
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers.merge(roast: ->(**kw) { Roast.critique(**kw) }), out: out).call
    assert_includes out.string, "roast: skipped (roast refused: 1 sensitive term(s)"
    refute_includes out.string, "narration by scene"
    refute File.exist?(File.join(@root, "roast", "round-1.json"))
  ensure
    ENV.delete("CF_SENSITIVE_TERMS_FILE")
  end

  def keyed_roast = providers.merge(roast: ->(**) { WalkthroughEnv.openai_key! && @critic })

  def test_unenrolled_draft_roast_needs_enrollment_instead_of_skipping
    with_enrolled do
      assert_raises(WalkthroughEnv::NeedsEnrollment) do
        WalkthroughRender::Run.new(@root, providers: keyed_roast, out: StringIO.new).call
      end
    end
    refute File.exist?(File.join(@root, "roast", "round-1.json"))
  end

  def test_deferred_draft_roast_skips_the_round_and_keeps_rendering
    out = StringIO.new
    with_enrolled("openai") do
      CfSecretStore.defer(CfProjectIdentity.for(Dir.pwd).slug, "openai")
      capture_io { WalkthroughRender::Run.new(@root, providers: keyed_roast, out: out).call }
    end
    assert_match(/roast: skipped \(\[cf\] openai deferred until \S+; skipping paid step\)/, out.string)
    refute File.exist?(File.join(@root, "roast", "round-1.json"))
  end

  def failing_roast(status, body = "{}")
    providers.merge(roast: lambda do |**|
      raise CfProviderError.classify(provider: "openai", status: status, body: body, key: "sk-test-secret")
    end)
  end

  def test_revoked_or_quota_draft_roast_surfaces_instead_of_skipping
    [ [ 401, "{}" ], [ 429, '{"error":{"code":"insufficient_quota"}}' ] ].each do |status, body|
      err = assert_raises(CfProviderError::Failure) do
        WalkthroughRender::Run.new(@root, providers: failing_roast(status, body), out: StringIO.new).call
      end
      assert err.surface?, status.to_s
    end
  end

  def test_server_error_draft_roast_still_skips
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: failing_roast(503), out: out).call
    assert_includes out.string, "roast: skipped (OpenAI HTTP 503 server"
  end

  def test_allow_sensitive_gate_reaches_the_roast_provider
    seen = nil
    prov = providers.merge(roast: lambda do |**kw|
      seen = kw[:allow_sensitive]
      @critic
    end)
    WalkthroughRender::Run.new(@root, providers: prov, out: StringIO.new, gates: { allow_sensitive: true }).call
    assert_equal true, seen
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

  # The gate speaks before any capture: it names the missing roast and the
  # exact --draft command, on the run output as well as in the error.
  def test_final_without_a_roast_names_the_draft_command_before_capturing
    out = StringIO.new
    err = assert_raises(WalkthroughRoast::OpenFindingsError) { run_render(final: true, out: out, gates: { roast: true }) }
    assert_includes err.message, "no draft roast on record"
    assert_includes err.message, "walkthrough_render.rb #{Shellwords.escape(@root)} --draft"
    assert_includes out.string, "--draft"
    refute File.exist?(File.join(@root, "manifest.json")), "refused before any render work"
  end

# A directory with a space comes back quoted, so the printed command
# renders the same walkthrough when pasted.
def test_draft_command_escapes_a_directory_with_spaces
  spaced = File.join(File.dirname(@root), "My Project")
  FileUtils.cp_r(@root, spaced)
  cmd = WalkthroughRender::Run.new(spaced, providers: providers, out: StringIO.new).send(:draft_command)
  assert_equal [ "ruby", "~/.claude/cf/bin/walkthrough_render.rb", spaced, "--draft" ], Shellwords.split(cmd)
ensure
  FileUtils.rm_rf(spaced) if spaced
end

  def test_finished_loop_takes_no_further_paid_round
    WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new).call
    @calls[:roast].clear
    out = StringIO.new
    WalkthroughRender::Run.new(@root, providers: providers, out: out).call
    assert_empty @calls[:roast]
    assert_includes out.string, "roast: loop finished"
  end

  # A converged roast holds only for the content it reviewed: each kind of
  # authored edit reopens the loop for one more paid round and blocks --final.
  def test_content_edits_after_convergence_reopen_the_roast_loop
    edits = {
      screen: -> { File.write(File.join(@root, "screens", "detail.html"), "<html><body>changed</body></html>") },
      narration: lambda do
        b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
        b["scenes"][0]["narration"]["text"] = "Scene list says something new."
        File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
      end,
      seed: -> { File.write(File.join(@root, "data", "seed.json"), JSON.generate("items" => [ { "id" => 2 } ])) },
      camera: lambda do
        b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
        b["scenes"][0]["camera"] = { "zoom" => 1.2 }
        File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
      end
    }
    edits.each do |name, edit|
      FileUtils.rm_rf(File.join(@root, "roast"))
      WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new).call
      assert run_render(final: true, gates: { roast: true })[:mp4], "#{name}: unchanged content passes --final"
      edit.call
      err = assert_raises(WalkthroughRoast::OpenFindingsError, name.to_s) { run_render(final: true, gates: { roast: true }) }
      assert_includes err.message, "content changed since round 1", name.to_s
      @calls[:roast].clear
      WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new).call
      assert_equal 1, @calls[:roast].size, "#{name}: edit takes a new round"
      assert run_render(final: true, gates: { roast: true })[:mp4], "#{name}: re-roasted content passes --final"
    end
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

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def test_draft_and_final_land_beside_the_storyboard_and_survive_a_cache_delete
    draft = run_render
    assert File.file?(File.join(@root, "demo-draft-01.mp4")), "the silent cut is draft-01"
    assert_equal File.join(@root, "demo-draft-02.mp4"), draft[:deliverable][:mp4]
    assert_equal File.binread(draft[:mp4]), File.binread(File.join(@root, "demo-draft-02.mp4"))
    assert File.file?(File.join(@root, "demo-draft-02.vtt"))
    assert File.file?(draft[:mp4]), "the cache copy stays where the renderer expects it"
    final = run_render(final: true)
    assert_equal File.join(@root, "demo-final.mp4"), final[:deliverable][:mp4]
    FileUtils.rm_rf(File.join(@root, ".cache"))
    assert_equal "mp4", File.binread(File.join(@root, "demo-final.mp4"))
    assert File.file?(File.join(@root, "demo-final.vtt"))
    assert File.file?(File.join(@root, "demo-draft-02.mp4"))
    assert_empty Dir.glob(File.join(@root, ".demo-*.tmp-*")), "no temp file is left behind"
  end

  def test_final_prunes_superseded_renders_and_dead_frames_but_keeps_paid_audio
    run_render
    cache = File.join(@root, ".cache")
    old = File.join(cache, "render", "superseded")
    FileUtils.mkdir_p(old)
    File.binwrite(File.join(old, "walkthrough.mp4"), "old")
    dead = File.join(cache, "frames", "dead-scene-key")
    FileUtils.mkdir_p(dead)
    audio = Dir.glob(File.join(cache, "audio", "*.mp3"))
    refute_empty audio
    out = StringIO.new
    final = run_render(final: true, out: out)
    refute File.exist?(old)
    refute File.exist?(dead)
    assert File.file?(final[:mp4]), "the current render dir stays"
    audio.each { |a| assert File.file?(a) }
    final[:manifest]["scenes"].each { |s| assert File.directory?(File.join(cache, "frames", s["frames_key"])) }
    assert_includes out.string, "prune: dropped"
  end

  # The render, the share copy, and every probe write or read the board's
  # bind mount as the host user, never root (a root-owned share copy breaks
  # sync tools and later edits on Linux).
  def test_every_render_container_runs_as_the_host_user
    run_render(final: true)
    all = @calls[:docker] + @calls[:loudness] + @share_calls.to_a
    refute_empty @share_calls.to_a, "the share copy was encoded"
    all.each do |argv|
      at = argv.index("--user")
      refute_nil at, argv.join(" ")
      assert_equal "#{Process.uid}:#{Process.gid}", argv[at + 1]
    end
  end

  def test_a_refused_cache_cleanup_warns_and_keeps_the_final
    run_render
    foreign = Dir.mktmpdir
    cache = File.join(@root, ".cache")
    FileUtils.cp_r(File.join(cache, "."), foreign)
    FileUtils.rm_rf(cache)
    File.symlink(foreign, cache)
    out = StringIO.new
    final = run_render(final: true, out: out)
    assert File.file?(File.join(@root, "demo-final.mp4"))
    assert File.file?(final[:mp4])
    assert_match(/warning: cache cleanup skipped: refusing: .* the render succeeded/, out.string)
    refute_includes out.string, "prune: dropped"
  ensure
    FileUtils.rm_rf(foreign) if foreign
  end

  def test_a_hand_made_cache_link_under_the_default_root_is_pruned
    run_render
    Dir.mktmpdir do |home|
      target = File.join(home, ".cache", "cf-walkthrough", "demo")
      FileUtils.mkdir_p(File.dirname(target))
      cache = File.join(@root, ".cache")
      FileUtils.cp_r(cache, target)
      FileUtils.rm_rf(cache)
      File.symlink(target, cache)
      FileUtils.mkdir_p(File.join(target, "render", "superseded"))
      out = StringIO.new
      with_env("XDG_CACHE_HOME" => File.join(home, ".cache")) { run_render(final: true, out: out) }
      refute File.exist?(File.join(target, "render", "superseded"))
      assert_includes out.string, "prune: dropped"
    end
  end

  def test_cache_root_override_links_the_cache_out_of_the_tree
    Dir.mktmpdir do |ext|
      with_env("CF_WALKTHROUGH_CACHE_ROOT" => ext) do
        result = run_render
        link = File.join(@root, ".cache")
        assert File.symlink?(link)
        target = File.join(File.realpath(ext), WalkthroughHousekeeping.cache_key(@root))
        assert_equal target, File.realpath(link)
        assert File.file?(File.join(target, "render", File.basename(File.dirname(result[:mp4])), "walkthrough.mp4"))
        assert_includes @calls[:docker].last.join(" "), "source=#{target}\",target=#{File.readlink(link)}"
        assert_includes File.read(File.join(@root, ".gitignore")).lines.map(&:strip), ".cache"
        assert File.file?(File.join(@root, "demo-draft-02.mp4"))
      end
    end
  end

  def test_render_warns_when_the_cache_passes_the_threshold
    out = StringIO.new
    with_env("CF_WALKTHROUGH_CACHE_WARN_GB" => "0.000000001") { run_render(out: out) }
    assert_match(/warning: .* over 1.0e-09 GB/, out.string)
    out = StringIO.new
    run_render(out: out)
    refute_includes out.string, "over 2.0 GB"
  end


  def test_screens_inline_cached_images_from_an_external_cache_root
    Dir.mktmpdir do |ext|
      with_env("CF_WALKTHROUGH_CACHE_ROOT" => ext) { test_final_inlines_high_quality_images_with_new_keys_and_mp4 }
      assert File.symlink?(File.join(@root, ".cache"))
    end
  end

  def test_prune_after_a_board_edit_keeps_the_render_it_recorded
    draft = run_render
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["scenes"][0]["camera"] = { "zoom" => 1.5 }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new).prune
    assert File.file?(draft[:mp4])
  end

  def test_music_start_sizes_the_bed_and_delays_it
    run_render
    full = @calls[:music].last
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["music"].merge!("start" => 1.5, "fade_in" => 0.05)
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    run_render
    assert_equal ElevenLabs.clamp_music_ms(WalkthroughStoryboard.timeline(b)["total_ms"] - 1500), @calls[:music].last
    assert_operator @calls[:music].last, :<, full
    assert_includes @calls[:docker].last.join(" "), "adelay=delays=1500:all=1,afade=t=in:st=1.500:d=0.050,"
  end

  def test_music_fade_out_reaches_the_mix_and_rekeys_the_render
    run_render
    first = @calls[:docker].last.join(" ")
    assert_match(/afade=t=out:st=[\d.]+:d=2\.500,/, first)
    paid = @calls[:music].size
    b = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    b["music"]["fade_out"] = 1
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    run_render
    assert_match(/afade=t=out:st=[\d.]+:d=1\.000,/, @calls[:docker].last.join(" "))
    assert_equal paid, @calls[:music].size
  end

  def set_board_target(name)
    path = File.join(@root, "storyboard.json")
    b = JSON.parse(File.read(path))
    b["target"] = name
    File.write(path, JSON.pretty_generate(b))
  end

  def fidelity_round(issues)
    critic = { "score" => 8, "summary" => "s", "issues" => issues,
               "thirty_second_test" => { "verdict" => "pass", "reason" => "r" }, "purpose_test" => [] }
    Roast.write_round(File.join(@root, WalkthroughRoast::FIDELITY_DIR), 1, critic)
  end

  def test_fidelity_gate_is_active_only_for_a_reference_target
    gates = { roast: false, allow_roast: true, fidelity_targets: [ "portal" ] }
    assert run_render(final: true, gates: gates)[:mp4], "a storyboard without a target is untouched"
    set_board_target("admin")
    assert run_render(final: true, gates: gates)[:mp4], "a target with no reference is untouched"
    set_board_target("portal")
    err = assert_raises(WalkthroughRoast::OpenFindingsError) { run_render(final: true, gates: gates) }
    assert_includes err.message, "no fidelity roast on record"
  end

  def test_fidelity_gate_blocks_open_p1_and_the_override_works
    set_board_target("portal")
    gates = { roast: false, allow_roast: true, fidelity_targets: [ "portal" ] }
    fidelity_round([ { "priority" => "P1", "where" => "001.png header", "problem" => "foreign type scale", "fix" => "use the kit" } ])
    err = assert_raises(WalkthroughRoast::OpenFindingsError) { run_render(final: true, gates: gates) }
    assert_includes err.message, "fidelity finding(s)"
    assert_includes err.message, "--allow-fidelity-findings"
    assert run_render(final: true, gates: gates.merge(allow_fidelity: true))[:mp4]
  end

  def test_fidelity_gate_passes_on_p2_only_and_records_the_signoff
    set_board_target("portal")
    fidelity_round([ { "priority" => "P2", "where" => "001.png", "problem" => "radius", "fix" => "4px" } ])
    assert run_render(final: true, gates: { roast: false, allow_roast: true, fidelity_targets: [ "portal" ] })[:mp4]
    signoff = JSON.parse(File.read(File.join(@root, WalkthroughRoast::FIDELITY_DIR, "signoff.json")))
    assert_equal 1, signoff["round"]
  end
  # -- draft delivery ---------------------------------------------------------

  def draft_lines(text) = text.scan(/^```\n(walkthrough-draft: .*)\n```$/).flatten

  def test_silent_cut_is_delivered_before_any_paid_call
    out = StringIO.new
    tts_at_cut = nil
    spy = providers
    capture = spy[:capture]
    spy[:capture] = lambda do |**kw|
      tts_at_cut ||= @calls[:tts].size
      capture.call(**kw)
    end
    run_render(out: out, providers: spy)
    assert_equal 0, tts_at_cut, "the first capture (the silent cut) ran before narration"
    log = out.string
    assert_operator log.index("silent cut:"), :<, log.index("list: narrating")
    lines = draft_lines(log)
    assert_equal 2, lines.size, "one fenced line per deliverable"
    assert_match(%r{\Awalkthrough-draft: #{Regexp.escape(@root)}/demo-draft-01\.mp4 \| draft-01: silent; first cut, 3 scenes\z}, lines[0])
    assert_match(%r{demo-draft-02\.mp4 \| draft-02: narrated; scenes list, detail and hero refilmed\z}, lines[1])
    kinds = JSON.parse(File.read(File.join(@root, "demo-deliveries.json")))["deliveries"].map { |e| e["kind"] }
    assert_equal %w[silent narrated], kinds
    shares = log.scan(/^```\n(walkthrough-share: .*)\n```$/).flatten
    assert_equal [ "walkthrough-share: #{@root}/demo-draft-01-share.mp4", "walkthrough-share: #{@root}/demo-draft-02-share.mp4" ], shares
    share_call = @share_calls.find { |a| a.last == "/work/demo-draft-01-share.mp4" }
    assert_includes share_call, ChangeDocker::FFMPEG_IMAGE
  end

  # A failed free cut stops the run before any paid call: the paid providers
  # refuse outright, and none is ever reached.
  def test_failed_silent_cut_stops_before_any_paid_call
    refuse = ->(name) { ->(**) { raise "paid #{name} called after a failed silent cut" } }
    ps = providers.merge(tts: refuse.call(:tts), music: refuse.call(:music), image: refuse.call(:image),
                         broll: refuse.call(:broll), capture: ->(**) { raise Errno::ENOENT, "walkthrough_ease.js" })
    out = StringIO.new
    err = assert_raises(Errno::ENOENT) { run_render(providers: ps, out: out) }
    assert_includes err.message, "walkthrough_ease.js"
    assert_match(/silent cut failed: Errno::ENOENT: .*walkthrough_ease\.js; the run stopped before any paid call/, out.string)
    refute_includes out.string, "the run goes on"
  end

  # A remote font that cannot be fetched stops the run, naming its URL,
  # before the silent cut, any capture, or any paid call.
  def test_failed_font_fetch_stops_before_any_paid_call
    url = "https://fonts.googleapis.com/css2?family=Inter"
    File.write(File.join(@root, "screens", "list.html"), "<html><head><link rel='stylesheet' href='#{url}'></head><body>x</body></html>")
    refuse = ->(name) { ->(**) { raise "paid #{name} called after a failed font fetch" } }
    ps = providers.merge(tts: refuse.call(:tts), music: refuse.call(:music), image: refuse.call(:image), broll: refuse.call(:broll),
                         capture: refuse.call(:capture),
                         font_fetch: ->(u) { raise WalkthroughFonts::FetchError, "font fetch failed: #{u} returned HTTP 503" })
    out = StringIO.new
    err = assert_raises(WalkthroughFonts::FetchError) { run_render(providers: ps, out: out) }
    assert_includes err.message, url
    assert_includes out.string, "the run stopped before any paid call"
    refute_includes out.string, "estimate"
  end

  # -- --max-usd ceiling ------------------------------------------------------

  def refusing(*names)
    names.to_h { |n| [ n, ->(**) { raise "paid #{n} called over the --max-usd ceiling" } ] }
  end

  def paid_refusers = refusing(:tts, :music, :image, :broll, :roast)

  # The authored measured_ms matches what the stub TTS measures, so the
  # estimate prices the music bed at the length the run composes.
  def estimate_usd
    b = board
    b["scenes"].each { |s| s["narration"]["measured_ms"] = s["narration"]["text"].length * 50 }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    run = WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new, gates: { roast: false })
    run.call(estimate_only: true)
    run.instance_variable_get(:@estimated_usd)
  end

  def test_zero_ceiling_delivers_the_silent_cut_and_refuses_every_paid_call
    out = StringIO.new
    err = assert_raises(WalkthroughRender::SpendCeilingError) do
      run_render(providers: providers.merge(paid_refusers), out: out, max_usd: 0.0, gates: { roast: true })
    end
    assert_match(/paid estimate \$\d+\.\d\d passes the --max-usd \$0\.00 ceiling/, err.message)
    assert File.file?(File.join(@root, "demo-draft-01.mp4")), "the free silent cut is delivered"
    refute_includes out.string, "narrating"
    refute_includes out.string, "music: composing"
  end

  def test_music_alone_over_the_ceiling_is_refused
    b = board
    b["scenes"].each { |s| s.delete("narration") }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    out = StringIO.new
    err = assert_raises(WalkthroughRender::SpendCeilingError) do
      run_render(providers: providers.merge(paid_refusers), out: out, max_usd: 0.0)
    end
    assert_includes out.string, "narration $0.00"
    assert_includes err.message, "--max-usd $0.00"
  end

  def test_ceiling_just_under_the_estimate_is_refused
    est = estimate_usd
    assert_operator est, :>, 0.01
    assert_raises(WalkthroughRender::SpendCeilingError) do
      run_render(providers: providers.merge(paid_refusers), max_usd: est - 0.001)
    end
  end

  def test_ceiling_at_the_estimate_proceeds
    est = estimate_usd
    result = run_render(max_usd: est)
    assert result[:mp4]
    assert_equal 1, @calls[:music].size
    refute_empty @calls[:tts]
  end

  def test_music_repriced_after_long_narration_is_refused
    est = estimate_usd
    long = providers[:tts]
    slow_tts = ->(**kw) { long.call(**kw).merge(measured_ms: 10_000) }
    out = StringIO.new
    err = assert_raises(WalkthroughRender::SpendCeilingError) do
      run_render(providers: providers.merge(tts: slow_tts).merge(refusing(:music)), out: out, max_usd: est)
    end
    assert_includes err.message, "music at its measured length"
    refute_includes out.string, "music: composing"
  end

  def test_uncached_image_over_the_ceiling_is_refused
    b = board
    b["scenes"][0]["images"] = [ { "id" => "hero", "prompt" => "a hero", "size" => "1024x1024" } ]
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    assert_raises(WalkthroughRender::SpendCeilingError) do
      run_render(providers: providers.merge(paid_refusers), max_usd: 0.0)
    end
  end

  def test_broll_over_the_ceiling_is_refused_and_takes_the_free_fallback
    write_broll_board
    out = StringIO.new
    assert_raises(WalkthroughRender::SpendCeilingError) do
      run_render(providers: providers.merge(paid_refusers), out: out, max_usd: 0.0)
    end
    assert_includes out.string, "the silent cut never generates"
  end

  def test_final_over_the_ceiling_is_refused_without_a_cut
    out = StringIO.new
    assert_raises(WalkthroughRender::SpendCeilingError) do
      run_render(providers: providers.merge(paid_refusers), out: out, max_usd: 0.0, final: true)
    end
    refute_includes out.string, "silent cut"
  end

  def test_roast_round_past_what_the_ceiling_leaves_is_skipped
    est = estimate_usd
    out = StringIO.new
    result = run_render(providers: providers.merge(refusing(:roast)), out: out, max_usd: est, gates: { roast: true })
    assert result[:mp4]
    assert_includes out.string, "roast: skipped, the round"
  end

  # A --scene run still prefetches every screen's fonts: dependents and the
  # recomputed keys prepare scenes beyond the target.
  def test_scene_run_prefetches_fonts_for_other_scenes
    url = "https://fonts.googleapis.com/css2?family=Inter"
    File.write(File.join(@root, "screens", "detail.html"), "<html><head><link rel='stylesheet' href='#{url}'></head><body>x</body></html>")
    ps = providers.merge(font_fetch: ->(u) { raise WalkthroughFonts::FetchError, "font fetch failed: #{u} returned HTTP 503" })
    err = assert_raises(WalkthroughFonts::FetchError) { run_render(providers: ps, scene: "list") }
    assert_includes err.message, url
    assert_empty @calls[:tts]
  end

  # The documented exception (#464): an uncached generated image is a paid
  # step, so the free cut is skipped, said plainly, and the paid run goes on.
  def test_silent_cut_skipped_for_an_uncached_generated_image
    b = board
    b["scenes"][0]["images"] = [ { "prompt" => "a hero", "size" => "1024x1024" } ]
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
    out = StringIO.new
    run_render(out: out)
    assert_includes out.string, "silent cut: skipped: scene list needs an uncached generated image"
    assert_equal 3, @calls[:tts].size, "the paid run goes on"
    assert_equal %w[list detail hero], @calls[:capture], "only the narrated draft captured"
  end

  def test_silent_cut_writes_nothing_back
    before = File.read(File.join(@root, "storyboard.json"))
    run = WalkthroughRender::Run.new(@root, providers: providers, out: StringIO.new, silent: true,
                                            board: WalkthroughDraftBoard.silent(WalkthroughStoryboard.load(File.join(@root, "storyboard.json"))))
    run.call
    assert_equal before, File.read(File.join(@root, "storyboard.json"))
    refute File.exist?(File.join(@root, "manifest.json"))
    assert_empty @calls[:tts]
    assert_empty @calls[:music]
  end

  def test_no_silent_cut_once_audio_is_cached
    run_render
    out = StringIO.new
    run_render(out: out)
    refute_includes out.string, "silent cut:"
    assert_equal 1, draft_lines(out.string).size
    assert_match(/draft-03: narrated; no picture change/, draft_lines(out.string).first)
  end

  def test_final_only_produces_only_the_final
    out = StringIO.new
    result = run_render(final_only: true, out: out, gates: { roast: false, allow_ux: true })
    assert_equal File.join(@root, "demo-final.mp4"), result[:deliverable][:mp4]
    assert_empty Dir.glob(File.join(@root, "demo-draft-*.mp4"))
    assert_equal [ "walkthrough-draft: #{@root}/demo-final.mp4 | final: final; first cut, 3 scenes" ], draft_lines(out.string)
  end

  def test_scene_regeneration_is_delivered_as_its_own_draft
    run_render
    out = StringIO.new
    run_render(scene: "detail", out: out)
    assert_match(/draft-03: scene; /, draft_lines(out.string).last)
  end

  def pending_board
    b = board
    b["scenes"][1]["pending"] = { "reason" => "waiting on PR 12" }
    File.write(File.join(@root, "storyboard.json"), JSON.pretty_generate(b))
  end

  def test_pending_scene_renders_a_placeholder_and_a_partial_cut
    pending_board
    out = StringIO.new
    result = run_render(out: out)
    entry = result[:deliverable][:entry]
    assert_equal "partial", entry["kind"]
    assert_equal({ "detail" => "waiting on PR 12" }, entry["placeholders"])
    assert_includes entry["caption"], "scene detail still a placeholder (waiting on PR 12)"
    saved = JSON.parse(File.read(File.join(@root, "storyboard.json")))
    assert_equal({ "reason" => "waiting on PR 12" }, saved["scenes"][1]["pending"], "the authored scene is written back, not its card")
    assert_equal "screens/detail.html", saved["scenes"][1].dig("screen", "html")
  end

  def test_final_refuses_while_a_placeholder_remains
    pending_board
    err = assert_raises(WalkthroughStoryboard::ValidationError) { run_render(final: true) }
    assert_includes err.message, "detail (waiting on PR 12)"
    assert_empty @calls[:tts], "refused before any paid call"
  end

  def test_silent_cut_uses_provisional_timing_for_anchored_ops
    anchor_board("speaks")
    out = StringIO.new
    run_render(out: out)
    assert_includes draft_lines(out.string).first, "provisional timing (pre-narration)"
    refute_includes draft_lines(out.string).last, "provisional"
  end
end
