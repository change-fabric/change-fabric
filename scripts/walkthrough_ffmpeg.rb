# frozen_string_literal: true

require 'json'

# Pure FFmpeg argv generation for a walkthrough render. Nothing here shells
# out: the renderer hands the argv to docker in FFMPEG_IMAGE. The input is a
# plan hash built from manifest.json and the cache (container paths only):
#
#   { fps:, width:, height:, total_ms:, cursor_png:, srt:, output:,
#     music: { path:, gain_db: } | nil, duck_spans: [{ start_ms:, end_ms:, db: }],
#     scenes: [{ id:, frames_dir:, frames:, start_frame:, transition: { 'type', 'ms' },
#                cursor: [{ 'frame', 'x', 'y' }], taps: [...] | nil, hero_still:, audio:, offset_ms: }] }
#
# Audio is normalized in two passes: pass 1 measures with loudnorm
# print_format=json, pass 2 applies the measured values with linear=true.
module WalkthroughFfmpeg
  LOUDNORM = 'I=-16:TP=-1.5:LRA=11'
  # Above this many value changes per axis a cursor path is driven by a
  # sendcmd file instead of an inline if() chain, which FFmpeg parses slowly.
  CHAIN_MAX = 200
  OFFSCREEN = -200
  # The tap ripple sprite's size in canvas px (matches WalkthroughDevice::RIPPLE).
  RIPPLE = 44
  DETERMINISM = [ '-fflags', '+bitexact', '-flags:v', '+bitexact', '-flags:a', '+bitexact', '-r', '30',
                  '-pix_fmt', 'yuv420p', '-map_metadata', '-1', '-c:v', 'libx264', '-preset', 'medium',
                  '-crf', '18', '-threads', '4', '-c:a', 'aac', '-b:a', '192k' ].freeze
  MEASURED = { 'input_i' => 'measured_I', 'input_tp' => 'measured_TP', 'input_lra' => 'measured_LRA',
               'input_thresh' => 'measured_thresh', 'target_offset' => 'offset' }.freeze

  class LoudnormParseError < StandardError; end

  module_function

  def seconds(ms) = format('%.3f', ms / 1000.0)

  def frame_seconds(frames, fps) = format('%.3f', frames.to_f / fps)

  # -- cursor --------------------------------------------------------------

  # Runs of identical values on one axis as [first_n, value]; n is the
  # 0-based output frame number FFmpeg's overlay sees (cursor.json is 1-based).
  def runs(points, axis)
    points.each_with_object([]) do |pt, out|
      value = pt.fetch(axis).round
      out << [ pt.fetch('frame') - 1, value ] unless out.last && out.last[1] == value
    end
  end

  # Piecewise if(lt(n,..)) chain over the runs of one axis.
  def chain(axis_runs)
    return OFFSCREEN.to_s if axis_runs.empty?

    tail = axis_runs.last[1].to_s
    axis_runs.each_cons(2).reverse_each.reduce(tail) do |acc, ((_, value), (next_n, _))|
      "if(lt(n,#{next_n}),#{value},#{acc})"
    end
  end

  def long_path?(points) = runs(points, 'x').size > CHAIN_MAX || runs(points, 'y').size > CHAIN_MAX

  # sendcmd script for a long path: one line per frame where a value changes.
  def sendcmd(points, target, fps)
    changes = (runs(points, 'x').map { |n, v| [ n, 'x', v ] } + runs(points, 'y').map { |n, v| [ n, 'y', v ] })
    changes.group_by(&:first).sort.map do |n, list|
      "#{frame_seconds(n, fps)} #{list.map { |_, axis, v| "#{target} #{axis} #{v}" }.join(', ')};"
    end.join("\n") + "\n"
  end

  def sendcmd_path(plan, scene) = File.join(File.dirname(plan[:output]), "cursor-#{scene[:id]}.cmd")

  # { container_path => content } for every scene whose path needs sendcmd.
  def sendcmd_files(plan)
    plan[:scenes].each_with_index.filter_map do |scene, i|
      points = Array(scene[:cursor])
      [ sendcmd_path(plan, scene), sendcmd(points, "overlay@c#{i}", plan[:fps]) ] if long_path?(points)
    end.to_h
  end

  # -- video graph ---------------------------------------------------------

  def scene_chain(plan, scene, i)
    points = Array(scene[:cursor])
    raw = "[#{i}:v]setpts=PTS-STARTPTS,scale=#{plan[:width]}:#{plan[:height]}:flags=lanczos"
    taps = Array(scene[:taps])
    out = taps.empty? ? scene_output(plan, scene, i) : "[a#{i}]"
    parts = if long_path?(points)
              first = points.first
              [ "#{raw},sendcmd=f='#{sendcmd_path(plan, scene)}'[s#{i}]",
                "[s#{i}][c#{i}]overlay@c#{i}=x=#{first['x'].round}:y=#{first['y'].round}:eval=frame#{out}" ]
    else
              [ "#{raw}[s#{i}]",
                "[s#{i}][c#{i}]overlay=x='#{chain(runs(points, 'x'))}':y='#{chain(runs(points, 'y'))}':eval=frame#{out}" ]
    end
    parts.concat(tap_chain(plan, scene, i, taps)) unless taps.empty?
    parts
  end

  # A phone scene's tap ripples: a generated ring sprite (no extra input, so
  # input indices stay put) overlaid along taps.json, parked off canvas
  # between taps. Tap points are sparse, so the inline chain always fits.
  def tap_chain(plan, scene, i, taps)
    size = RIPPLE
    half = size / 2
    ring = "hypot(X-#{half},Y-#{half})"
    [ "color=c=white@0:s=#{size}x#{size}:r=#{plan[:fps]},format=rgba,"       "geq=r=255:g=255:b=255:a='if(between(#{ring},#{half - 7},#{half - 2}),210,if(lt(#{ring},#{half - 7}),70,0))'[r#{i}]",
      "[a#{i}][r#{i}]overlay=x='#{chain(runs(taps, 'x'))}':y='#{chain(runs(taps, 'y'))}':eval=frame:shortest=1"       "#{scene_output(plan, scene, i)}" ]
  end

  # A hero still slowly pushes in: upscale 4x with lanczos, then zoompan back
  # to the output size so the zoom does not shimmer. zoompan stamps its link
  # with the board fps while overlay leaves 1/0, and concat outputs a 1/1000000
  # timebase; xfade rejects a pair whose rate or timebase differ, so every
  # scene and every concat ends on an explicit fps and timebase. FFmpeg 7.1
  # drops a scene's last frame when fps follows overlay on raw timestamps, so
  # a plain scene renumbers its frames (setpts=N) before fps.
  def scene_output(plan, scene, i)
    tail = scene[:hero_still] ? ",#{hero_filter(plan)}" : ",#{timebase(plan)},setpts=N,fps=#{plan[:fps]}"
    tail = ",#{camera_filter(plan, scene[:camera])}#{tail}" if scene[:camera]
    "#{tail},#{timebase(plan)}[v#{i}]"
  end

  def timebase(plan) = "settb=1/#{plan[:fps]}"

  # A camera framing: the frame scales by `zoom` around `focus`. Zooming in
  # crops back to the canvas, clamped so the crop never leaves the frame;
  # zooming out pads back to the canvas, clamped so the frame stays whole.
  # Cursor and taps are already drawn in, so they stay aligned.
  def camera_filter(plan, camera)
    w = plan[:width]
    h = plan[:height]
    zoom = camera['zoom'].to_f
    zw = 2 * (w * zoom / 2).floor
    zh = 2 * (h * zoom / 2).floor
    fx = camera.dig('focus', 'x') || 0.5
    fy = camera.dig('focus', 'y') || 0.5
    x = camera_offset(fx, zw, w)
    y = camera_offset(fy, zh, h)
    fit = zoom >= 1 ? "crop=#{w}:#{h}:#{x}:#{y}" : "pad=#{w}:#{h}:#{x}:#{y}:color=black"
    "scale=#{zw}:#{zh}:flags=lanczos,#{fit},setsar=1"
  end

  # Offset along one axis: where the crop starts inside a larger scaled frame,
  # or where a smaller scaled frame sits inside the canvas.
  def camera_offset(focus, scaled, canvas)
    off = (focus.to_f * scaled) - (canvas / 2.0)
    scaled >= canvas ? off.clamp(0, scaled - canvas).round : (-off).clamp(0, canvas - scaled).round
  end

  def hero_filter(plan)
    "scale=iw*4:ih*4:flags=lanczos,zoompan=z='min(zoom+0.0008,1.12)':d=1:" \
      "x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=#{plan[:width]}x#{plan[:height]}:fps=#{plan[:fps]}"
  end

  # xfade offset (seconds into the accumulated stream) and duration for each
  # scene after the first; nil for a cut.
  def transitions(plan)
    plan[:scenes].each_cons(2).map do |prev, scene|
      next nil unless scene.dig(:transition, 'type') == 'fade'

      overlap = prev[:start_frame] + prev[:frames] - scene[:start_frame]
      { offset: frame_seconds(scene[:start_frame], plan[:fps]), duration: frame_seconds(overlap, plan[:fps]) }
    end
  end

  def video_graph(plan)
    n = plan[:scenes].size
    cursor_in = n
    parts = [ "[#{cursor_in}:v]split=#{n}#{(0...n).map { |i| "[c#{i}]" }.join}" ]
    plan[:scenes].each_with_index { |scene, i| parts.concat(scene_chain(plan, scene, i)) }
    acc = 'v0'
    transitions(plan).each_with_index do |fade, k|
      i = k + 1
      parts << if fade
                 "[#{acc}][v#{i}]xfade=transition=fade:duration=#{fade[:duration]}:offset=#{fade[:offset]}[j#{i}]"
      else
                 "[#{acc}][v#{i}]concat=n=2:v=1:a=0,#{timebase(plan)}[j#{i}]"
      end
      acc = "j#{i}"
    end
    # Captions are soft (a mov_text track) unless the plan asks to burn them in.
    burn = plan[:burn_captions] ? "subtitles=filename='#{plan[:srt]}'," : ''
    parts << "[#{acc}]#{burn}format=yuv420p[vout]"
    parts
  end

  # -- audio graph ---------------------------------------------------------

  # Input index of each narration clip and of the music track. Video frame
  # inputs come first, then the cursor sprite, then audio, then the SRT.
  def audio_inputs(plan)
    base = plan.fetch(:audio_base) { plan[:scenes].size + 1 }
    voiced = plan[:scenes].select { |s| s[:audio] }
    narration = voiced.each_with_index.map { |s, k| [ s, base + k ] }
    music = plan[:music] ? base + voiced.size : nil
    { narration: narration, music: music, next: base + voiced.size + (music ? 1 : 0) }
  end

  # Volume automation: gain 1 outside narration, the span's duck level inside.
  def duck_expression(spans)
    spans.reverse.reduce('1') do |acc, span|
      gain = format('%.4f', 10**(span[:db].to_f / 20))
      "if(between(t,#{seconds(span[:start_ms])},#{seconds(span[:end_ms])}),#{gain},#{acc})"
    end
  end

  # Narration EQ filters: a `bass` shelf and an `equalizer` peaking cut (this
  # ffmpeg rejects equalizer t=l). Empty without an EQ, so the graph is unchanged.
  def eq_filters(eq)
    return '' if eq.nil? || eq.empty?

    num = ->(v) { v.to_f == v.to_i ? v.to_i.to_s : v.to_f.to_s }
    out = +''
    out << ",bass=f=#{num.(eq['low_shelf_hz'])}:g=#{num.(eq['low_shelf_db'])}" if eq['low_shelf_hz']
    out << ",equalizer=f=#{num.(eq['cut_hz'])}:t=q:w=1:g=#{num.(eq['cut_db'])}" if eq['cut_hz']
    out
  end

  def audio_graph(plan, loudnorm)
    io = audio_inputs(plan)
    parts = []
    labels = []
    io[:narration].each do |scene, idx|
      parts << "[#{idx}:a]adelay=delays=#{scene[:offset_ms]}:all=1#{eq_filters(plan[:voice_eq])}[n#{idx}]"
      labels << "[n#{idx}]"
    end
    if io[:music]
      total = seconds(plan[:total_ms])
      parts << "[#{io[:music]}:a]atrim=duration=#{total},volume='#{duck_expression(plan[:duck_spans] || [])}':eval=frame," \
               "volume=#{plan[:music][:gain_db].to_f}dB[mus]"
      labels << '[mus]'
    end
    total = seconds(plan[:total_ms])
    parts << if labels.empty?
               "anullsrc=r=44100:cl=stereo,atrim=duration=#{total},loudnorm=#{loudnorm}[aout]"
    else
               "#{labels.join}amix=inputs=#{labels.size}:normalize=0:duration=longest,apad,atrim=duration=#{total}," \
                 "loudnorm=#{loudnorm}[aout]"
    end
    parts
  end

  # -- loudnorm ------------------------------------------------------------

  def pass1_loudnorm = "#{LOUDNORM}:print_format=json"

  # Pass 2 filter options from the pass 1 JSON measurement.
  def pass2_loudnorm(measured)
    values = MEASURED.map { |src, dest| "#{dest}=#{measured.fetch(src)}" }
    "#{LOUDNORM}:#{values.join(':')}:linear=true:print_format=summary"
  end

  # The last JSON object loudnorm printed to stderr.
  def parse_loudnorm(output)
    blob = output.to_s.scan(/\{[^{}]*"input_i"[^{}]*\}/m).last or raise LoudnormParseError, 'no loudnorm JSON in pass 1 output'
    JSON.parse(blob)
  end

  # -- argv ----------------------------------------------------------------

  def inputs(plan, with_video:)
    argv = []
    if with_video
      plan[:scenes].each { |s| argv += [ '-framerate', plan[:fps].to_s, '-i', File.join(s[:frames_dir], '%06d.png') ] }
      argv += [ '-i', plan[:cursor_png] ]
    end
    plan[:scenes].select { |s| s[:audio] }.each { |s| argv += [ '-i', s[:audio] ] }
    argv += [ '-i', plan[:music][:path] ] if plan[:music]
    argv
  end

  def head = [ '-hide_banner', '-nostdin', '-y' ]

  # Pass 1: audio only, measurement printed, output discarded. Audio input
  # indices are rebased since no video inputs precede them.
  def pass1(plan)
    graph = audio_graph(plan.merge(audio_base: 0), pass1_loudnorm)
    head + inputs(plan, with_video: false) + [ '-filter_complex', graph.join(';'), '-map', '[aout]', '-f', 'null', '-' ]
  end

  def pass2(plan, measured)
    io = audio_inputs(plan)
    graph = video_graph(plan) + audio_graph(plan, pass2_loudnorm(measured))
    head + inputs(plan, with_video: true) + [ '-i', plan[:srt], '-filter_complex', graph.join(';'),
                                               '-map', '[vout]', '-map', '[aout]', '-map', "#{io[:next]}:s",
                                               '-c:s', 'mov_text' ] + DETERMINISM + [ '-movflags', '+faststart', plan[:output] ]
  end
end
