# frozen_string_literal: true

# Fixture clips in test/fixtures/roast_audio, made in the pinned
# ChangeDocker::FFMPEG_IMAGE:
#
# continuous.mp3 (6 s: 0.25 s lead, 5.5 s continuous 220 Hz tone, 0.25 s tail):
#   ffmpeg -f lavfi -i "anullsrc=r=44100:cl=mono:d=0.25" -f lavfi -i "sine=f=220:r=44100:d=5.5,volume=-18dB" -f lavfi -i "anullsrc=r=44100:cl=mono:d=0.25" -filter_complex "[0][1][2]concat=n=3:v=0:a=1" -ac 1 -c:a libmp3lame -b:a 128k continuous.mp3
#   (sine's default amplitude is 1/8, so the tone peaks at -36 dBFS and measures -40 LUFS: a loudness repair case.)
# noise_bed.mp3 (the same, with pink noise peaking at -45 dBFS under the whole clip):
#   ffmpeg -f lavfi -i "anullsrc=r=44100:cl=mono:d=0.25" -f lavfi -i "sine=f=220:r=44100:d=5.5,volume=-18dB" -f lavfi -i "anullsrc=r=44100:cl=mono:d=0.25" -f lavfi -i "anoisesrc=c=pink:r=44100:a=0.0056:d=6" -filter_complex "[0][1][2]concat=n=3:v=0:a=1[t];[t][3]amix=inputs=2:normalize=0" -ac 1 -c:a libmp3lame -b:a 128k noise_bed.mp3
# hot_stereo.mp3 (4 s stereo, -15.5 LUFS, true peak -1.3 dBTP, 15 ms edge fades and no pad):
#   E="0.13*sin(2*PI*220*t)*(1-between(mod(t\,1)\,0.5\,0.52))+0.9*sin(2*PI*1000*t)*between(mod(t\,1)\,0.5\,0.52)"
#   ffmpeg -f lavfi -i "aevalsrc=${E}|${E}:s=44100:d=4,afade=t=in:d=0.015,afade=t=out:st=3.985:d=0.015" -c:a libmp3lame -b:a 128k hot_stereo.mp3
# recorded/clipped.* come from a 2 s hard-clipped tone (not committed as audio):
#   ffmpeg -f lavfi -i "aevalsrc=clip(4*sin(2*PI*220*t)\,-1\,1):s=44100:d=2" -c:a libmp3lame -b:a 128k clipped.mp3
# recorded/ holds what the real container printed for each, filtered to the lines the parsers read.

require "minitest/autorun"
require "digest"
require "json"
require "tmpdir"
require_relative "../scripts/roast_audio_gate"
require_relative "../scripts/roast_audio_words"
require_relative "roast_audio_helpers"

