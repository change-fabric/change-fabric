# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'change_docker'
require_relative 'roast_vtt'
require_relative 'walkthrough_loudness'

# The free, deterministic gate of cf:roast --audio. Every measurement runs in
# the pinned FFmpeg container: ffprobe for the guard and format, one pass of
# astats, silencedetect and ebur128 for clipping, DC, edges and loudness, and a
# 10 ms RMS profile of the source for the noise floor over expected non-speech
# regions. Repairable failures (format, loudness, true peak, DC, edge pad, and
# the caption shift a trim implies) are fixed for free in one filter chain into
# a new file, which is gated again; the source is mounted read-only and never
# written. What a repair cannot fix (source clipping, a noise bed, a target
# still missed after the fix) is terminal and waits for a re-voice.
module RoastAudioGate
  DEFAULTS = {
    lufs: WalkthroughLoudness::TARGET_I, lufs_tol: WalkthroughLoudness::TOLERANCE_LU, max_tp: WalkthroughLoudness::MAX_TP,
    max_clipped: 0, noise_max: -60.0, pad_min: 0.1, pad_max: 0.5, sample_rate: 44_100, channels: 1,
    min_kbps: 128, fix_kbps: 192, noise_windows: []
  }.freeze
  SAMPLE_RATES = [ 22_050, 32_000, 44_100, 48_000 ].freeze
  MAX_BYTES = 20 * 1024 * 1024
  MAX_SECONDS = 600
  SILENCE_DB = -50
  SILENCE_MIN_S = 0.02
  CLIP_DBFS = -0.1
  DC_MAX = 0.005
  LRA = 11
  NOISE_REGION_MIN_S = 0.2
  NOISE_TRIM_S = 0.05
  RMS_FRAME_S = 0.01
  FLOOR_DB = -120.0
  REPAIRABLE = %w[format loudness true_peak dc_offset pad].freeze
  SRC = '/src'
  OUT = '/out'
  DEFAULT_DOCKER = ->(argv) { Open3.capture2e(*argv) }

  class GateError < StandardError; end
  class UsageError < StandardError; end

  module_function

  # Unsupported flag combinations, refused before any work.
  def validate!(cfg)
    raise UsageError, '--pad-min must not exceed --pad-max' if cfg[:pad_min] > cfg[:pad_max]
    raise UsageError, "--sample-rate must be one of #{SAMPLE_RATES.join(', ')}" unless SAMPLE_RATES.include?(cfg[:sample_rate])
    raise UsageError, '--channels must be 1 or 2' unless [ 1, 2 ].include?(cfg[:channels])
    raise UsageError, '--fix-kbps must be at least --min-kbps' if cfg[:fix_kbps] < cfg[:min_kbps]
    raise UsageError, '--max-tp must be below 0' unless cfg[:max_tp].negative?
    raise UsageError, '--pad-min must not be negative' if cfg[:pad_min].negative?

    cfg
  end

  # The gate's own deps: only the flags that change what the gate measures or writes.
  def config_hash(cfg) = Digest::SHA256.hexdigest(JSON.generate(DEFAULTS.keys.to_h { |k| [ k, cfg[k] ] }))

  # ---- measurement -------------------------------------------------------

  def mounts(path) = { File.dirname(File.expand_path(path)) => { target: SRC, readonly: true } }

  def run!(docker, argv, what)
    output, status = docker.call(argv)
    raise GateError, "#{what} failed (is Docker running?):\n#{output.to_s.lines.last(6).join}" unless status.success?

    output.to_s
  end

  def probe(path, docker:)
    argv = ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, entrypoint: 'ffprobe', workdir: SRC, mounts: mounts(path),
                                    args: [ '-v', 'error', '-show_format', '-show_streams', '-of', 'json', "#{SRC}/#{File.basename(path)}" ])
    parse_probe(run!(docker, argv, 'ffprobe'))
  end

  def parse_probe(output)
    data = JSON.parse(output[/\{.*\}/m] || raise(GateError, 'ffprobe printed no JSON'))
    stream = Array(data['streams']).find { |s| s['codec_type'] == 'audio' } or raise GateError, 'no audio stream'
    format = data['format'] || {}
    { 'codec' => stream['codec_name'], 'channels' => stream['channels'].to_i, 'sample_rate' => stream['sample_rate'].to_i,
      'kbps' => ((stream['bit_rate'] || format['bit_rate']).to_i / 1000.0).round(1), 'duration_s' => format['duration'].to_f.round(3) }
  end

  def analysis_argv(path)
    ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, workdir: SRC, mounts: mounts(path),
                             args: [ '-hide_banner', '-nostdin', '-nostats', '-i', "#{SRC}/#{File.basename(path)}", '-map', '0:a:0', '-af',
                                     "astats=metadata=0:measure_perchannel=none,silencedetect=noise=#{SILENCE_DB}dB:d=#{SILENCE_MIN_S}," \
                                     'ebur128=peak=true:framelog=verbose', '-f', 'null', '-' ])
  end

  # Loudness, peaks, DC, decoded length and silences from one pass.
  def parse_analysis(output, sample_rate:)
    loud = WalkthroughLoudness.parse(output) or raise GateError, 'ebur128 printed no summary'
    stat = ->(name) { output[/\] #{Regexp.escape(name)}: (-?(?:inf|[\d.]+))/, 1] }
    peak_db = number(stat.call('Peak level dB'))
    samples = stat.call('Number of samples').to_f
    duration = sample_rate.positive? && samples.positive? ? samples / sample_rate : nil
    { 'integrated' => finite(loud[:integrated]), 'true_peak' => finite(loud[:true_peak]), 'peak_db' => finite(peak_db),
      'clipped' => peak_db >= CLIP_DBFS ? stat.call('Peak count').to_f.round : 0, 'dc_offset' => stat.call('DC offset').to_f,
      'decoded_s' => duration&.round(3), 'silences' => silences(output, duration) }
  end

  def silences(output, duration)
    out = []
    output.scan(/silence_(start|end): (-?[\d.]+)/) do |kind, t|
      if kind == 'start' then out << [ t.to_f, nil ]
      elsif out.last && out.last[1].nil? then out.last[1] = t.to_f
      end
    end
    out.each { |s| s[1] ||= duration || s[0] }.map { |s, e| [ s.round(3), e.round(3) ] }
  end

  def rms_argv(path)
    ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, workdir: SRC, mounts: mounts(path),
                             args: [ '-hide_banner', '-nostdin', '-nostats', '-loglevel', 'info', '-i', "#{SRC}/#{File.basename(path)}", '-map', '0:a:0', '-af',
                                     "aformat=channel_layouts=mono,asetnsamples=n=#{(44_100 * RMS_FRAME_S).round}:p=0," \
                                     'astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level,' \
                                     'ametadata=mode=print:key=lavfi.astats.Overall.RMS_level', '-f', 'null', '-' ])
  end

  # [[time_s, rms_db], ...] per 10 ms frame. asetnsamples counts samples, so
  # the frame length is exact only at 44.1 kHz; pts_time keeps it honest.
  def parse_rms(output)
    times = output.scan(/pts_time:(-?[\d.]+)/).flatten.map(&:to_f)
    levels = output.scan(/RMS_level=(-?(?:inf|[\d.]+))/).flatten.map { |v| number(v) }
    times.zip(levels).reject { |_, l| l.nil? }
  end

  def number(text) = text.to_s.include?('inf') ? -Float::INFINITY : Float(text)

  def finite(value) = value.nil? ? nil : [ value, FLOOR_DB ].max.round(2)

  # Everything the checks read. rms: false skips the profile (only the source needs it).
  def measure(path, docker:, rms: true, probed: nil)
    m = (probed || probe(path, docker: docker)).merge('bytes' => File.size(path))
    m.merge!(parse_analysis(run!(docker, analysis_argv(path), 'ffmpeg analysis'), sample_rate: m['sample_rate']))
    m['duration_s'] = m['decoded_s'] if m['decoded_s']
    m.merge!(edges(m['silences'], m['duration_s']))
    m['speech'] = speech(m['silences'], m['duration_s'])
    m['rms'] = parse_rms(run!(docker, rms_argv(path), 'ffmpeg rms profile')) if rms
    m
  end

  # ---- derived -----------------------------------------------------------

  def edges(silences, duration)
    lead = silences.find { |s, _| s <= 0.001 }
    tail = silences.find { |_, e| e >= duration - 0.02 }
    { 'lead_s' => lead ? lead[1].round(3) : 0.0, 'tail_s' => tail ? (duration - tail[0]).round(3) : 0.0 }
  end

  # Detected speech in ms: the complement of the silences inside [0, duration].
  def speech(silences, duration)
    out = []
    cursor = 0.0
    silences.each do |s, e|
      out << [ cursor, s ] if s > cursor
      cursor = [ cursor, e ].max
    end
    out << [ cursor, duration ] if duration > cursor
    out.map { |s, e| [ (s * 1000).round, (e * 1000).round ] }.reject { |s, e| e - s < 1 }
  end

  # Expected non-speech regions in seconds, from the most trustworthy source
  # available: verified word spans, explicit windows, then caption cue gaps.
  # Returns [source, regions]; source nil means none was usable (unverified).
  def noise_regions(duration:, words: nil, windows: [], cues: [])
    return [ 'windows', windows.map { |s, e| [ s.to_f, e.to_f ] } ] unless windows.empty?

    spans = if words&.any? then [ 'alignment', words.map { |w| [ w[:start_ms] / 1000.0, w[:end_ms] / 1000.0 ] } ]
    elsif cues.any? then [ 'cues', cues.map { |c| [ c.start_ms / 1000.0, c.end_ms / 1000.0 ] } ]
    end
    return [ nil, [] ] unless spans

    [ spans[0], gaps(spans[1], duration) ]
  end

  def gaps(spans, duration)
    bounds = [ [ nil, 0.0 ], *spans.sort, [ duration, nil ] ]
    bounds.each_cons(2).filter_map do |(_, a_end), (b_start, _)|
      next unless b_start - a_end >= NOISE_REGION_MIN_S - 1e-9

      [ (a_end + NOISE_TRIM_S).round(3), (b_start - NOISE_TRIM_S).round(3) ]
    end
  end

  # Power mean of the 10 ms RMS frames lying inside [start, end).
  def region_rms(profile, start, finish)
    frames = profile.select { |t, _| t >= start - 1e-6 && t + RMS_FRAME_S <= finish + 1e-6 }
    return nil if frames.empty?

    power = frames.sum { |_, db| db.finite? ? 10**(db / 10.0) : 0.0 } / frames.size
    power.positive? ? [ 10 * Math.log10(power), FLOOR_DB ].max.round(2) : FLOOR_DB
  end

  # ---- checks ------------------------------------------------------------

  def check(ok, measured, want) = { 'status' => ok ? 'pass' : 'fail', 'measured' => measured, 'want' => want }

  def guard(m)
    ok = m['bytes'] <= MAX_BYTES && m['duration_s'] <= MAX_SECONDS
    check(ok, { 'bytes' => m['bytes'], 'duration_s' => m['duration_s'] }, "<= #{MAX_BYTES / 1024 / 1024} MB and <= #{MAX_SECONDS} s")
  end

  # The checks whose result a repair can change, graded on one file.
  def repairable_checks(m, cfg, cues)
    lufs_ok = m['integrated'] && (m['integrated'] - cfg[:lufs]).abs <= cfg[:lufs_tol] + 1e-9
    pad_ok = [ m['lead_s'], m['tail_s'] ].all? { |p| p >= cfg[:pad_min] - 1e-9 && p <= cfg[:pad_max] + 1e-9 }
    {
      'format' => check(m['codec'] == 'mp3' && m['channels'] == cfg[:channels] && m['sample_rate'] == cfg[:sample_rate] && m['kbps'] >= cfg[:min_kbps],
                        m.slice('codec', 'channels', 'sample_rate', 'kbps'), "mp3, #{cfg[:channels]} ch, #{cfg[:sample_rate]} Hz, >= #{cfg[:min_kbps]} kbps"),
      'loudness' => check(lufs_ok, { 'integrated' => m['integrated'] }, "#{cfg[:lufs]} +/- #{cfg[:lufs_tol]} LUFS"),
      'true_peak' => check(m['true_peak'] && m['true_peak'] <= cfg[:max_tp] + 1e-9, { 'true_peak' => m['true_peak'] }, "<= #{cfg[:max_tp]} dBTP"),
      'dc_offset' => check(m['dc_offset'].abs <= DC_MAX, { 'dc_offset' => m['dc_offset'] }, "abs <= #{DC_MAX}"),
      'pad' => check(pad_ok, m.slice('lead_s', 'tail_s'), "lead and tail in [#{cfg[:pad_min]}, #{cfg[:pad_max]}] s"),
      'captions' => captions(cues, m)
    }
  end

  def captions(cues, m)
    failures = RoastVtt.structure(cues, duration_ms: (m['duration_s'] * 1000).round, speech: m['speech'])
    check(failures.empty?, { 'cues' => cues.size, 'failures' => failures }, 'structure only: ordered, inside speech, no uncaptioned speech')
  end

  # Source-only checks: no repair can fix them, so a failure is terminal.
  def source_checks(m, cfg, regions)
    clip_ok = m['clipped'] <= cfg[:max_clipped] && m['peak_db'] < CLIP_DBFS
    clipping = check(clip_ok, m.slice('clipped', 'peak_db'), "clipped samples <= #{cfg[:max_clipped]} and peak < #{CLIP_DBFS} dBFS")
    clipping['status'] = 'terminal' unless clip_ok
    { 'clipping' => clipping, 'noise' => noise(m, cfg, regions) }
  end

  def noise(m, cfg, (source, regions))
    measured = regions.filter_map do |s, e|
      db = region_rms(m['rms'] || [], s, e)
      db && { 'start_s' => s, 'end_s' => e, 'rms_db' => db }
    end
    want = "max region RMS <= #{cfg[:noise_max]} dBFS"
    return { 'status' => 'unverified', 'measured' => { 'source' => source, 'regions' => [] }, 'want' => want, 'reason' => 'no expected non-speech region of at least 0.2 s' } if measured.empty?

    worst = measured.map { |r| r['rms_db'] }.max
    { 'status' => worst <= cfg[:noise_max] + 1e-9 ? 'pass' : 'terminal', 'measured' => { 'source' => source, 'max_db' => worst, 'regions' => measured }, 'want' => want }
  end

  def failing(checks) = checks.reject { |_, c| %w[pass unverified].include?(c['status']) }.keys

  # ---- repair ------------------------------------------------------------

  # The repair filter chain before loudnorm, from the failed checks and the
  # effective flags: DC highpass, edge trim and pad, then downmix and resample.
  def pre_filters(failed, cfg)
    chain = []
    chain << 'highpass=f=20' if failed.include?('dc_offset')
    if failed.include?('pad') || failed.include?('captions')
      pad = ((cfg[:pad_min] + cfg[:pad_max]) / 2.0).round(3)
      trim = "silenceremove=start_periods=1:start_threshold=#{SILENCE_DB}dB"
      chain += [ trim, 'areverse', trim, 'areverse', "adelay=delays=#{(pad * 1000).round}:all=1", "apad=pad_dur=#{pad}" ]
    end
    chain << "aresample=#{cfg[:sample_rate]}" << "aformat=channel_layouts=#{cfg[:channels] == 1 ? 'mono' : 'stereo'}"
  end

  def loudnorm(cfg) = "loudnorm=I=#{cfg[:lufs]}:TP=#{(cfg[:max_tp] - 1).round(2)}:LRA=#{LRA}"

  def repair_argv(source, out_dir, args)
    ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE, workdir: OUT,
                             mounts: mounts(source).merge(File.expand_path(out_dir) => OUT),
                             args: [ '-hide_banner', '-nostdin', '-nostats', '-y', '-i', "#{SRC}/#{File.basename(source)}", '-map', '0:a:0', *args ])
  end

  # Two-pass loudnorm on the pre chain, encoded to out_path. Returns the
  # filter graph it applied.
  def repair!(source, out_path, failed, cfg, docker:)
    pre = pre_filters(failed, cfg)
    dir = File.dirname(out_path)
    FileUtils.mkdir_p(dir)
    pass1 = run!(docker, repair_argv(source, dir, [ '-af', [ *pre, "#{loudnorm(cfg)}:print_format=json" ].join(','), '-f', 'null', '-' ]), 'loudnorm pass 1')
    m = JSON.parse(pass1[/\{[^{}]*"input_i"[^{}]*\}/m] || raise(GateError, 'loudnorm pass 1 printed no measurement'))
    measured = "measured_I=#{m['input_i']}:measured_TP=#{m['input_tp']}:measured_LRA=#{m['input_lra']}:" \
               "measured_thresh=#{m['input_thresh']}:offset=#{m['target_offset']}:linear=true"
    graph = [ *pre, "#{loudnorm(cfg)}:#{measured}", "aresample=#{cfg[:sample_rate]}" ].join(',')
    run!(docker, repair_argv(source, dir, [ '-af', graph, '-ac', cfg[:channels].to_s, '-ar', cfg[:sample_rate].to_s,
                                            '-c:a', 'libmp3lame', '-b:a', "#{cfg[:fix_kbps]}k", "#{OUT}/#{File.basename(out_path)}" ]), 'repair encode')
    raise GateError, "repair wrote no file: #{out_path}" unless File.file?(out_path)

    graph
  end

  # ---- the gate ------------------------------------------------------------

  # Gates `audio` (the clip's current take) against `vtt`, repairing into
  # out_dir/<id>.a<attempt>.mp3 when allowed. Returns the gate.json record.
  # words: verified alignment word spans for the noise regions, or nil.
  def run(audio:, vtt:, id:, attempt:, out_dir:, cfg:, docker: DEFAULT_DOCKER, fix: true, words: nil)
    audio_sha = Digest::SHA256.file(audio).hexdigest
    vtt_sha = Digest::SHA256.file(vtt).hexdigest
    cues = RoastVtt.parse_file(vtt)
    base = { 'deps' => { 'audio_sha256' => audio_sha, 'vtt_sha256' => vtt_sha, 'config_hash' => config_hash(cfg) },
             'source_id' => id, 'attempt' => attempt, 'input' => { 'audio' => audio, 'vtt' => vtt } }
    probed = probe(audio, docker: docker).merge('bytes' => File.size(audio))
    guarded = guard(probed)
    return finish(base.merge('checks' => { 'guard' => guarded.merge('status' => 'terminal') }, 'measurements' => { 'source' => probed })) if guarded['status'] != 'pass'

    src = measure(audio, docker: docker, probed: probed)

    regions = noise_regions(duration: src['duration_s'], words: words, windows: cfg[:noise_windows], cues: cues)
    fixed_src = source_checks(src, cfg, regions)
    first = repairable_checks(src, cfg, cues)
    to_fix = failing(first) & (REPAIRABLE + [ 'captions' ])
    audio_fix = to_fix & REPAIRABLE
    record = base.merge('measurements' => { 'source' => slim(src) })
    if audio_fix.empty? || !fix
      # With repair allowed, only an unrepairable caption failure is left here.
      checks = first.transform_values { |c| c['status'] == 'fail' && fix ? c.merge('status' => 'terminal') : c }
      return finish(record.merge('checks' => { 'guard' => guarded }.merge(checks).merge(fixed_src),
                                 'output' => { 'audio' => audio, 'audio_sha256' => audio_sha, 'vtt' => vtt, 'vtt_sha256' => vtt_sha }))
    end

    finish(repaired(record, audio, audio_sha, cues, src, first, to_fix, out_dir, id, attempt, cfg, docker).tap do |r|
      r['checks'] = { 'guard' => guarded }.merge(r['checks']).merge(fixed_src)
    end)
  end

  def repaired(record, audio, audio_sha, cues, src, first, to_fix, out_dir, id, attempt, cfg, docker)
    out_audio = File.join(out_dir, "#{id}.a#{attempt}.mp3")
    graph = repair!(audio, out_audio, to_fix, cfg, docker: docker)
    out = measure(out_audio, docker: docker, rms: false)
    delta = to_fix.include?('pad') || to_fix.include?('captions') ? ((out['lead_s'] - src['lead_s']) * 1000).round : 0
    shifted = RoastVtt.shift(cues, delta)
    out_vtt = File.join(out_dir, "#{id}.a#{attempt}.vtt")
    File.write(out_vtt, RoastVtt.render(shifted))
    after = repairable_checks(out, cfg, shifted)
    checks = after.to_h do |name, c|
      was = first[name]['status']
      [ name, c['status'] == 'pass' ? c.merge('repaired' => was != 'pass') : c.merge('status' => 'terminal', 'before' => first[name]['measured']) ]
    end
    record.merge('checks' => checks, 'repair' => { 'filters' => graph, 'fixed' => to_fix },
                 'derived_from' => { 'source_sha256' => audio_sha, 'trim_delta_ms' => delta },
                 'output' => { 'audio' => out_audio, 'audio_sha256' => Digest::SHA256.file(out_audio).hexdigest,
                               'vtt' => out_vtt, 'vtt_sha256' => Digest::SHA256.file(out_vtt).hexdigest },
                 'measurements' => record['measurements'].merge('output' => slim(out)))
  end

  def finish(record)
    statuses = record['checks'].values.map { |c| c['status'] }
    record.merge('status' => statuses.all? { |s| %w[pass unverified].include?(s) } ? 'pass' : 'fail',
                 'terminal' => record['checks'].select { |_, c| c['status'] == 'terminal' }.keys)
  end

  def slim(m) = m.except('rms')

  private_class_method :run!, :check, :repaired, :finish, :slim, :gaps, :silences, :captions, :noise, :mounts, :repair_argv
end
