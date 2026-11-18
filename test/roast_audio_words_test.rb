# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast_audio"
require_relative "roast_audio_helpers"
require_relative "imagegen_helpers"
require_relative "enroll_helpers"

class RoastAudioWordsTest < Minitest::Test
  include RoastAudioHelpers
  include EnrollHelpers

  # Records each transcription request and answers with the documented reply shape ({ "text": ... }).
  class Http < ImagegenHelpers::FakeHttp
    def initialize(text) = super("200").tap { @text = text }

    def request(req)
      @requests << req
      ImagegenHelpers::FakeResponse.new("200", JSON.generate({ "text" => @text }))
    end
  end

  def setup
    @tmp = Dir.mktmpdir("roast-audio-words")
    @audio = File.join(FIXTURES, "continuous.mp3")
    @sha = Digest::SHA256.file(@audio).hexdigest
    @ledger = RoastAudioLedger.new(@tmp, cap_usd: 1.0, max_usd: 0.5)
    enroll_home!("openai")
  end

  def teardown
    restore_home!
    FileUtils.rm_rf(@tmp)
  end

  def sidecar(spans, audio_sha: @sha) = write_sidecar(File.join(@tmp, "continuous.alignment.json"), spans, audio_sha)

  def gate(vtt: File.join(FIXTURES, "continuous.vtt"), status: "pass")
    { "status" => status, "deps" => { "audio_sha256" => @sha, "vtt_sha256" => Digest::SHA256.file(vtt).hexdigest, "config_hash" => "c", "fix" => true, "alignment_sha256" => nil },
      "derived_from" => { "source_sha256" => @sha, "trim_delta_ms" => 0 },
      "output" => { "audio" => @audio, "audio_sha256" => @sha, "vtt" => vtt }, "measurements" => { "source" => { "duration_s" => 6.0 } } }
  end

  def check(alignment_path: nil, http: nil, response: nil, g: gate, brief: "")
    RoastAudioWords.check(gate: g, alignment: RoastAudioWords.provenance(alignment_path, audio_sha256: @sha), clip_dir: @tmp, id: "src-0000abcd",
                          ledger: @ledger, response_file: response, brief: brief, http: http)
  end

  def test_bound_alignment_matching_the_captions_has_no_ops_and_verified_timing
    w = check(alignment_path: sidecar(exact_spans))
    assert_equal "alignment", w["source"]
    assert_equal "verified", w["timing"]
    assert_equal [], w["ops"]
    refute File.exist?(File.join(@tmp, "spend.json")), "the alignment path is free"
  end

  def test_cue_timing_is_checked_to_250_ms_after_the_trim_delta
    spans = exact_spans
    spans[1] = [ spans[1][0], 2200, 4000 ]
    assert_empty check(alignment_path: sidecar(spans))["ops"], "200 ms is inside the tolerance"
    spans[1] = [ spans[1][0], 2400, 4000 ]
    ops = check(alignment_path: sidecar(spans))["ops"]
    assert_equal [ [ "cue_timing", 2, "0:02.0" ] ], ops.map { |o| o.values_at("kind", "cue", "at") }
    g = gate.merge("derived_from" => { "trim_delta_ms" => -400 })
    assert_includes check(alignment_path: sidecar(spans), g: g)["ops"].map { |o| o["cue"] }, 1, "a 400 ms trim moves cue 1's first word out of tolerance"
  end

  def test_mismatched_and_unbound_alignment_fall_back_to_transcription
    http = Http.new(CUE_TEXT.join(" "))
    w = check(alignment_path: sidecar(exact_spans, audio_sha: "0" * 64), http: http)
    assert_equal [ "transcribe", "unverified", "mismatch" ], w.values_at("source", "timing", "alignment")
    bare = File.join(@tmp, "bare.json")
    File.write(bare, JSON.generate(alignment(exact_spans)))
    assert_equal "unbound", check(alignment_path: bare, http: http)["alignment"]
    assert_equal 1, http.requests.size, "the second clip read the cached reply"
  end

  def test_transcription_posts_the_gated_clip_with_no_prompt_through_the_ledger
    http = Http.new(CUE_TEXT.join(" "))
    w = check(http: http)
    req = http.requests.first
    fields = req.instance_variable_get(:@body_data).to_h { |name, value, *| [ name, value ] }
    assert_equal "/v1/audio/transcriptions", req.path
    assert_equal %w[model response_format file], fields.keys
    assert_equal [ "gpt-transcribe", "json" ], fields.values_at("model", "response_format")
    assert_equal 0, w["counts"]["raw"]
    entry = JSON.parse(File.read(File.join(@tmp, "spend.json")))["entries"].first
    assert_equal [ "transcribe", "settled", 0.0045 ], entry.values_at("op", "status", "actual_usd")
    assert File.file?(RoastAudioWords.cache_path(@tmp, @sha, "gpt-transcribe"))
  end

  def test_a_failing_gate_never_reaches_transcription
    http = Http.new("x")
    assert_raises(RoastAudioWords::WordsError) { check(http: http, g: gate(status: "fail")) }
    assert_empty http.requests
  end

  def test_diff_ops_map_to_cues_with_stable_ids
    heard = "The first cue sits inside the tone. The second queue continues with pause. The third cue ends where the tone ends right now."
    ops = check(http: Http.new(heard))["ops"]
    assert_equal [ [ "substituted", 2, "cue", "queue" ], [ "missing", 2, "no", nil ], [ "extra", 3, nil, "right" ], [ "extra", 3, nil, "now" ] ],
                 ops.map { |o| o.values_at("kind", "cue", "expected", "heard") }
    again = check(http: Http.new("ignored, cached"))["ops"]
    assert_equal ops.map { |o| o["id"] }, again.map { |o| o["id"] }
    assert ops.all? { |o| o["id"].match?(/\A\h{12}\z/) }
  end

  def test_numbers_quotes_and_hyphens_normalize_alike
    assert_equal RoastAudioWords.tokens("Twenty-one 'items', 1,200 left"), RoastAudioWords.tokens("twenty one items one thousand two hundred left")
  end

  def response(rebuttals, inputs: { "audio_sha256" => @sha, "vtt_sha256" => gate["deps"]["vtt_sha256"] })
    path = File.join(@tmp, "words.response.json")
    File.write(path, JSON.generate({ "source_id" => "src-0000abcd", "inputs" => inputs, "rebuttals" => rebuttals }))
    path
  end

  def with_ops(heard)
    ops = check(http: Http.new(heard))["ops"]
    FileUtils.rm_rf(File.join(@tmp, "cache"))
    ops
  end

  def test_a_valid_rebuttal_reduces_accepted_and_bad_ones_are_ignored
    heard = CUE_TEXT.join(" ").sub("sits", "sitz").sub("no pause", "pause")
    ops = with_ops(heard)
    sub = ops.find { |o| o["kind"] == "substituted" }
    miss = ops.find { |o| o["kind"] == "missing" }
    good = { "op_id" => sub["id"], "reason" => "proper_noun", "evidence" => "sits is spelled in the brief" }
    w = check(http: Http.new(heard), response: response([ good ]), brief: "Product term: sits\n")
    assert_equal({ "raw" => 2, "rebutted" => 1, "accepted" => 1 }, w["counts"])
    FileUtils.rm_rf(File.join(@tmp, "cache"))
    bad = [ good.merge("reason" => "accent"), { "op_id" => miss["id"], "reason" => "proper_noun", "evidence" => "no" }, good.merge("evidence" => "nothing") ]
    w = check(http: Http.new(heard), response: response(bad), brief: "Product term: sits\n")
    assert_equal 2, w["counts"]["accepted"]
    assert_equal 3, w["warnings"].size
    FileUtils.rm_rf(File.join(@tmp, "cache"))
    stale = check(http: Http.new(heard), response: response([ good ], inputs: { "audio_sha256" => "x", "vtt_sha256" => "y" }), brief: "Product term: sits\n")
    assert_equal 2, stale["counts"]["accepted"]
    assert_match(/not the current audio/, stale["warnings"].first)
  end

  def test_number_and_homophone_evidence_is_checked
    heard = CUE_TEXT.join(" ").sub("where", "wear")
    sub = with_ops(heard).find { |o| o["kind"] == "substituted" }
    no = check(http: Http.new(heard), response: response([ { "op_id" => sub["id"], "reason" => "homophone", "evidence" => "where/wear" } ]))
    assert_match(/not a known homophone pair/, no["warnings"].first)
    op = { "id" => "x", "kind" => "substituted", "expected" => "too", "heard" => "two" }
    assert_nil RoastAudioWords.send(:evidence_problem, "homophone", "too/two", op, "", {})
    num = { "kind" => "substituted", "expected" => "twelve", "heard" => "dozen" }
    assert_match(/normalize equal/, RoastAudioWords.send(:evidence_problem, "number_format", "12 = a dozen", num, "", {}))
    assert_match(/both the expected and the heard/, RoastAudioWords.send(:evidence_problem, "number_format", "12 = twelve", num, "", {}))
    real = { "kind" => "substituted", "expected" => "twelve", "heard" => "ninety" }
    assert_match(/both the expected and the heard/, RoastAudioWords.send(:evidence_problem, "number_format", "12 = twelve", real, "", {}))
    same = { "kind" => "substituted", "expected" => "hundred", "heard" => "one" }
    assert_nil RoastAudioWords.send(:evidence_problem, "number_format", "100 = one hundred", same, "", {})
  end

  def test_a_rebuttal_added_later_changes_rebuttal_sha_and_counts
    heard = CUE_TEXT.join(" ").sub("sits", "sitz")
    first = check(http: Http.new(heard))
    sub = first["ops"].first
    later = check(http: Http.new("cached"), response: response([ { "op_id" => sub["id"], "reason" => "proper_noun", "evidence" => "sits" } ]), brief: "sits\n")
    refute_equal first["deps"]["rebuttal_sha256"], later["deps"]["rebuttal_sha256"]
    assert_equal [ 1, 0 ], [ first["counts"]["accepted"], later["counts"]["accepted"] ]
  end

  def run_cli(*args, http:)
    out = StringIO.new
    dir = File.join(@tmp, "a")
    audio = File.join(dir, "intro.mp3")
    stage_clip(dir, "continuous", as: "intro") unless File.file?(audio)
    code = RoastAudio::Cli.run([ "--audio", audio, "--brief", File.join(FIXTURES, "brief.txt"), "--out-dir", File.join(@tmp, "ra"), *args ],
                               out: out, http: http, docker: FakeDocker.new(tags: { "intro.mp3" => "continuous" }))
    [ code, out.string, audio ]
  end

  def test_a_vtt_change_reuses_the_cached_transcript_with_no_new_paid_call
    http = Http.new(CUE_TEXT.join(" "))
    code, out, audio = run_cli("--stop-after", "words", http: http)
    assert_equal 0, code, out
    assert_match(/0 raw, 0 accepted; source transcribe, timing unverified/, out)
    File.write(audio.sub(".mp3", ".vtt"), File.read(File.join(FIXTURES, "continuous.vtt")).sub("no pause", "a pause"))
    code, out, = run_cli("--stop-after", "words", http: http)
    assert_equal 0, code, out
    assert_match(/1 raw, 1 accepted/, out)
    assert_equal 1, http.requests.size
    assert_equal 1, JSON.parse(File.read(File.join(@tmp, "ra", "spend.json")))["entries"].size
  end

  def test_estimate_only_prints_the_bound_and_never_reaches_the_transport
    http = Http.new("x")
    run_cli("--stop-after", "gate", http: http)
    code, out, = run_cli("--stop-after", "words", "--estimate-only", http: http)
    assert_equal 0, code
    assert_match(/words \$0\.0045/, out)
    assert_empty http.requests
    refute File.exist?(File.join(@tmp, "ra", "spend.json"))
  end

  def test_a_missing_key_releases_the_reservation_and_asks_for_enrollment
    with_enrolled do
      code, out, = run_cli("--stop-after", "words", http: Http.new("x"))
      assert_equal 4, code, out
    end
    assert_equal "released", JSON.parse(File.read(File.join(@tmp, "ra", "spend.json")))["entries"].first["status"]
  end
end
