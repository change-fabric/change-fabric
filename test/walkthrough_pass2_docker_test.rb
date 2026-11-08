# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../scripts/change_docker"
require_relative "../scripts/ffmpeg_watchdog"
require_relative "../scripts/walkthrough_ffmpeg"

# Real pass 1 and pass 2 in the pinned FFmpeg image against hostile audio:
# mono mp3 narration with a non-zero start_time at two rates, a WAV whose
# header claims an unbounded data length, and stereo music well short of the
# timeline. The assembled mp4 must end on the timeline with 48 kHz stereo
# audio of the same length, and a runaway encode must be killed, not hung.
class WalkthroughPass2DockerTest < Minitest::Test
  FPS = 30
  SCENE_S = 3
  SCENES = 3
  TOTAL_MS = SCENES * SCENE_S * 1000

  def setup
    skip "docker not available" unless ChangeDocker.available?
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def ffmpeg(args, entrypoint: nil, timeout: 120)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args, entrypoint: entrypoint,
                                    mounts: { @dir => "/work" }, workdir: "/work")
    Open3.capture2e("timeout", timeout.to_s, *argv)
  end

  def make!(args)
    out, status = ffmpeg([ "-hide_banner", "-v", "error", "-y" ] + args)
    skip "could not make fixtures: #{out.lines.last(3).join}" unless status.success?
  end

  # A WAV whose RIFF and data sizes both read 0xFFFFFFFF, as a streamed or
  # truncated writer leaves them: the header no longer bounds the clip.
  def corrupt_wav!(name)
    make!([ "-f", "lavfi", "-i", "sine=f=330:r=96000:d=2", "-ac", "1", "-bitexact", name ])
    path = File.join(@dir, name)
    bytes = File.binread(path)
    data = bytes.index("data")
    bytes[4, 4] = [ 0xFFFFFFFF ].pack("V")
    bytes[data + 4, 4] = [ 0xFFFFFFFF ].pack("V")
    File.binwrite(path, bytes)
  end

  def fixtures!
    SCENES.times do |i|
      FileUtils.mkdir_p(File.join(@dir, "f#{i}"))
      make!([ "-f", "lavfi", "-i", "color=c=gray:s=64x36:r=#{FPS}", "-frames:v", (SCENE_S * FPS).to_s,
              "-start_number", "1", "f#{i}/%06d.png" ])
    end
    make!([ "-f", "lavfi", "-i", "anoisesrc=r=44100:d=2.5:c=pink:a=0.3", "-ac", "1", "-c:a", "libmp3lame", "n0.mp3" ])
    corrupt_wav!("n1.wav")
    make!([ "-f", "lavfi", "-i", "anoisesrc=r=48000:d=2.5:c=pink:a=0.3", "-ac", "1", "-c:a", "libmp3lame", "n2.mp3" ])
    make!([ "-f", "lavfi", "-i", "sine=f=220:r=44100:d=4", "-ac", "2", "-c:a", "libmp3lame", "music.mp3" ])
    FileUtils.cp(File.join(__dir__, "..", "scripts", "vendor", "walkthrough", "cursor.png"), @dir)
    File.write(File.join(@dir, "c.srt"), "1\n00:00:00,000 --> 00:00:01,000\nhi\n")
  end

  def plan
    audio = %w[n0.mp3 n1.wav n2.mp3]
    scenes = (0...SCENES).map do |i|
      { id: "s#{i}", frames_dir: "/work/f#{i}", frames: SCENE_S * FPS, start_frame: i * SCENE_S * FPS,
        transition: { "type" => "cut", "ms" => 0 }, cursor: [], hero_still: false,
        audio: "/work/#{audio[i]}", offset_ms: (i * SCENE_S * 1000) + 200 }
    end
    { fps: FPS, width: 64, height: 36, total_ms: TOTAL_MS, cursor_png: "/work/cursor.png", srt: "/work/c.srt",
      output: "/work/out.mp4", music: { path: "/work/music.mp3", gain_db: -18 },
      duck_spans: [ { start_ms: 200, end_ms: 2700, db: -12 } ], scenes: scenes }
  end

  def probe(field)
    out, = ffmpeg([ "-v", "error", "-show_entries", field, "-of", "csv=p=0", "out.mp4" ], entrypoint: "ffprobe")
    out.lines.grep_v(/WARNING/).map(&:strip).reject(&:empty?)
  end

  def test_pass2_ends_on_the_timeline_with_hostile_audio
    fixtures!
    p = plan
    out, status = ffmpeg(WalkthroughFfmpeg.pass1(p))
    assert status.success?, out.lines.last(10).join
    measured = WalkthroughFfmpeg.parse_loudnorm(out)
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: WalkthroughFfmpeg.pass2(p, measured),
                                    mounts: { @dir => "/work" }, workdir: "/work")
    out, status = FfmpegWatchdog.run(argv, limit_s: WalkthroughFfmpeg.runaway_limit(TOTAL_MS))
    assert status.success?, out.lines.last(10).join

    total = TOTAL_MS / 1000.0
    frame = 1.0 / FPS
    video, audio = %w[video audio].map do |type|
      probe("stream=codec_type,duration").find { |l| l.start_with?(type) }.split(",").last.to_f
    end
    assert_in_delta total, video, 2 * frame
    assert_in_delta total, audio, 2 * frame
    assert_includes probe("stream=codec_type,sample_rate,channels"), "audio,48000,2"
  end

  # An endless source is the runaway in its purest form: the watchdog kills
  # the named container once output time passes the limit.
  def test_watchdog_kills_a_runaway_container
    name = "cf-walkthrough-watchdog-test-#{Process.pid}"
    argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, name: name,
                                    args: [ "-hide_banner", "-nostdin", "-progress", "pipe:1", "-nostats",
                                            "-f", "lavfi", "-i", "sine=r=48000", "-f", "null", "-" ])
    kill = -> { system("docker", "kill", name, out: File::NULL, err: File::NULL) }
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = assert_raises(FfmpegWatchdog::RunawayError) { FfmpegWatchdog.run(argv, limit_s: 20, kill: kill, label: "pass 2") }
    assert_match(/pass 2 ran away/, err.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 60
    running, = Open3.capture2e("docker", "ps", "-q", "--filter", "name=#{name}")
    assert_empty running.strip, "the container is gone"
  ensure
    system("docker", "rm", "-f", name, out: File::NULL, err: File::NULL) if name
  end

  # Opt-in soak (CF_WALKTHROUGH_SOAK=1, several minutes): the shape that ran
  # away before this graph was bounded. 20 mono 44.1 kHz mp3 clips with a
  # non-zero start_time, stereo music 192s short of a ~13 min timeline. The
  # old graph (amix duration=longest into a bare apad) intermittently kept
  # emitting audio for hours in pass 1; each run here must stop on time.
  SOAK_DURS = [ 23.43, 74.71, 19.25, 10.63, 14.21, 10.89, 17.16, 41.82, 33.93, 17.68,
                91.72, 81.74, 57.68, 22.47, 12.67, 49.68, 42.63, 22.80, 56.08, 48.30 ].freeze

  def test_soak_long_mp3_timeline_stays_bounded
    skip "set CF_WALKTHROUGH_SOAK=1 to run" unless ENV["CF_WALKTHROUGH_SOAK"] == "1"

    start = 0
    scenes = SOAK_DURS.each_with_index.map do |d, i|
      make!([ "-f", "lavfi", "-i", "anoisesrc=r=44100:d=#{d}:c=pink:a=0.3", "-ac", "1", "-c:a", "libmp3lame", "n#{i}.mp3" ])
      frames = ((d + 3.6) * FPS).round
      scene = { id: "s#{i}", frames: frames, start_frame: start, audio: "/work/n#{i}.mp3", offset_ms: (start * 1000 / FPS) + 500 }
      start += frames
      scene
    end
    total_ms = start * 1000 / FPS
    make!([ "-f", "lavfi", "-i", "sine=f=220:r=44100:d=#{(total_ms / 1000.0) - 192}", "-ac", "2", "-c:a", "libmp3lame", "music.mp3" ])
    soak = { fps: FPS, total_ms: total_ms, music: { path: "/work/music.mp3", gain_db: -18 }, scenes: scenes,
             duck_spans: scenes.zip(SOAK_DURS).map { |s, d| { start_ms: s[:offset_ms], end_ms: s[:offset_ms] + (d * 1000).round, db: -12 } } }
    3.times do |k|
      name = "cf-walkthrough-soak-#{Process.pid}-#{k}"
      args = WalkthroughFfmpeg.pass1(soak)
      args.insert(3, "-progress", "pipe:1", "-nostats")
      argv = ChangeDocker.run_command(network: "none", image: ChangeDocker::FFMPEG_IMAGE, args: args, name: name,
                                      mounts: { @dir => "/work" }, workdir: "/work")
      kill = -> { system("docker", "kill", name, out: File::NULL, err: File::NULL) }
      out, status = FfmpegWatchdog.run(argv, limit_s: WalkthroughFfmpeg.runaway_limit(total_ms), kill: kill, label: "soak pass 1 run #{k}")
      assert status.success?, out.lines.last(5).join
    end
  end
end