class RoastAudioGateTest < Minitest::Test
  include RoastAudioHelpers

  def setup
    @tmp = Dir.mktmpdir("roast-audio-gate")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def cfg(**over) = RoastAudioGate::DEFAULTS.merge(noise_windows: []).merge(over)

  def gate(name, docker: FakeDocker.new, fix: true, words: nil, vtt: nil, **over)
    audio = stage_clip(File.join(@tmp, "in"), name)
    RoastAudioGate.run(audio: audio, vtt: vtt || audio.sub(/\.mp3\z/, ".vtt"), id: "src-0000abcd", attempt: 1,
                       out_dir: File.join(@tmp, "out"), cfg: cfg(**over), docker: docker, fix: fix, words: words)
  end

  def test_a_quiet_clip_is_loudness_repaired_and_passes
    docker = FakeDocker.new
    g = gate("continuous", docker: docker)
    assert_equal "pass", g["status"]
    assert_equal "pass", g["checks"]["loudness"]["status"]
    assert g["checks"]["loudness"]["repaired"]
    assert_equal(-16.2, g["checks"]["loudness"]["measured"]["integrated"])
    assert_equal [ "loudness" ], g["repair"]["fixed"]
    assert_equal({ "source_sha256" => g["deps"]["audio_sha256"], "trim_delta_ms" => 0 }, g["derived_from"])
    assert_match(%r{/out/src-0000abcd\.a1\.mp3\z}, g["output"]["audio"])
    assert_includes docker.joined(:loudnorm).first, "loudnorm=I=-16.0:TP=-3.0:LRA=11:print_format=json"
    assert_includes docker.joined(:encode).first, "measured_I=-40.10"
  end

  def test_continuous_vtt_passes_the_structure_gate_against_its_speech
    g = gate("continuous")
    assert_equal "pass", g["checks"]["captions"]["status"]
    assert_equal [ [ 250, 5750 ] ], g["measurements"]["source"]["speech"]
  end

  def test_hot_stereo_unpadded_clip_is_downmixed_limited_and_padded
    docker = FakeDocker.new
    g = gate("hot_stereo", docker: docker)
    assert_equal "pass", g["status"]
    %w[format true_peak pad].each { |c| assert g["checks"][c]["repaired"], c }
    assert_equal 300, g["derived_from"]["trim_delta_ms"]
    shifted = RoastVtt.parse_file(g["output"]["vtt"])
    assert_equal [ 300, 2300 ], shifted.map(&:start_ms)
    graph = g["repair"]["filters"]
    assert_includes graph, "silenceremove=start_periods=1:start_threshold=-50dB"
    assert_includes graph, "adelay=delays=300:all=1"
    assert_includes graph, "aformat=channel_layouts=mono"
    assert_includes docker.joined(:encode).first, "-ac 1 -ar 44100 -c:a libmp3lame -b:a 192k"
    assert_equal "unverified", g["checks"]["noise"]["status"], "no pause between cues and none at the edges"
  end

  def test_noise_bed_fails_over_caption_cue_gaps
    g = gate("noise_bed")
    noise = g["checks"]["noise"]
    assert_equal "terminal", noise["status"]
    assert_equal "cues", noise["measured"]["source"]
    assert_operator noise["measured"]["max_db"], :>, -60
    assert_equal "fail", g["status"]
    assert_includes g["terminal"], "noise"
  end

  def test_noise_bed_fails_over_an_explicit_window_and_continuous_passes
    g = gate("noise_bed", noise_windows: [ [ 0.0, 0.25 ] ])
    assert_equal "windows", g["checks"]["noise"]["measured"]["source"]
    assert_equal "terminal", g["checks"]["noise"]["status"]
    assert_equal "pass", gate("continuous", noise_windows: [ [ 0.0, 0.25 ] ])["checks"]["noise"]["status"]
  end

  def test_noise_uses_verified_alignment_word_gaps_first
    words = [ { start_ms: 260, end_ms: 2000 }, { start_ms: 2500, end_ms: 5700 } ]
    noise = gate("noise_bed", words: words)["checks"]["noise"]["measured"]
    assert_equal "alignment", noise["source"]
    assert_equal [ [ 0.05, 0.21 ], [ 2.05, 2.45 ], [ 5.75, 5.95 ] ], noise["regions"].map { |r| [ r["start_s"], r["end_s"] ] }
  end

  def test_source_clipping_is_terminal_and_stays_on_the_fixed_record
    g = gate("continuous", docker: FakeDocker.new(tags: { "continuous.mp3" => "clipped" }))
    assert_equal "terminal", g["checks"]["clipping"]["status"]
    assert_equal(-0.05, g["checks"]["clipping"]["measured"]["peak_db"])
    assert g["repair"], "other repairs still run"
    assert_includes g["terminal"], "clipping"
  end

  def test_repair_targets_follow_the_flags
    docker = FakeDocker.new
    g = gate("continuous", docker: docker, lufs: -19.0, max_tp: -4.0, fix_kbps: 256, channels: 2, sample_rate: 48_000)
    pass1 = docker.joined(:loudnorm).first
    assert_includes pass1, "loudnorm=I=-19.0:TP=-5.0:LRA=11"
    assert_includes pass1, "aformat=channel_layouts=stereo"
    assert_includes docker.joined(:encode).first, "-ac 2 -ar 48000 -c:a libmp3lame -b:a 256k"
    # The recorded fix measured -16.2 LUFS and mono 44.1 kHz, so the flag targets are missed: terminal, not pass.
    assert_equal "terminal", g["checks"]["loudness"]["status"]
    assert_equal "terminal", g["checks"]["format"]["status"]
    assert_equal({ "integrated" => -40.0 }, g["checks"]["loudness"]["before"])
  end

  def test_true_peak_still_over_after_the_fix_is_terminal
    g = gate("hot_stereo", max_tp: -3.5)
    assert_equal "terminal", g["checks"]["true_peak"]["status"]
  end

  def test_pad_still_out_of_range_after_the_fix_is_terminal
    edit = ->(t) { t.sub("silence_start: 0", "silence_start: 9") }
    g = gate("hot_stereo", docker: FakeDocker.new(edits: { "hot_stereo.fixed.analysis.txt" => edit }))
    assert_equal "terminal", g["checks"]["pad"]["status"]
  end

  def test_dc_offset_is_repaired_with_a_highpass
    over = ->(t) { t.sub(/DC offset: [\d.]+/, "DC offset: 0.020000") }
    g = gate("continuous", docker: FakeDocker.new(edits: { "continuous.analysis.txt" => over }))
    assert_includes g["repair"]["filters"], "highpass=f=20"
    assert g["checks"]["dc_offset"]["repaired"]
    still = gate("continuous", docker: FakeDocker.new(edits: { "continuous.analysis.txt" => over, "continuous.fixed.analysis.txt" => over }))
    assert_equal "terminal", still["checks"]["dc_offset"]["status"]
  end

  def test_no_fix_reports_fail_and_runs_no_repair
    docker = FakeDocker.new
    g = gate("hot_stereo", docker: docker, fix: false)
    assert_equal "fail", g["checks"]["true_peak"]["status"]
    assert_equal "fail", g["checks"]["format"]["status"]
    refute_includes docker.kinds, :encode
    assert_nil g["repair"]
  end

  def test_a_caption_failure_alone_is_terminal_with_no_repair
    vtt = File.join(@tmp, "late.vtt")
    File.write(vtt, "WEBVTT\n\n00:00.250 --> 00:02.000\na\n\n00:02.000 --> 00:03.000\nb\n")
    docker = FakeDocker.new
    g = gate("continuous", docker: docker, lufs: -40.0, vtt: vtt)
    assert_equal "terminal", g["checks"]["captions"]["status"]
    assert_equal [ "uncaptioned_speech" ], g["checks"]["captions"]["measured"]["failures"].map { |f| f["rule"] }
    refute_includes docker.kinds, :encode
  end

  def test_the_guard_stops_before_any_analysis
    long = ->(t) { t.gsub(/"duration": "[\d.]+"/, '"duration": "700.000000"') }
    docker = FakeDocker.new(edits: { "continuous.probe.json" => long })
    g = gate("continuous", docker: docker)
    assert_equal [ "guard" ], g["terminal"]
    assert_equal [ :probe ], docker.kinds
  end

  def test_the_source_is_never_written
    audio = stage_clip(File.join(@tmp, "in"), "hot_stereo")
    before = [ Digest::SHA256.file(audio).hexdigest, File.mtime(audio) ]
    docker = FakeDocker.new
    RoastAudioGate.run(audio: audio, vtt: audio.sub(".mp3", ".vtt"), id: "src-0000abcd", attempt: 1, out_dir: File.join(@tmp, "out"), cfg: cfg, docker: docker)
    assert_equal before, [ Digest::SHA256.file(audio).hexdigest, File.mtime(audio) ]
    docker.calls.each { |argv| assert_match(%r{target=/src,readonly}, argv.join(" ")) }
  end

  def test_docker_down_is_a_named_gate_error
    err = assert_raises(RoastAudioGate::GateError) { gate("continuous", docker: FakeDocker.new(down: true)) }
    assert_match(/Docker/, err.message)
  end

  def test_unsupported_flag_combinations_are_refused
    [ { pad_min: 0.6 }, { sample_rate: 16_000 }, { channels: 3 }, { fix_kbps: 96 }, { max_tp: 0.0 } ].each do |bad|
      assert_raises(RoastAudioGate::UsageError, bad.inspect) { RoastAudioGate.validate!(cfg(**bad)) }
    end
    assert RoastAudioGate.validate!(cfg)
  end

  def test_region_rms_is_a_power_mean_and_gaps_skip_short_pauses
    profile = [ [ 0.0, -60.0 ], [ 0.01, -60.0 ], [ 0.02, -Float::INFINITY ], [ 0.03, -60.0 ] ]
    assert_in_delta(-61.25, RoastAudioGate.region_rms(profile, 0.0, 0.04), 0.01)
    assert_nil RoastAudioGate.region_rms(profile, 1.0, 2.0)
    _, regions = RoastAudioGate.noise_regions(duration: 3.0, cues: [ RoastVtt::Cue.new(start_ms: 100, end_ms: 1000), RoastVtt::Cue.new(start_ms: 1100, end_ms: 2500) ])
    assert_equal [ [ 2.55, 2.95 ] ], regions
    assert_equal [ nil, [] ], RoastAudioGate.noise_regions(duration: 3.0)
  end

  def test_config_hash_covers_only_gate_flags
    assert_equal RoastAudioGate.config_hash(cfg), RoastAudioGate.config_hash(cfg.merge(unrelated: 1))
    refute_equal RoastAudioGate.config_hash(cfg), RoastAudioGate.config_hash(cfg(lufs: -18.0))
  end
end
