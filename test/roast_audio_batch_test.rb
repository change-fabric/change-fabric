# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "open3"
require "base64"
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

  def test_roast_rb_help_lists_the_audio_modes
    out = StringIO.new
    assert_equal 0, Roast::Cli.run([ "--help" ], out: out)
    %w[--audio --audio-regen --audio-batch --manifest --stop-after].each { |flag| assert_includes out.string, flag }
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
    assert_match(/blocked: src-\h{8} \(gate terminal: noise; regen report-only, not executable\)/, decide)
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

  # ---- manifest, regen proposals and approved re-voice ----------------------------

  P1_PROSODY = { "priority" => "P1", "cue" => 2, "area" => "prosody", "problem" => "flat, read not spoken", "fix" => "f", "revoice" => true }.freeze

  def flat_manifest(*names, voice: "voice-a", settings: nil)
    path = File.join(@tmp, "narration.manifest.json")
    clips = names.map { |n| { "file" => n, "text" => CUE_TEXT.join(" "), "voice_id" => voice, "settings" => settings }.compact }
    File.write(path, JSON.generate({ "clips" => clips }))
    path
  end

  # ElevenLabs with-timestamps reply: a real mp3 (changed by a suffix, so it is a new take) and a bound-able alignment.
  def tts_transport(calls)
    lambda do |request, _key|
      calls << request
      body = { "audio_base64" => Base64.strict_encode64(File.binread(File.join(FIXTURES, "continuous.mp3")) + "take#{calls.size}"),
               "alignment" => alignment(exact_spans) }
      ImagegenHelpers::FakeResponse.new("200", JSON.generate(body))
    end
  end

  def regen(*ids, calls: [])
    out = StringIO.new
    code = with_enrolled("elevenlabs") { RoastAudio::Cli.run([ "--audio-regen", @out, *ids.flat_map { |i| [ "--approve", i ] } ], out: out, transport: tts_transport(calls)) }
    [ code, out.string ]
  end

  def proposal(id) = JSON.parse(File.read(File.join(@out, id, "regen.json")))

  def judged_with_manifest(*audios, http:, manifest: flat_manifest(*audios.map { |a| File.basename(a) }), extra: [])
    out = StringIO.new
    args = audios.flat_map { |a| [ "--audio", a ] } + [ "--brief", @brief, "--out-dir", @out, "--manifest", manifest, *extra ]
    code = with_enrolled("openai") { RoastAudio::Cli.run(args, out: out, http: http, docker: FakeDocker.new(tags: { "intro.mp3" => "continuous", "outro.mp3" => "continuous" })) }
    [ code, out.string ]
  end

  def test_persistent_source_clipping_proposes_a_revoice_with_a_gate_reason
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    out = StringIO.new
    RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--out-dir", @out, "--manifest", flat_manifest("intro.mp3"), "--stop-after", "gate" ],
                        out: out, docker: FakeDocker.new(tags: { "intro.mp3" => "clipped" }))
    id = batch["clips"].first["source_id"]
    prop = proposal(id)
    assert_equal [ "revoice", true ], prop.values_at("action", "executable")
    assert_includes prop["reasons"].map { |r| [ r["source"], r["id"] ] }, [ "gate", "clipping" ]
    assert_equal "voice-a", prop["retake"]["voice_id"]
    assert_in_delta 0.08 * CUE_TEXT.join(" ").length / 1000.0, prop["estimate_usd"], 1e-4
  end

  def test_a_prosody_p1_with_revoice_proposes_a_retake_with_a_judge_reason
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY, P1_PROSODY.merge("area" => "pacing", "cue" => 3, "problem" => "rushed") ]))
    prop = proposal(batch["clips"].first["source_id"])
    assert_equal "revoice", prop["action"]
    assert_equal [ "judge" ], prop["reasons"].map { |r| r["source"] }.uniq
    assert_equal({ "speed" => "-0.05 (pacing at cue 3)" }, prop["retake"]["settings_delta"])
    assert_in_delta 0.95, prop["retake"]["settings"]["speed"]
    assert_match(/cue 2: P1 prosody: flat/, prop["retake"]["instruction"])
    assert_match(/blocked: src-\h{8} \(.*; regen proposed\)/, decide)
  end

  def test_an_artifact_raises_stability_capped_at_0_85
    settings, delta = RoastAudioBatch.settings_delta({ "stability" => 0.8, "speed" => 1.18 },
                                                     [ { "source" => "judge", "kind" => "revoice", "area" => "artifact", "cue" => 1, "detail" => "metallic" },
                                                       { "source" => "judge", "kind" => "revoice", "area" => "pacing", "cue" => 2, "detail" => "drags" } ])
    assert_equal [ 0.85, 1.2 ], settings.values_at("stability", "speed")
    assert_equal %w[stability speed], delta.keys
  end

  def test_a_clip_with_no_manifest_entry_is_report_only
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]), manifest: flat_manifest("other.mp3"))
    prop = proposal(batch["clips"].first["source_id"])
    assert_equal [ "report-only", false ], prop.values_at("action", "executable")
    assert_match(/no manifest entry/, prop["why"])
    assert_nil prop["estimate_usd"]
  end

  def test_declining_leaves_the_proposal_ledger_and_audio_unchanged
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]))
    id = batch["clips"].first["source_id"]
    before = [ File.read(File.join(@out, id, "regen.json")), File.read(File.join(@out, "spend.json")), File.binread(a), batch["clips"].first["current"] ]
    calls = []
    code, out = regen(calls: calls)
    assert_equal 2, code
    assert_match(/nothing is re-voiced without approval/, out)
    assert_empty calls
    assert_equal before, [ File.read(File.join(@out, id, "regen.json")), File.read(File.join(@out, "spend.json")), File.binread(a), batch["clips"].first["current"] ]
  end

  def test_only_approved_clips_are_revoiced_and_a_fresh_process_resumes_on_the_take
    a = bound_clip("a", "intro")
    b = bound_clip("b", "outro")
    judged_with_manifest(a, b, http: Judge.new(score: 7, issues: [ P1_PROSODY ]))
    ida, idb = batch["clips"].map { |c| c["source_id"] }
    b_before = batch["clips"][1]["current"]
    calls = []
    code, out = regen(ida, calls: calls)
    assert_equal 0, code, out
    assert_equal 1, calls.size
    assert_equal "voice-a", calls.first.path[%r{text-to-speech/([^/]+)/}, 1]
    cur = batch["clips"][0]["current"]
    assert_equal File.join(@out, ida, "takes", "#{ida}.t1.mp3"), cur["audio"]
    assert_equal "verified", RoastAudioWords.provenance(cur["alignment"], audio_sha256: cur["audio_sha256"])[:status]
    assert_equal b_before, batch["clips"][1]["current"]
    assert_equal [ "regen", "settled" ], JSON.parse(File.read(File.join(@out, "spend.json")))["entries"].last.values_at("op", "status")
    assert_equal a, batch["clips"][0]["source_audio"], "the source id and source file never change"

    script = File.expand_path("../scripts/roast.rb", __dir__)
    tags = { "intro.mp3" => "continuous", "outro.mp3" => "continuous", File.basename(cur["audio"]) => "continuous" }
    stdout, status = Open3.capture2e({ "CF_TEST_DOCKER_TAGS" => JSON.generate(tags), "CF_SENSITIVE_TERMS_FILE" => @terms },
                                     RbConfig.ruby, "-r", File.expand_path("roast_audio_subprocess_boot.rb", __dir__), script,
                                     "--audio", a, "--audio", b, "--brief", @brief, "--out-dir", @out, "--manifest", flat_manifest("intro.mp3", "outro.mp3"),
                                     "--stop-after", "words")
    assert status.success?, stdout
    assert_match(/gate #{ida} \(intro\.mp3\): pass/, stdout)
    assert_match(/words #{ida} \(intro\.mp3\): 0 raw, 0 accepted; source alignment, timing verified/, stdout)
    assert_match(/#{idb} \(outro\.mp3\): skipped, blocked/, stdout)
    assert Dir.glob(File.join(@out, ida, "stale", "*", "gate.json")).any?, "the old take's records went stale"
    assert Dir.glob(File.join(@out, ida, "stale", "*", "round-1.json")).any?
    assert_equal ida, JSON.parse(File.read(File.join(@out, ida, "gate.json")))["source_id"]
    assert_equal cur["audio"], JSON.parse(File.read(File.join(@out, ida, "gate.json")))["input"]["audio"]
  end

  def test_an_exhausted_clip_is_refused_until_max_attempts_is_raised
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]), extra: [ "--max-attempts", "1" ])
    id = batch["clips"].first["source_id"]
    assert_equal [ "revoice", false ], proposal(id).values_at("action", "executable")
    assert_match(/exhausted/, proposal(id)["why"])
    calls = []
    code, out = regen(id, calls: calls)
    assert_equal 1, code
    assert_match(/not executable \(exhausted/, out)
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]), extra: [ "--max-attempts", "3" ])
    assert proposal(id)["executable"]
    code, = regen(id, calls: calls)
    assert_equal 0, code
    assert_equal 1, calls.size
  end

  def test_a_clip_edited_to_exhausted_after_the_proposal_is_refused_at_dispatch
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]))
    id = batch["clips"].first["source_id"]
    ledger = RoastAudioLedger.new(@out, cap_usd: 1.0, max_usd: 0.5)
    # Exhaust the clip after the proposal is written and before dispatch.
    RoastAudioBatch.singleton_class.alias_method(:real_summary!, :summary!)
    RoastAudioBatch.define_singleton_method(:summary!) do |dir, snap|
      rows = real_summary!(dir, snap)
      b = JSON.parse(File.read(File.join(dir, "batch.json")))
      b["clips"][0]["attempts"] = b["clips"][0]["max_attempts"]
      File.write(File.join(dir, "batch.json"), JSON.generate(b))
      rows
    end
    calls = []
    code, out = regen(id, calls: calls)
    assert_equal 1, code
    assert_match(/attempts used at dispatch/, out)
    assert_empty calls
    refute(ledger.read["entries"].any? { |e| e["op"] == "regen" }, "the refused dispatch reserved nothing")
  ensure
    RoastAudioBatch.singleton_class.alias_method(:summary!, :real_summary!) if RoastAudioBatch.respond_to?(:real_summary!)
  end

  def test_a_regen_past_the_run_cap_is_refused
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]))
    id = batch["clips"].first["source_id"]
    b = batch
    b["settings"]["run_max_usd"] = 0.005 # the judge settled at about $0.0024; a $0.009 re-voice no longer fits
    File.write(File.join(@out, "batch.json"), JSON.generate(b))
    calls = []
    code, out = regen(id, calls: calls)
    assert_equal 1, code
    assert_match(/run cap/, out)
    assert_empty calls
  end

  def test_caption_fixes_and_report_only_proposals_are_refused_by_name
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY.merge("revoice" => false) ]))
    code, out = regen(batch["clips"].first["source_id"])
    assert_equal 1, code
    assert_match(/a report-only proposal is not re-voiced/, out)
  end

  # ---- per-clip manifest directory ----------------------------------------------

  def clip_json(dir, stem, pauses:)
    FileUtils.mkdir_p(dir)
    parts = CUE_TEXT.each_with_index.map { |t, i| { "n" => i + 1, "line" => { "say" => t }, "gap_ms" => pauses[i] } }.reverse
    File.write(File.join(dir, "#{stem}.json"), JSON.generate({ "parts" => parts, "speaker" => { "id" => "voice-b", "engine" => "eleven_flash_v2_5", "tune" => { "stability" => 0.6 } } }))
    dir
  end

  MAP = [ "--text-path", "parts[].line.say", "--order-key", "n", "--pause-key", "gap_ms", "--voice-path", "speaker.id", "--model-path", "speaker.engine",
          "--settings-path", "speaker.tune" ].freeze

  def test_a_per_clip_directory_maps_nested_text_in_order_and_keeps_segments
    dir = clip_json(File.join(@tmp, "clips"), "intro", pauses: [ 0, 0, 0 ])
    entries = RoastAudioBatch.manifest(dir, map: { text_path: "parts[].line.say", order_key: "n", pause_key: "gap_ms", voice_path: "speaker.id",
                                                   model_path: "speaker.engine", settings_path: "speaker.tune" })
    e = entries.fetch("intro.mp3")
    assert_equal CUE_TEXT.join(" "), e["text"]
    assert_equal 3, e["segments"].size
    assert_equal [ "voice-b", "eleven_flash_v2_5", { "stability" => 0.6 } ], e.values_at("voice_id", "model", "settings")
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]), manifest: dir, extra: MAP)
    prop = proposal(batch["clips"].first["source_id"])
    assert_equal [ "revoice", true, 0.6 ], [ prop["action"], prop["executable"], prop["retake"]["settings"]["stability"] ]
  end

  def test_segments_with_pauses_are_report_only_and_keep_their_boundaries
    dir = clip_json(File.join(@tmp, "clips"), "intro", pauses: [ 400, 250, 0 ])
    a = bound_clip("a", "intro")
    judged_with_manifest(a, http: Judge.new(score: 7, issues: [ P1_PROSODY ]), manifest: dir, extra: MAP)
    prop = proposal(batch["clips"].first["source_id"])
    assert_equal [ "report-only", false ], prop.values_at("action", "executable")
    assert_match(/3 segments with pauses \(pause_ms 400, 250, 0\)/, prop["why"])
    assert_equal [ 400, 250, 0 ], prop["retake"]["segments"].map { |g| g["pause_ms"] }
  end

  def test_a_bad_or_ambiguous_manifest_exits_2
    a = bound_clip("a", "intro")
    bad = File.join(@tmp, "bad.json")
    File.write(bad, JSON.generate({ "clips" => [ { "file" => "intro.mp3", "text" => "hi" } ] }))
    code, out = judged_with_manifest(a, http: Judge.new(score: 9), manifest: bad)
    assert_equal 2, code
    assert_match(/has no voice_id/, out)
    b = bound_clip("b", "intro")
    code, out = judged_with_manifest(a, b, http: Judge.new(score: 9), manifest: flat_manifest("intro.mp3"))
    assert_equal 2, code
    assert_match(/matches 2 clips/, out)
  end

  def test_manifest_text_is_scanned_for_sensitive_terms
    a = bound_clip("a", "intro")
    File.write(@terms, "voice-a\n")
    code, out = judged_with_manifest(a, http: Judge.new(score: 9))
    assert_equal 1, code
    assert_match(/sensitive term/, out)
  end
end
