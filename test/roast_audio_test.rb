# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast_audio"
require_relative "roast_audio_helpers"
require_relative "imagegen_helpers"
require_relative "enroll_helpers"

class RoastAudioTest < Minitest::Test
  include RoastAudioHelpers
  include EnrollHelpers

  # fixtures/roast_audio/chat_reply.json: the live gpt-audio-1.5 reply to the
  # phase 3 judge run on continuous.mp3, critic and usage as returned.
  REPLY = JSON.parse(File.read(File.join(RoastAudioHelpers::FIXTURES, "chat_reply.json")))

  class Http < ImagegenHelpers::FakeHttp
    def initialize(body = REPLY) = super("200").tap { @body = body }

    def request(req)
      @requests << req
      ImagegenHelpers::FakeResponse.new("200", JSON.generate(@body))
    end
  end

  def setup
    @tmp = Dir.mktmpdir("roast-audio")
    @out = File.join(@tmp, "ra")
    @brief = File.join(@tmp, "brief.txt")
    FileUtils.cp(File.join(FIXTURES, "brief.txt"), @brief)
    @cues = RoastVtt.parse_file(File.join(FIXTURES, "continuous.vtt"))
    @words = { "source" => "alignment", "counts" => { "accepted" => 0 }, "timing" => "verified" }
    enroll_home!("openai")
  end

  def teardown
    restore_home!
    FileUtils.rm_rf(@tmp)
  end

  def request(**over) = RoastAudio.build_request(audio: File.join(FIXTURES, "continuous.mp3"), brief: "b", cues: @cues, words: @words, history: [], **over)

  def test_the_request_is_chat_completions_with_one_base64_mp3_part
    r = request
    assert_equal "https://api.openai.com/v1/chat/completions", r[:url]
    body = r[:body]
    assert_equal [ "gpt-audio-1.5", [ "text" ], 4000 ], body.values_at(:model, :modalities, :max_completion_tokens)
    parts = body[:messages].last[:content]
    audio = parts.find { |p| p[:type] == "input_audio" }[:input_audio]
    assert_equal "mp3", audio[:format]
    assert_equal File.binread(File.join(FIXTURES, "continuous.mp3")), Base64.strict_decode64(audio[:data])
    assert_includes parts.first[:text], "2. [0:02.0] The second cue continues with no pause."
    refute body.key?(:response_format), "gpt-audio-1.5 rejects json_schema; the shape is in the prompt"
    assert_includes body[:messages].first[:content], "JSON Schema"
  end

  def test_the_reservation_is_twice_the_measured_rate_plus_prompt_bytes_plus_max_output
    r = request
    b = RoastAudio.judge_bound(r, 6.0)
    audio = (6.0 * 2 * RoastAudioLedger::MEASURED_AUDIO_TOKENS_PER_SECOND).ceil
    text = r[:prompt_bytes] + RoastAudioLedger::MESSAGE_OVERHEAD_TOKENS
    assert_equal [ audio, text, 4000 ], b[:basis].values_at(:audio_tokens, :text_tokens, :output_tokens)
    assert_in_delta ((audio * 32.0) + (text * 2.5) + (4000 * 10.0)) / 1e6, b[:usd], 1e-6
  end

  def test_no_calibrated_rate_raises_unbounded_cost
    RoastAudioLedger.singleton_class.alias_method(:calibrated_rate, :measured_rate)
    RoastAudioLedger.define_singleton_method(:measured_rate) { nil }
    assert_raises(RoastAudioLedger::UnboundedCost) { RoastAudio.judge_bound(request, 6.0) }
  ensure
    RoastAudioLedger.singleton_class.alias_method(:measured_rate, :calibrated_rate)
  end

  def test_both_parse_paths_and_cue_stamps
    critic = RoastAudio.parse_critic(REPLY, cues: @cues)
    assert_equal 4, critic["score"]
    assert_equal [ "cue 1 at 0:00.3", "cue 2 at 0:02.0" ], critic["issues"].map { |i| i["where"] }.uniq.first(2)
    prose = REPLY.merge("choices" => [ { "message" => { "content" => "Here you go:\n```json\n#{REPLY.dig('choices', 0, 'message', 'content')}\n```" } } ])
    assert_equal critic, RoastAudio.parse_critic(prose, cues: @cues)
  end

  def test_an_invalid_reply_fails_by_name
    bad = ->(issue) { REPLY.merge("choices" => [ { "message" => { "content" => JSON.generate("score" => 5, "summary" => "s", "issues" => [ issue ]) } } ]) }
    ok = { "priority" => "P1", "cue" => 1, "area" => "pacing", "problem" => "p", "fix" => "f", "revoice" => true }
    { "cue" => 9, "area" => "loudness", "revoice" => "yes", "priority" => "P4" }.each do |k, v|
      err = assert_raises(Roast::RequestError) { RoastAudio.parse_critic(bad.call(ok.merge(k => v)), cues: @cues) }
      assert_match(/audio judge issue 1/, err.message)
    end
    assert_raises(Roast::RequestError) { RoastAudio.parse_critic({ "choices" => [ { "message" => { "content" => "no json" } } ] }, cues: @cues) }
    refusal = { "choices" => [ { "message" => { "content" => nil, "refusal" => "cannot" } } ] }
    assert_match(/refused/, assert_raises(Roast::RequestError) { RoastAudio.parse_critic(refusal, cues: @cues) }.message)
  end

  def run_cli(*args, http: Http.new, audio: nil)
    audio ||= stage_clip(File.join(@tmp, "a"), "continuous", as: "intro").tap { |a| bound_sidecar(a) }
    out = StringIO.new
    code = RoastAudio::Cli.run([ "--audio", audio, "--brief", @brief, "--out-dir", @out, *args ], out: out, http: http,
                                                                                                 docker: FakeDocker.new(tags: { "intro.mp3" => "continuous" }))
    [ code, out.string, audio ]
  end

  def test_a_judged_run_writes_the_round_and_settles_the_ledger
    http = Http.new
    code, out, = run_cli(http: http)
    assert_equal 0, code, out
    assert_match(/judge src-\h{8}: round 1 score 4, 3 P0\/P1/, out)
    entry = JSON.parse(File.read(File.join(@out, "spend.json")))["entries"].last
    assert_equal [ "judge", "settled" ], entry.values_at("op", "status")
    assert_in_delta 0.006193, entry["actual_usd"], 1e-6
    assert_equal 1, http.requests.size
    code, out, = run_cli(http: http)
    assert_equal 0, code
    assert_match(/skipped, blocked/, out)
    assert_equal 1, http.requests.size, "an unchanged clip is not judged again"
  end

  def test_an_invalid_reply_is_logged_raw_and_exits_1
    junk = REPLY.merge("choices" => [ { "message" => { "content" => "{\"score\": 42}" } } ])
    code, out, = run_cli(http: Http.new(junk))
    assert_equal 1, code
    assert_match(/raw reply in .*raw\/round-1\.json/, out)
    assert Dir.glob(File.join(@out, "src-*", "raw", "round-1.json")).any?
  end

  def test_refused_over_the_per_call_or_run_cap_before_any_request
    http = Http.new
    code, out, = run_cli("--max-usd", "0.01", http: http)
    assert_equal 1, code
    assert_match(/per-call ceiling/, out)
    FileUtils.rm_rf(@out)
    code, out, = run_cli("--run-max-usd", "0.01", http: http)
    assert_equal 1, code
    assert_match(/run cap/, out)
    assert_empty http.requests
  end

  def test_an_unpriced_model_is_refused
    http = Http.new
    code, out, = run_cli("--model", "gpt-audio-9", http: http)
    assert_equal 1, code
    assert_match(/no price for gpt-audio-9/, out)
    assert_empty http.requests
  end

  def test_a_changed_brief_makes_only_the_judge_stale
    run_cli
    File.write(@brief, "#{File.read(@brief)}Audience changed.\n")
    batch = RoastAudioBatch.load(@out)
    rec = RoastAudioBatch.revalidate(@out, batch, batch["clips"].first)
    assert rec[:gate]
    assert rec[:words]
    assert_nil rec[:judge]
    assert Dir.glob(File.join(@out, "src-*", "stale", "*", "round-1.json")).any?
  end

  def test_estimate_only_prints_the_judge_bound_and_sends_nothing
    http = Http.new
    run_cli("--stop-after", "words", http: http)
    code, out, = run_cli("--estimate-only", http: http)
    assert_equal 0, code
    assert_match(/judge \$0\.04\d\d/, out)
    assert_empty http.requests
  end
end
