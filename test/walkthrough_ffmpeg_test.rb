# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/walkthrough_ffmpeg"

class WalkthroughFfmpegTest < Minitest::Test
  MEASURED = { "input_i" => "-23.10", "input_tp" => "-4.20", "input_lra" => "6.30",
               "input_thresh" => "-33.40", "target_offset" => "0.15" }.freeze

  def cursor(frames, x0 = 10)
    (1..frames).map { |f| { "frame" => f, "x" => x0 + (f > 2 ? 5 : 0), "y" => 20, "down" => false } }
  end

  def plan
    { fps: 30, width: 1920, height: 1080, total_ms: 6000, cursor_png: "/work/r/cursor.png", srt: "/work/r/captions.srt",
      output: "/work/r/walkthrough.mp4", music: { path: "/work/m.mp3", gain_db: -18 },
      duck_spans: [ { start_ms: 100, end_ms: 1500, db: -12 }, { start_ms: 2500, end_ms: 3800, db: -6 } ],
      scenes: [
        { id: "one", frames_dir: "/work/f/a", frames: 60, start_frame: 0, transition: { "type" => "cut", "ms" => 0 },
          cursor: cursor(4), hero_still: false, audio: "/work/a1.mp3", offset_ms: 0 },
        { id: "two", frames_dir: "/work/f/b", frames: 60, start_frame: 45, transition: { "type" => "fade", "ms" => 500 },
          cursor: cursor(3, 50), hero_still: false, audio: "/work/a2.mp3", offset_ms: 1500 },
        { id: "three", frames_dir: "/work/f/c", frames: 75, start_frame: 105, transition: { "type" => "cut", "ms" => 0 },
          cursor: [], hero_still: true, audio: nil, offset_ms: 3500 }
      ] }
  end

  def graph(argv) = argv[argv.index("-filter_complex") + 1].split(";")

  def test_pass2_golden_argv
    argv = WalkthroughFfmpeg.pass2(plan, MEASURED)
    inputs = argv.each_index.select { |i| argv[i] == "-i" }.map { |i| argv[i + 1] }
    assert_equal [ "/work/f/a/%06d.png", "/work/f/b/%06d.png", "/work/f/c/%06d.png", "/work/r/cursor.png",
                   "/work/a1.mp3", "/work/a2.mp3", "/work/m.mp3", "/work/r/captions.srt" ], inputs
    assert_equal [ "-framerate", "30", "-i", "/work/f/a/%06d.png" ], argv[3, 4]
    expected = [
      "[3:v]split=3[c0][c1][c2]",
      "[0:v]setpts=PTS-STARTPTS,scale=1920:1080:flags=lanczos[s0]",
      "[s0][c0]overlay=x='if(lt(n,2),10,15)':y='20':eval=frame,fps=30,settb=1/30[v0]",
      "[1:v]setpts=PTS-STARTPTS,scale=1920:1080:flags=lanczos[s1]",
      "[s1][c1]overlay=x='if(lt(n,2),50,55)':y='20':eval=frame,fps=30,settb=1/30[v1]",
      "[2:v]setpts=PTS-STARTPTS,scale=1920:1080:flags=lanczos[s2]",
      "[s2][c2]overlay=x='-200':y='-200':eval=frame,scale=iw*4:ih*4:flags=lanczos,zoompan=z='min(zoom+0.0008,1.12)':d=1:" \
      "x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1920x1080:fps=30,settb=1/30[v2]",
      "[v0][v1]xfade=transition=fade:duration=0.500:offset=1.500[j1]",
      "[j1][v2]concat=n=2:v=1:a=0,settb=1/30[j2]",
      "[j2]format=yuv420p[vout]",
      "[4:a]adelay=delays=0:all=1[n4]",
      "[5:a]adelay=delays=1500:all=1[n5]",
      "[6:a]atrim=duration=6.000,volume='if(between(t,0.100,1.500),0.2512,if(between(t,2.500,3.800),0.5012,1))':eval=frame," \
      "volume=-18.0dB[mus]",
      "[n4][n5][mus]amix=inputs=3:normalize=0:duration=longest,apad,atrim=duration=6.000," \
      "loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=-23.10:measured_TP=-4.20:measured_LRA=6.30:measured_thresh=-33.40:" \
      "offset=0.15:linear=true:print_format=summary[aout]"
    ]
    assert_equal expected, graph(argv)
    tail = argv[argv.index("-map")..]
    assert_equal [ "-map", "[vout]", "-map", "[aout]", "-map", "7:s", "-c:s", "mov_text" ], tail.first(8)
    assert_equal "/work/r/walkthrough.mp4", argv.last
  end

  def test_every_scene_link_carries_the_board_fps
    graph(WalkthroughFfmpeg.pass2(plan, MEASURED)).grep(/\[v\d\]\z/).each do |part|
      assert_match(/fps=30,settb=1\/30\[v\d\]\z/, part)
    end
  end

  def test_determinism_flags_present_in_order
    argv = WalkthroughFfmpeg.pass2(plan, MEASURED)
    flags = %w[-fflags +bitexact -flags:v +bitexact -flags:a +bitexact -r 30 -pix_fmt yuv420p -map_metadata -1
               -c:v libx264 -preset medium -crf 18 -threads 4 -c:a aac -b:a 192k]
    assert_equal flags, argv[-(flags.size + 3)...-3]
    assert_equal %w[-movflags +faststart /work/r/walkthrough.mp4], argv.last(3)
  end

  def test_subtitles_filter_only_when_burning
    soft = graph(WalkthroughFfmpeg.pass2(plan, MEASURED))
    assert_empty soft.grep(/subtitles=/)
    assert_equal "[j2]format=yuv420p[vout]", soft.find { |p| p.include?("[vout]") }
    burned = graph(WalkthroughFfmpeg.pass2(plan.merge(burn_captions: true), MEASURED))
    assert_includes burned, "[j2]subtitles=filename='/work/r/captions.srt',format=yuv420p[vout]"
  end

  def test_pass1_is_audio_only_with_json_measurement
    argv = WalkthroughFfmpeg.pass1(plan)
    refute(argv.any? { |a| a.include?("%06d") })
    g = graph(argv)
    assert_equal "[0:a]adelay=delays=0:all=1[n0]", g.first
    assert_match(/loudnorm=I=-16:TP=-1\.5:LRA=11:print_format=json\[aout\]\z/, g.last)
    assert_equal [ "-map", "[aout]", "-f", "null", "-" ], argv.last(5)
  end

  def test_parse_loudnorm_takes_last_json_block
    out = "noise\n[Parsed_loudnorm_0 @ 0x1]\n{\n  \"input_i\" : \"-20.00\",\n  \"input_tp\" : \"-1.00\"\n}\n" \
          "more\n{\n  \"input_i\" : \"-23.10\",\n  \"input_tp\" : \"-4.20\",\n  \"input_lra\" : \"6.30\",\n" \
          "  \"input_thresh\" : \"-33.40\",\n  \"target_offset\" : \"0.15\"\n}\n"
    measured = WalkthroughFfmpeg.parse_loudnorm(out)
    assert_equal MEASURED, measured
    assert_includes WalkthroughFfmpeg.pass2_loudnorm(measured), "measured_I=-23.10"
    assert_raises(WalkthroughFfmpeg::LoudnormParseError) { WalkthroughFfmpeg.parse_loudnorm("nothing") }
  end

  def test_duck_expression
    assert_equal "1", WalkthroughFfmpeg.duck_expression([])
    assert_equal "if(between(t,1.000,2.000),0.2512,1)",
                 WalkthroughFfmpeg.duck_expression([ { start_ms: 1000, end_ms: 2000, db: -12 } ])
  end

  def test_fade_offsets_follow_timeline_overlap
    p = plan
    p[:scenes][2][:transition] = { "type" => "fade", "ms" => 1000 }
    p[:scenes][2][:start_frame] = 75
    fades = WalkthroughFfmpeg.transitions(p)
    assert_equal({ offset: "1.500", duration: "0.500" }, fades[0])
    assert_equal({ offset: "2.500", duration: "1.000" }, fades[1])
  end

  def test_long_cursor_path_uses_sendcmd
    p = plan
    p[:scenes][0][:cursor] = (1..(WalkthroughFfmpeg::CHAIN_MAX + 5)).map { |f| { "frame" => f, "x" => f, "y" => 7 } }
    files = WalkthroughFfmpeg.sendcmd_files(p)
    assert_equal [ "/work/r/cursor-one.cmd" ], files.keys
    body = files.values.first
    assert body.start_with?("0.000 overlay@c0 x 1, overlay@c0 y 7;\n0.033 overlay@c0 x 2;\n")
    g = graph(WalkthroughFfmpeg.pass2(p, MEASURED))
    assert_includes g, "[0:v]setpts=PTS-STARTPTS,scale=1920:1080:flags=lanczos,sendcmd=f='/work/r/cursor-one.cmd'[s0]"
    assert_includes g, "[s0][c0]overlay@c0=x=1:y=7:eval=frame,fps=30,settb=1/30[v0]"
  end

  def test_silent_plan_uses_null_source
    p = plan.merge(music: nil)
    p[:scenes].each { |s| s[:audio] = nil }
    argv = WalkthroughFfmpeg.pass2(p, MEASURED)
    assert_match(/\Aanullsrc=r=44100:cl=stereo,atrim=duration=6\.000,loudnorm=/, graph(argv).last)
    assert_includes argv.join(" "), "-map 4:s"
  end

  def test_same_plan_same_argv
    assert_equal WalkthroughFfmpeg.pass2(plan, MEASURED), WalkthroughFfmpeg.pass2(plan, MEASURED)
  end
end

# Captured frames may arrive at a device pixel ratio above 1; every scene is
# scaled to the output canvas before the cursor overlay so all scenes agree.
class WalkthroughFfmpegCanvasScaleTest < WalkthroughFfmpegTest
  def test_every_scene_scales_to_canvas_before_overlay
    g = graph(WalkthroughFfmpeg.pass2(plan.merge(width: 1280, height: 720), MEASURED))
    [ 0, 1, 2 ].each do |i|
      assert_includes g, "[#{i}:v]setpts=PTS-STARTPTS,scale=1280:720:flags=lanczos[s#{i}]"
    end
  end
end
