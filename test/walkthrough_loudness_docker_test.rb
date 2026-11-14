# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/walkthrough_ffmpeg"

# Real pass 1 and pass 2 in the pinned FFmpeg image on a mix whose loudness
# range is well above loudnorm's LRA=11 target: a loud half then a quiet half.
# loudnorm with linear=true falls back to dynamic mode on such a mix and
# squeezes the range; the static gain plus limiter must keep the range within
# about 1 LU of the input and land integrated loudness within 1 LU of -16.
class WalkthroughLoudnessDockerTest < Minitest::Test
  FPS = 30
  TOTAL_MS = 20_000

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def ffmpeg(args, entrypoint: nil)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args, entrypoint: entrypoint,
                                    mounts: { @dir => "/work" }, workdir: "/work")
    Open3.capture2e("timeout", "300", *argv)
  end

  def ffmpeg!(args)
    out, status = ffmpeg(args)
    assert status.success?, out.lines.last(10).join
    out
  end

  def make!(args)
    out, status = ffmpeg([ "-hide_banner", "-v", "error", "-y" ] + args)
    skip "could not make fixtures: #{out.lines.last(3).join}" unless status.success?
  end

  # A tone 20 dB quieter for its second half: low crest factor, so the gain
  # never reaches the limiter and the range is the leveling's alone.
  def fixtures!
    FileUtils.mkdir_p(File.join(@dir, "f0"))
    make!([ "-f", "lavfi", "-i", "color=c=gray:s=64x36:r=#{FPS}", "-frames:v", (TOTAL_MS / 1000 * FPS).to_s,
            "-start_number", "1", "f0/%06d.png" ])
    make!([ "-f", "lavfi", "-i", "sine=f=440:r=48000:d=20", "-af", "volume=0.1,volume='if(lt(t,10),1,0.1)':eval=frame",
            "-ac", "1", "n0.wav" ])
    FileUtils.cp(File.join(__dir__, "..", "scripts", "vendor", "walkthrough", "cursor.png"), @dir)
  end

  # Square-wave clicks between quiet passages: high crest factor and
  # intersample overshoot, so the gain drives the limiter hard.
  def transient_fixture!
    fixtures!
    make!([ "-f", "lavfi", "-i", "aevalsrc='0.5*sgn(sin(2*PI*3001*t))*lt(mod(t,0.5),0.004)+0.01*sin(2*PI*220*t)':s=48000:d=20",
            "-ac", "1", "-y", "n0.wav" ])
  end

  def plan
    scene = { id: "s0", frames_dir: "/work/f0", frames: TOTAL_MS / 1000 * FPS, start_frame: 0,
              transition: { "type" => "cut", "ms" => 0 }, cursor: [], hero_still: false, audio: "/work/n0.wav", offset_ms: 0 }
    { fps: FPS, width: 64, height: 36, total_ms: TOTAL_MS, cursor_png: "/work/cursor.png", srt: "/work/c.srt",
      output: "/work/out.mp4", music: nil, duck_spans: [], scenes: [ scene ], caption_track: false }
  end

  def measure(input)
    WalkthroughFfmpeg.parse_loudnorm(ffmpeg!([ "-hide_banner", "-nostdin", "-i", input, "-af", WalkthroughFfmpeg.pass1_loudnorm, "-f", "null", "-" ]))
  end

  def test_static_level_keeps_the_range_and_hits_the_target
    fixtures!
    p = plan
    measured = WalkthroughFfmpeg.parse_loudnorm(ffmpeg!(WalkthroughFfmpeg.pass1(p)))
    assert_operator measured["input_lra"].to_f, :>, 11.0, "the fixture must exceed loudnorm's LRA target"

    ffmpeg!(WalkthroughFfmpeg.pass2(p, measured))
    delivered = measure("out.mp4")
    assert_in_delta measured["input_lra"].to_f, delivered["input_lra"].to_f, 1.0, "loudness range was compressed"
    assert_in_delta WalkthroughFfmpeg::TARGET_I, delivered["input_i"].to_f, 1.0
  end

  # The limiter alone, to PCM: oversampled it holds the TP ceiling, while
  # the same alimiter at 48 kHz lets intersample peaks through above 0 dBTP.
  def test_limiter_holds_the_true_peak_ceiling
    transient_fixture!
    gain = WalkthroughFfmpeg.static_gain(measure("n0.wav"))
    tp = lambda do |limiter|
      ffmpeg!([ "-hide_banner", "-nostdin", "-y", "-i", "n0.wav", "-af", "volume=#{gain}dB,#{limiter},aresample=48000",
                "-c:a", "pcm_f32le", "lim.wav" ])
      measure("lim.wav")["input_tp"].to_f
    end
    assert_operator tp.call(WalkthroughFfmpeg::LIMITER), :<=, WalkthroughFfmpeg::TARGET_TP + 0.1
    assert_operator tp.call(WalkthroughFfmpeg::LIMITER.sub(/\Aaresample=\d+,/, "")), :>, 0.0
  end

  # The delivered mp4 adds AAC's own overshoot, measured at about 0.5 dB.
  def test_delivered_transients_stay_near_the_ceiling
    transient_fixture!
    p = plan
    measured = WalkthroughFfmpeg.parse_loudnorm(ffmpeg!(WalkthroughFfmpeg.pass1(p)))
    assert_operator measured["input_tp"].to_f + WalkthroughFfmpeg.static_gain(measured), :>, 0, "the fixture must need limiting"
    ffmpeg!(WalkthroughFfmpeg.pass2(p, measured))
    assert_operator measure("out.mp4")["input_tp"].to_f, :<=, WalkthroughFfmpeg::TARGET_TP + 1.0
  end

  # The fixture is the case the bug lives in: the old linear loudnorm pass 2
  # on the same input goes dynamic and squeezes the range by more than 1 LU.
  def test_old_linear_loudnorm_would_compress_the_range
    fixtures!
    raw = measure("n0.wav")
    values = { "measured_I" => raw["input_i"], "measured_TP" => raw["input_tp"], "measured_LRA" => raw["input_lra"],
               "measured_thresh" => raw["input_thresh"], "offset" => raw["target_offset"] }
    old = "loudnorm=#{WalkthroughFfmpeg::LOUDNORM}:#{values.map { |k, v| "#{k}=#{v}" }.join(':')}:linear=true"
    ffmpeg!([ "-hide_banner", "-nostdin", "-i", "n0.wav", "-af", "#{old},aresample=48000", "-y", "old.wav" ])
    assert_operator raw["input_lra"].to_f - measure("old.wav")["input_lra"].to_f, :>, 1.0
  end
end
