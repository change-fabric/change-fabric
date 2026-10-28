# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "base64"
require "json"
require_relative "../scripts/walkthrough_elevenlabs"

class WalkthroughElevenlabsTest < Minitest::Test
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
    r = WalkthroughElevenlabs.tts_request(text: "Hi", voice_id: "v1", model: "eleven_multilingual_v2",
                                          output_format: "mp3_44100_128", settings: { "stability" => 0.5 })
    assert_equal "https://api.elevenlabs.io/v1/text-to-speech/v1/with-timestamps?output_format=mp3_44100_128", r.uri.to_s
    assert_equal({ "text" => "Hi", "model_id" => "eleven_multilingual_v2", "voice_settings" => { "stability" => 0.5 } }, r.body)
  end

  def test_tts_request_omits_empty_voice_settings
    r = WalkthroughElevenlabs.tts_request(text: "Hi", voice_id: "v1", model: "m", output_format: "mp3_44100_128", settings: {})
    refute r.body.key?("voice_settings")
  end

  def test_decode_prefers_normalized_alignment
    d = WalkthroughElevenlabs.decode_tts(tts_body)
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
    out = WalkthroughElevenlabs.tts(**args, transport: transport)
    assert_equal "MP3DATA", File.binread(out[:audio])
    assert_equal %w[H i], JSON.parse(File.read(out[:alignment]))["characters"]
    assert_equal 1250, out[:measured_ms]
    assert_equal KEY, calls.first[1]
    again = WalkthroughElevenlabs.tts(**args, transport: ->(*) { flunk "cache miss" })
    assert_equal 1250, again[:measured_ms]
    assert_equal 1, calls.length
  end

  def test_music_request_clamps_length
    assert_equal 3000, WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 10, model: "music_v1").body["music_length_ms"]
    assert_equal 600_000, WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 9_000_000, model: "music_v1").body["music_length_ms"]
  end

  def test_composition_plan_rules
    ok = { "sections" => [ { "duration_ms" => 5000 } ] }
    assert_equal ok, WalkthroughElevenlabs.music_request(composition_plan: ok, length_ms: 5000, model: "m").body["composition_plan"]
    assert_raises(WalkthroughElevenlabs::RequestError) do
      WalkthroughElevenlabs.music_request(composition_plan: { "sections" => [ { "duration_ms" => 200_000 } ] }, length_ms: 1, model: "m")
    end
    assert_raises(WalkthroughElevenlabs::RequestError) do
      WalkthroughElevenlabs.music_request(composition_plan: ok.merge("seed" => 1), length_ms: 1, model: "m")
    end
  end

  def test_music_writes_cache
    out = WalkthroughElevenlabs.music(prompt: "calm", length_ms: 30_000, model: "music_v1", cache_root: @dir,
                                      transport: ->(*) { Resp.new("200", "MUSIC") })
    assert_equal "MUSIC", File.binread(out[:path])
    assert_includes out[:path], "/music/"
  end

  def test_named_errors_and_scrubbed_key
    { 401 => WalkthroughElevenlabs::AuthError, 402 => WalkthroughElevenlabs::QuotaError,
      422 => WalkthroughElevenlabs::RequestError }.each do |code, klass|
      body = JSON.generate("detail" => { "message" => "bad key #{KEY}" })
      err = assert_raises(klass) do
        WalkthroughElevenlabs.perform(WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                      transport: ->(*) { Resp.new(code.to_s, body) }, sleeper: ->(_) { })
      end
      refute_includes err.message, KEY
      assert_includes err.message, "[REDACTED]"
    end
  end

  def test_transport_exception_scrubbed
    err = assert_raises(WalkthroughElevenlabs::RequestError) do
      WalkthroughElevenlabs.perform(WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { raise IOError, "boom #{KEY}" }, sleeper: ->(_) { })
    end
    refute_includes err.message, KEY
  end

  def test_429_backoff_then_success
    sleeps = []
    seq = [ Resp.new("429", "{}", { "retry-after" => "1.5" }), Resp.new("429", "{}"), Resp.new("200", "OK") ]
    body = WalkthroughElevenlabs.perform(WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                         transport: ->(*) { seq.shift }, sleeper: ->(s) { sleeps << s })
    assert_equal "OK", body
    assert_equal [ 1.5, 4 ], sleeps
  end

  def test_429_gives_up_after_three_retries
    sleeps = []
    assert_raises(WalkthroughElevenlabs::RateLimitError) do
      WalkthroughElevenlabs.perform(WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { Resp.new("429", "{}") }, sleeper: ->(s) { sleeps << s })
    end
    assert_equal 3, sleeps.length
  end

  def test_missing_key_raises_named_error
    ENV.delete("ELEVEN_LABS_API_KEY")
    assert_raises(WalkthroughEnv::MissingKeyError) do
      WalkthroughElevenlabs.perform(WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { flunk }, sleeper: ->(_) { })
    end
  end

  def test_format_hint_on_422
    err = assert_raises(WalkthroughElevenlabs::RequestError) do
      WalkthroughElevenlabs.perform(WalkthroughElevenlabs.music_request(prompt: "p", length_ms: 5000, model: "m"),
                                    transport: ->(*) { Resp.new("422", '{"detail":"output_format not allowed"}') },
                                    sleeper: ->(_) { })
    end
    assert_includes err.message, "higher plan"
  end

  def test_estimate
    e = WalkthroughElevenlabs.estimate(chars: 2000, music_ms: 120_000, model: "eleven_multilingual_v2")
    assert_in_delta 0.16, e[:tts_usd]
    assert_in_delta 0.30, e[:music_usd]
    assert_in_delta 0.46, e[:total_usd]
    assert_in_delta 0.08, WalkthroughElevenlabs.estimate(chars: 2000, music_ms: 0, model: "eleven_flash_v2_5")[:tts_usd]
    assert_includes WalkthroughElevenlabs.format_estimate(e), "$0.46"
  end
end
