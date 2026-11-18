# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast_audio"
require_relative "roast_audio_helpers"

class RoastAudioBatchTest < Minitest::Test
  include RoastAudioHelpers

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
    assert_match(/\$0\.00 to spend/, out)
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

  def test_later_stages_are_refused_by_name_for_now
    a = stage_clip(File.join(@tmp, "a"), "continuous", as: "intro")
    out = StringIO.new
    code = RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--out-dir", @out ], out: out, docker: FakeDocker.new)
    assert_equal 2, code
    assert_match(/judge lands in phase 3/, out.string)
    code = RoastAudio::Cli.run([ "--audio", a, "--brief", @brief, "--stop-after", "words" ], out: out, docker: FakeDocker.new)
    assert_equal 2, code
    assert_match(/words lands in phase 2/, out.string)
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
end
