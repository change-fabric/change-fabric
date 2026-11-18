# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast_audio"
require_relative "roast_audio_helpers"
require_relative "imagegen_helpers"
require_relative "enroll_helpers"

class RoastAudioBatchTest < Minitest::Test
  include RoastAudioHelpers
  include EnrollHelpers

  def setup
    @tmp = Dir.mktmpdir("roast-audio-batch")
    @out = File.join(@tmp, "roast-audio")
    @brief = File.join(FIXTURES, "brief.txt")
    @terms = File.join(@tmp, "terms.txt")
    File.write(@terms, "")
    @env = ENV.fetch("CF_SENSITIVE_TERMS_FILE", nil)
    ENV["CF_SENSITIVE_TERMS_FILE"] = @terms
  end

  def teardown
    ENV["CF_SENSITIVE_TERMS_FILE"] = @env
    FileUtils.rm_rf(@tmp)
  end

  def run_cli(*args, docker: FakeDocker.new(tags: { "intro.mp3" => "continuous", "outro.mp3" => "continuous" }))
    out = StringIO.new
    code = RoastAudio::Cli.run([ *args, "--brief", @brief, "--out-dir", @out, "--stop-after", "gate" ], out: out, docker: docker)
    [ code, out.string ]
  end

  def batch = JSON.parse(File.read(File.join(@out, "batch.json")))

  def test_two_clips_named_alike_in_different_folders_get_distinct_ids
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    b = stage_clip(File.join(@tmp, "b"), "continuous", as: "intro")
    code, out = run_cli("--audio", a, "--audio", b)
    assert_equal 0, code, out
    ids = batch["clips"].map { |c| c["source_id"] }
    assert_equal 2, ids.uniq.size
    ids.each { |id| assert_match(/\Asrc-\h{8}\z/, id) && assert(File.file?(File.join(@out, id, "gate.json"))) }
    assert_equal ids, [ a, b ].map { |p| RoastAudioBatch.source_id(p) }
  end

  def test_the_batch_index_binds_inputs_and_the_current_take
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    run_cli("--audio", a)
    clip = batch["clips"].first
    assert_equal a, clip["source_audio"]
    assert_equal clip["source_sha256"], clip["current"]["audio_sha256"]
    assert_equal a, clip["current"]["audio"]
    assert_equal a.sub(".mp3", ".vtt"), clip["vtt"]
    assert_equal 1, clip["attempts"]
    assert_equal 4, clip["max_attempts"]
    assert_equal({ "path" => @brief, "sha256" => Digest::SHA256.file(@brief).hexdigest }, batch["brief"])
    assert_match(/\A\h{64}\z/, batch["config_hash"])
  end

  def test_a_flag_that_disagrees_with_the_sibling_exits_2
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    other = File.join(@tmp, "other.vtt")
    File.write(other, "WEBVTT\n\n00:00.250 --> 00:05.750\nsomething else\n")
    code, out = run_cli("--audio", a, "--vtt", other)
    assert_equal 2, code
    assert_match(/disagrees with the sibling/, out)
  end

  def test_a_missing_vtt_or_a_count_mismatch_exits_2
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    File.delete(a.sub(".mp3", ".vtt"))
    code, out = run_cli("--audio", a)
    assert_equal 2, code
    assert_match(/no captions for/, out)
    b = stage_clip(File.join(@tmp, "b"), "continuous", as: "intro")
    code, out = run_cli("--audio", a, "--audio", b, "--vtt", b.sub(".mp3", ".vtt"))
    assert_equal 2, code
    assert_match(/1 --vtt for 2 --audio/, out)
  end

  def test_rerunning_the_same_selection_resumes_and_counts_no_attempt
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    run_cli("--audio", a)
    code, out = run_cli("--audio", a)
    assert_equal 0, code
    assert_match(/unchanged, no attempt counted/, out)
    assert_equal 1, batch["clips"].first["attempts"]
  end

  def test_a_changed_vtt_moves_the_gate_record_to_stale_and_counts_an_attempt
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    run_cli("--audio", a)
    id = batch["clips"].first["source_id"]
    File.write(a.sub(".mp3", ".vtt"), "WEBVTT\n\n00:00.250 --> 00:05.750\none cue now\n")
    code, out = run_cli("--audio", a)
    assert_equal 0, code, out
    assert File.file?(File.join(@out, id, "stale", "1", "gate.json"))
    assert_equal 2, batch["clips"].first["attempts"]
    assert_equal 2, JSON.parse(File.read(File.join(@out, id, "gate.json")))["attempt"]
  end

  def test_dropping_no_fix_or_adding_an_alignment_regates
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    run_cli("--audio", a, "--no-fix")
    code, out = run_cli("--audio", a)
    assert_equal 0, code, out
    refute_match(/unchanged/, out)
    assert_equal 2, batch["clips"].first["attempts"]
    File.write(a.sub(".mp3", ".alignment.json"), JSON.generate({ "alignment" => {} }))
    _, out = run_cli("--audio", a)
    refute_match(/unchanged/, out)
    assert_equal 3, batch["clips"].first["attempts"]
  end

  def test_estimate_only_runs_nothing_and_writes_nothing
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    docker = FakeDocker.new
    code, out = run_cli("--audio", a, "--estimate-only", docker: docker)
    assert_equal 0, code
    assert_match(/up to \$0\.0000 to spend; nothing was run/, out)
    assert_empty docker.calls
    refute File.exist?(@out)
  end

  def test_a_deleted_or_edited_repair_output_regates
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    run_cli("--audio", a)
    gate = JSON.parse(File.read(File.join(@out, batch["clips"].first["source_id"], "gate.json")))
    File.delete(gate["output"]["audio"])
    _, out = run_cli("--audio", a)
    refute_match(/unchanged/, out)
    assert_equal 2, batch["clips"].first["attempts"]
    File.write(gate["output"]["vtt"].sub(".a1.", ".a2."), "edited")
    _, out = run_cli("--audio", a)
    refute_match(/unchanged/, out)
  end

  def test_a_changed_selection_exits_2_unless_new_batch
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    b = stage_clip(File.join(@tmp, "b"), "continuous", as: "outro")
    run_cli("--audio", a)
    code, out = run_cli("--audio", a, "--audio", b)
    assert_equal 2, code
    assert_match(/adds src-/, out)
    code, = run_cli("--audio", a, "--audio", b, "--new-batch")
    assert_equal 0, code
    assert_equal 2, batch["clips"].size
  end

  def test_a_take_path_given_as_audio_exits_2
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    run_cli("--audio", a)
    id = batch["clips"].first["source_id"]
    take = File.join(@out, id, "fixed", "#{id}.a1.mp3")
    FileUtils.cp(File.join(FIXTURES, "continuous.vtt"), take.sub(".mp3", ".vtt"))
    code, out = run_cli("--audio", take)
    assert_equal 2, code
    assert_match(/is a roast take; name its source clip instead/, out)
  end

  def test_a_sensitive_caption_term_is_refused_unless_allowed
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    File.write(@terms, "tone\n")
    code, out = run_cli("--audio", a)
    assert_equal 1, code
    assert_match(/sensitive term/, out)
    code, = run_cli("--audio", a, "--allow-sensitive")
    assert_equal 0, code
  end

  def test_unsupported_gate_flags_exit_2_before_any_work
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    docker = FakeDocker.new
    code, out = run_cli("--audio", a, "--pad-min", "0.6", docker: docker)
    assert_equal 2, code
    assert_match(/--pad-min must not exceed --pad-max/, out)
    assert_empty docker.calls
  end

  def test_docker_down_exits_1_by_name
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    code, out = run_cli("--audio", a, docker: FakeDocker.new(down: true))
    assert_equal 1, code
    assert_match(/is Docker running/, out)
  end

  def test_a_terminal_failure_marks_the_clip_blocked
    a = stage_clip(File.join(@tmp, "a"), "noise_bed", as: "intro")
    code, out = run_cli("--audio", a, docker: FakeDocker.new(tags: { "intro.mp3" => "noise_bed" }))
    assert_equal 0, code
    assert_match(/failing noise terminal/, out)
    assert_equal "blocked", batch["clips"].first["state"]
  end

  def test_roast_rb_dispatches_audio
    require_relative "../scripts/roast"
    out = StringIO.new
    assert_equal 2, Roast::Cli.run([ "--audio", "x.mp3" ], out: out)
    assert_match(/--brief is required/, out.string)
  end

  # ---- states and decide ------------------------------------------------------

  class Judge < ImagegenHelpers::FakeHttp
    def initialize(score:, issues: []) = super("200").tap { @critic = { "score" => score, "summary" => "s", "issues" => issues } }

    def request(req)
      @requests << req
      body = { "choices" => [ { "message" => { "content" => JSON.generate(@critic) } } ],
               "usage" => { "prompt_tokens" => 600, "prompt_tokens_details" => { "audio_tokens" => 60 }, "completion_tokens" => 100 } }
      ImagegenHelpers::FakeResponse.new("200", JSON.generate(body))
    end
  end

  def judged(*audios, http:, **)
    out = StringIO.new
    args = audios.flat_map { |a| [ "--audio", a ] } + [ "--brief", @brief, "--out-dir", @out ]
    code = with_enrolled("openai") { RoastAudio::Cli.run(args, out: out, http: http, docker: FakeDocker.new(tags: { "intro.mp3" => "continuous", "outro.mp3" => "continuous" })) }
    [ code, out.string ]
  end

  def decide(*extra)
    out = StringIO.new
    RoastAudio::Cli.run([ "decide", "--audio-batch", @out, *extra ], out: out)
    out.string
  end

  def bound_clip(dir, as) = stage_clip(File.join(@tmp, dir), "continuous", as: as).tap { |a| bound_sidecar(a) }

  def test_a_clip_meeting_the_bar_is_ready_and_decide_stops
    a = bound_clip("a", "intro")
    code, out = judged(a, http: Judge.new(score: 9, issues: [ { "priority" => "P2", "cue" => 1, "area" => "pacing", "problem" => "p", "fix" => "f", "revoice" => false } ]))
    assert_equal 0, code, out
    assert_match(/1 ready/, out)
    d = decide
    assert_match(/\Aready: src-\h{8}$/, d)
    assert_match(/roast decision: stop: all 1 clip\(s\) ready/, d)
    rows = JSON.parse(File.read(File.join(@out, "summary.json")))["clips"]
    assert_equal [ "ready", "pass", "0/0", "verified", 9, 0 ], rows.first.values_at("state", "gate", "words", "timing", "score", "p0_p1")
    assert_includes File.read(File.join(@out, "summary.md")), "| ready |"
  end

  def test_score_or_a_p1_short_of_the_bar_is_blocked_not_ready
    a = bound_clip("a", "intro")
    judged(a, http: Judge.new(score: 8))
    assert_match(/blocked: src-\h{8} \(score 8 under 9/, decide)
    FileUtils.rm_rf(@out)
    judged(a, http: Judge.new(score: 9, issues: [ { "priority" => "P1", "cue" => 2, "area" => "artifact", "problem" => "p", "fix" => "f", "revoice" => true } ]))
    assert_match(/1 P0\/P1/, decide)
    assert_match(/roast decision: stop: no clip is retryable/, decide)
  end

  def test_mixed_attempts_continue_and_the_exhausted_clip_is_skipped
    a = bound_clip("a", "intro")
    b = bound_clip("b", "outro")
    judged(a, b, http: Judge.new(score: 6))
    batch = JSON.parse(File.read(File.join(@out, "batch.json")))
    batch["clips"][0]["attempts"] = 4
    File.write(a.sub(".mp3", ".vtt"), File.read(a.sub(".mp3", ".vtt")).sub("no pause", "a pause")) # clip a goes stale too
    File.write(b.sub(".mp3", ".vtt"), File.read(b.sub(".mp3", ".vtt")).sub("no pause", "a pause"))
    File.write(File.join(@out, "batch.json"), JSON.generate(batch))
    d = decide
    assert_match(/^retryable: #{batch['clips'][1]['source_id']}$/, d)
    assert_match(/^exhausted: #{batch['clips'][0]['source_id']}$/, d)
    assert_match(/roast decision: continue: 1 clip\(s\) retryable/, d)
    http = Judge.new(score: 6)
    _, out = judged(a, b, http: http)
    assert_match(/#{batch['clips'][0]['source_id']} \(intro\.mp3\): skipped, exhausted/, out)
    assert_equal 4, JSON.parse(File.read(File.join(@out, "batch.json")))["clips"][0]["attempts"]
    assert_equal 1, http.requests.size
  end

  def test_all_exhausted_or_blocked_stops
    a = bound_clip("a", "intro")
    judged(a, http: Judge.new(score: 3))
    assert_match(/stop: no clip is retryable/, decide)
    assert_match(/exhausted: src-/, decide("--max-attempts", "1"))
  end

  def test_a_repeated_terminal_gate_failure_is_blocked_and_costs_no_attempt
    a = stage_clip(File.join(@tmp, "a"), "noise_bed", as: "intro")
    docker = FakeDocker.new(tags: { "intro.mp3" => "noise_bed" })
    2.times { RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--out-dir", @out, "--stop-after", "gate" ], out: StringIO.new, docker: docker) }
    assert_equal 1, batch["clips"].first["attempts"]
    assert_match(/blocked: src-\h{8} \(gate terminal: noise\)/, decide)
  end

  def test_a_changed_vtt_makes_a_judged_clip_retryable_again
    a = bound_clip("a", "intro")
    judged(a, http: Judge.new(score: 6))
    File.write(a.sub(".mp3", ".vtt"), File.read(a.sub(".mp3", ".vtt")).sub("no pause", "a pause"))
    assert_match(/^retryable: src-/, decide)
    assert Dir.glob(File.join(@out, "src-*", "stale", "*", "gate.json")).any?
  end

  def test_an_unreadable_ledger_stops
    a = bound_clip("a", "intro")
    RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--out-dir", @out, "--stop-after", "gate" ], out: StringIO.new,
                                                                                                      docker: FakeDocker.new(tags: { "intro.mp3" => "continuous" }))
    File.write(File.join(@out, "spend.json"), "{broken")
    assert_match(/roast decision: stop: the run ledger cannot authorize spend/, decide)
  end

  def test_a_sensitive_term_only_in_the_brief_is_refused
    a = bound_clip("a", "intro")
    File.write(@terms, "buyer\n")
    code, out = judged(a, http: Judge.new(score: 9))
    assert_equal 1, code
    assert_match(/sensitive term\(s\) matched in the brief/, out)
  end

  def test_a_cached_guard_failure_still_exits_1
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    long = ->(t) { t.gsub(/"duration": "[\d.]+"/, '"duration": "9999.000000"') }
    docker = FakeDocker.new(tags: { "intro.mp3" => "continuous" }, edits: { "continuous.probe.json" => long })
    codes = Array.new(2) { RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--out-dir", @out, "--stop-after", "gate" ], out: StringIO.new, docker: docker) }
    assert_equal [ 1, 1 ], codes
  end

  def test_decide_stops_when_the_budget_left_cannot_fund_the_next_call
    a = bound_clip("a", "intro")
    RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--out-dir", @out, "--stop-after", "words", "--run-max-usd", "0.01" ], out: StringIO.new,
                                                                                                                              docker: FakeDocker.new(tags: { "intro.mp3" => "continuous" }))
    d = decide
    assert_match(/^retryable: src-/, d)
    assert_match(/roast decision: stop: the \$0\.0100 left of the run cap .* cannot fund/, d)
    FileUtils.rm_rf(@out)
    RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--out-dir", @out, "--stop-after", "words" ], out: StringIO.new,
                                                                                                      docker: FakeDocker.new(tags: { "intro.mp3" => "continuous" }))
    assert_match(/roast decision: continue: 1 clip\(s\) retryable/, decide)
  end
end
