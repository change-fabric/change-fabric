# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "base64"
require "json"
require "stringio"
require_relative "../scripts/elevenlabs"

class ElevenLabsTest < Minitest::Test
  KEY = "sk_test_secret_value_123"
  Resp = Struct.new(:code, :body, :headers) do
    def [](name) = (headers || {})[name]
  end

  def setup
    @dir = Dir.mktmpdir
    @saved = %w[ELEVEN_LABS_API_KEY ELEVENLABS_API_KEY].to_h { |k| [ k, ENV.fetch(k, nil) ] }
    ENV["ELEVEN_LABS_API_KEY"] = KEY
    ENV.delete("ELEVENLABS_API_KEY")
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def tts_body
    JSON.generate("audio_base64" => Base64.strict_encode64("MP3DATA"),
                  "alignment" => { "characters" => %w[a], "character_start_times_seconds" => [ 0.0 ],
                                   "character_end_times_seconds" => [ 9.9 ] },
                  "normalized_alignment" => { "characters" => %w[H i], "character_start_times_seconds" => [ 0.0, 0.1 ],
                                              "character_end_times_seconds" => [ 0.1, 1.25 ] })
  end

  def test_tts_request_shape
    r = ElevenLabs.tts_request(text: "Hi", voice_id: "v1", model: "eleven_multilingual_v2",
                                          output_format: "mp3_44100_128", settings: { "stability" => 0.5 })
    assert_equal "https://api.elevenlabs.io/v1/text-to-speech/v1/with-timestamps?output_format=mp3_44100_128", r.uri.to_s
    assert_equal({ "text" => "Hi", "model_id" => "eleven_multilingual_v2", "voice_settings" => { "stability" => 0.5 } }, r.body)
  end

  def test_tts_request_omits_empty_voice_settings
    r = ElevenLabs.tts_request(text: "Hi", voice_id: "v1", model: "m", output_format: "mp3_44100_128", settings: {})
    refute r.body.key?("voice_settings")
  end

  def test_decode_prefers_normalized_alignment
    d = ElevenLabs.decode_tts(tts_body)
    assert_equal "MP3DATA", d[:audio]
    assert_equal %w[H i], d[:alignment]["characters"]
    assert_equal 1250, d[:measured_ms]
  end

  def test_tts_stores_audio_and_alignment_and_hits_cache
    calls = []
    transport = lambda do |req, key|
      calls << [ req, key ]
      Resp.new("200", tts_body)
    end
    args = { text: "Hi", voice_id: "v1", model: "m", output_format: "mp3_44100_128", cache_root: @dir }
    out = ElevenLabs.tts(**args, transport: transport)
    assert_equal "MP3DATA", File.binread(out[:audio])
    assert_equal %w[H i], JSON.parse(File.read(out[:alignment]))["characters"]
    assert_equal 1250, out[:measured_ms]
    assert_equal KEY, calls.first[1]
    again = ElevenLabs.tts(**args, transport: ->(*) { flunk "cache miss" })
    assert_equal 1250, again[:measured_ms]
    assert_equal 1, calls.length
  end

  def test_music_request_clamps_length
    assert_equal 3000, ElevenLabs.music_request(prompt: "p", length_ms: 10, model: "music_v1").body["music_length_ms"]
    assert_equal 600_000, ElevenLabs.music_request(prompt: "p", length_ms: 9_000_000, model: "music_v1").body["music_length_ms"]
  end

  def test_composition_plan_rules
    ok = { "sections" => [ { "duration_ms" => 5000 } ] }
    assert_equal ok, ElevenLabs.music_request(composition_plan: ok, length_ms: 5000, model: "m").body["composition_plan"]
    assert_raises(ElevenLabs::RequestError) do
      ElevenLabs.music_request(composition_plan: { "sections" => [ { "duration_ms" => 200_000 } ] }, length_ms: 1, model: "m")
    end
    assert_raises(ElevenLabs::RequestError) do
      ElevenLabs.music_request(composition_plan: ok.merge("seed" => 1), length_ms: 1, model: "m")
    end
  end

  def test_music_writes_cache
    out = ElevenLabs.music(prompt: "calm", length_ms: 30_000, model: "music_v1", cache_root: @dir,
                                      transport: ->(*) { Resp.new("200", "MUSIC") })
    assert_equal "MUSIC", File.binread(out[:path])
    assert_includes out[:path], "/music/"
  end

  def test_named_errors_and_scrubbed_key
    { 401 => ElevenLabs::AuthError, 402 => ElevenLabs::QuotaError,
      422 => ElevenLabs::RequestError }.each do |code, klass|
      body = JSON.generate("detail" => { "message" => "bad key #{KEY}" })
      err = assert_raises(klass) do
        ElevenLabs.perform(ElevenLabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                      transport: ->(*) { Resp.new(code.to_s, body) }, sleeper: ->(_) { })
      end
      refute_includes err.message, KEY
      assert_includes err.message, "[REDACTED]"
    end
  end

  def test_transport_exception_scrubbed
    err = assert_raises(ElevenLabs::RequestError) do
      ElevenLabs.perform(ElevenLabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { raise IOError, "boom #{KEY}" }, sleeper: ->(_) { })
    end
    refute_includes err.message, KEY
  end

  def test_429_backoff_then_success
    sleeps = []
    seq = [ Resp.new("429", "{}", { "retry-after" => "1.5" }), Resp.new("429", "{}"), Resp.new("200", "OK") ]
    body = ElevenLabs.perform(ElevenLabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                         transport: ->(*) { seq.shift }, sleeper: ->(s) { sleeps << s })
    assert_equal "OK", body
    assert_equal [ 1.5, 4 ], sleeps
  end

  def test_429_gives_up_after_three_retries
    sleeps = []
    assert_raises(ElevenLabs::RateLimitError) do
      ElevenLabs.perform(ElevenLabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { Resp.new("429", "{}") }, sleeper: ->(s) { sleeps << s })
    end
    assert_equal 3, sleeps.length
  end

  def test_missing_key_raises_named_error
    ENV.delete("ELEVEN_LABS_API_KEY")
    assert_raises(WalkthroughEnv::MissingKeyError) do
      ElevenLabs.perform(ElevenLabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { flunk }, sleeper: ->(_) { })
    end
  end

  def test_format_hint_on_422
    err = assert_raises(ElevenLabs::RequestError) do
      ElevenLabs.perform(ElevenLabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { Resp.new("422", '{"detail":"output_format not allowed"}') },
                                    sleeper: ->(_) { })
    end
    assert_includes err.message, "higher plan"
  end

  def test_estimate
    e = ElevenLabs.estimate(chars: 2000, music_ms: 120_000, model: "eleven_multilingual_v2")
    assert_in_delta 0.16, e[:tts_usd]
    assert_in_delta 0.30, e[:music_usd]
    assert_in_delta 0.46, e[:total_usd]
    assert_in_delta 0.08, ElevenLabs.estimate(chars: 2000, music_ms: 0, model: "eleven_flash_v2_5")[:tts_usd]
    assert_includes ElevenLabs.format_estimate(e), "$0.46"
  end

  # -- CLI ------------------------------------------------------------------

  def stub_transport(body: tts_body, code: 200)
    @http_calls = []
    lambda do |request, key|
      @http_calls << [ request, key ]
      Resp.new(code, body.respond_to?(:call) ? body.call(request) : body)
    end
  end

  def cli(*argv, transport: stub_transport)
    out = StringIO.new
    code = ElevenLabs::Cli.run(argv.map(&:to_s) + [ "--cache", @dir ], out: out, transport: transport, sleeper: ->(_s) { })
    [ code, out.string ]
  end

  def test_cli_narrate_text_writes_audio_alignment_and_srt
    code, out = cli("narrate", "--text", "Hi there", "--voice", "v1")
    assert_equal 0, code, out
    assert_equal 1, @http_calls.size
    assert_equal KEY, @http_calls.first.last
    audio = out[/^audio: (.+)$/, 1]
    assert_equal "MP3DATA", File.binread(audio)
    assert File.file?(out[/^alignment: (.+)$/, 1])
    assert_match(/\A1\n00:00:00,000 --> /, File.read(out[/^srt: (.+)$/, 1]))
    assert_match(/^ElevenLabs estimate: narration \$0\.00, music \$0\.00, total \$0\.00$/, out)
    refute_includes out, KEY
  end

  def test_cli_narrate_cache_hit_makes_no_call_and_needs_no_key
    cli("narrate", "--text", "Hi there", "--voice", "v1")
    ENV.delete("ELEVEN_LABS_API_KEY")
    code, out = cli("narrate", "--text", "Hi there", "--voice", "v1")
    assert_equal 0, code, out
    assert_empty @http_calls, "second run is served from the audio_key cache"
    assert_match(/^audio: /, out)
    assert_match(/narration \$0\.00/, out)
  end

  def test_cli_narrate_estimate_only_spends_nothing
    code, out = cli("narrate", "--text", "x" * 2000, "--voice", "v1", "--estimate-only")
    assert_equal 0, code, out
    assert_empty @http_calls
    assert_includes out, "narration $0.16"
    refute_match(/^audio: /, out)
  end

  def test_cli_narrate_without_voice_is_a_usage_error
    code, out = cli("narrate", "--text", "Hi")
    assert_equal 1, code
    assert_includes out, "narrate needs --voice"
    assert_empty @http_calls.to_a
  end

  def test_cli_unknown_subcommand_prints_usage
    code, out = cli("sing")
    assert_equal 2, code
    assert_includes out, "usage: elevenlabs.rb narrate|music"
  end

  def test_cli_maps_api_errors_to_exit_one_without_the_key
    transport = stub_transport(body: JSON.generate("detail" => { "message" => "bad #{KEY}" }), code: 401)
    code, out = cli("narrate", "--text", "Hi", "--voice", "v1", transport: transport)
    assert_equal 1, code
    assert_includes out, "ElevenLabs HTTP 401"
    refute_includes out, KEY
  end

  def write_board
    path = File.join(@dir, "storyboard.json")
    scene = ->(id, order, text) { { "id" => id, "order" => order, "narration" => { "text" => text } } }
    File.write(path, JSON.generate(
                       "voice" => { "voice_id" => "board-voice", "model" => "eleven_flash_v2_5", "output_format" => "mp3_44100_64" },
                       "music" => { "model" => "music_v1", "prompt" => "calm piano" },
                       "scenes" => [ scene.call("b", 2, "Second."), scene.call("a", 1, "First."), scene.call("c", 3, "") ]
                     ))
    path
  end

  def test_cli_narrate_reads_a_script_file
    script = File.join(@dir, "script.txt")
    File.write(script, "Line one.\nLine two.\n")
    code, out = cli("narrate", "--file", script, "--voice", "v1")
    assert_equal 0, code, out
    assert_equal "Line one.\nLine two.", @http_calls.first.first.body["text"]
  end

  def test_cli_narrate_voice_and_model_overrides
    cli("narrate", "--text", "Hi", "--voice", "v9", "--model", "eleven_flash_v2_5", "--format", "mp3_22050_32")
    req = @http_calls.first.first
    assert_includes req.path, "/v9/"
    assert_equal "eleven_flash_v2_5", req.body["model_id"]
    assert_equal "mp3_22050_32", req.query["output_format"]
  end

  def test_cli_narrate_storyboard_narrates_every_scene_in_order_using_the_board_voice
    code, out = cli("narrate", "--storyboard", write_board)
    assert_equal 0, code, out
    assert_equal %w[First. Second.], @http_calls.map { |req, _| req.body["text"] }, "empty narration is skipped"
    assert_includes @http_calls.first.first.path, "/board-voice/"
    assert_equal "eleven_flash_v2_5", @http_calls.first.first.body["model_id"]
    assert_equal %w[a b], out.scan(/^scene (\w+):/).flatten
  end

  def test_cli_narrate_storyboard_scene_flag_targets_one_scene
    code, out = cli("narrate", "--storyboard", write_board, "--scene", "b")
    assert_equal 0, code, out
    assert_equal [ "Second." ], @http_calls.map { |req, _| req.body["text"] }
  end

  def test_cli_narrate_unknown_scene_is_an_error
    code, out = cli("narrate", "--storyboard", write_board, "--scene", "zzz")
    assert_equal 1, code
    assert_includes out, "no narrated scene zzz"
  end

  def test_cli_narrate_needs_exactly_one_source
    code, out = cli("narrate", "--voice", "v1")
    assert_equal 1, code
    assert_includes out, "exactly one of --text, --file, --storyboard"
  end

  def test_cli_narrate_storyboard_shares_the_walkthrough_audio_cache_key
    board_path = write_board
    code, out = cli("narrate", "--storyboard", board_path, "--scene", "a")
    assert_equal 0, code, out
    board = JSON.parse(File.read(board_path))
    key = WalkthroughStoryboard.audio_key(board, board["scenes"][1])
    assert_equal File.join(@dir, "audio", "#{key}.mp3"), out[/^audio: (.+)$/, 1]
  end

  def music_transport = stub_transport(body: "MUSICBYTES")

  def test_cli_music_prompt_writes_track_and_prints_estimate
    code, out = cli("music", "--prompt", "calm piano", "--duration-ms", "60000", transport: music_transport)
    assert_equal 0, code, out
    req = @http_calls.first.first
    assert_equal "/v1/music", req.path
    assert_equal "calm piano", req.body["prompt"]
    assert_equal 60_000, req.body["music_length_ms"]
    assert_equal "MUSICBYTES", File.binread(out[/^music: (.+)$/, 1])
    assert_includes out, "music $0.15"
  end

  def test_cli_music_cache_hit_makes_no_call
    cli("music", "--prompt", "calm piano", "--duration-ms", "60000", transport: music_transport)
    code, out = cli("music", "--prompt", "calm piano", "--duration-ms", "60000", transport: music_transport)
    assert_equal 0, code, out
    assert_empty @http_calls
    assert_includes out, "music $0.00"
  end

  def test_cli_music_estimate_only_spends_nothing
    code, out = cli("music", "--prompt", "calm", "--duration-ms", "120000", "--estimate-only", transport: music_transport)
    assert_equal 0, code, out
    assert_empty @http_calls
    assert_includes out, "music $0.30"
  end

  def test_cli_music_composition_plan_file
    plan = File.join(@dir, "plan.json")
    File.write(plan, JSON.generate("sections" => [ { "section_name" => "intro", "duration_ms" => 10_000 } ]))
    code, out = cli("music", "--plan", plan, transport: music_transport)
    assert_equal 0, code, out
    assert_equal "intro", @http_calls.first.first.body["composition_plan"]["sections"].first["section_name"]
  end

  def test_cli_music_plan_with_seed_is_rejected_before_any_call
    plan = File.join(@dir, "plan.json")
    File.write(plan, JSON.generate("seed" => 1, "sections" => []))
    code, out = cli("music", "--plan", plan, transport: music_transport)
    assert_equal 1, code
    assert_includes out, "must not carry a seed"
    assert_empty @http_calls
  end

  def test_cli_music_storyboard_is_sized_to_the_timeline
    board = write_board
    code, out = cli("music", "--storyboard", board, transport: music_transport)
    assert_equal 0, code, out
    expected = ElevenLabs.clamp_music_ms(WalkthroughStoryboard.timeline(JSON.parse(File.read(board)))["total_ms"])
    req = @http_calls.first.first
    assert_equal expected, req.body["music_length_ms"]
    assert_equal "calm piano", req.body["prompt"]
    assert_equal "music_v1", req.body["model_id"]
  end

  def test_cli_music_needs_exactly_one_source
    code, out = cli("music", "--duration-ms", "5000", transport: music_transport)
    assert_equal 1, code
    assert_includes out, "exactly one of --prompt, --plan, --storyboard"
  end

  def test_cli_music_prompt_needs_a_duration
    code, out = cli("music", "--prompt", "calm", transport: music_transport)
    assert_equal 1, code
    assert_includes out, "--prompt needs --duration-ms"
  end
end
