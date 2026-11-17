# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require_relative 'change_docker'

# The free loudness gate on a finished walkthrough master. FFmpeg's ebur128
# filter (peak=true) measures the MP4 in the pinned FFmpeg container, and the
# master passes only at -16 LUFS integrated, give or take 1 LU, with a true
# peak at or under -2 dBTP. The mix itself is leveled before this by the two
# pass static gain and true-peak limiter in WalkthroughFfmpeg; this gate
# checks what actually shipped, after AAC encoding.
#
# A board that declares itself silent (`audio: "none"`, or no narration and
# no music at all) is skipped with a logged reason. A board with narration
# whose master has no audio stream, or measures under -70 LUFS (nothing
# audible), fails.
module WalkthroughLoudness
  TARGET_I = -16.0
  TOLERANCE_LU = 1.0
  MAX_TP = -2.0
  SILENCE_FLOOR = -70.0
  WORK = '/src'
  CACHE = 'loudness.json'

  Result = Struct.new(:status, :reason, :integrated, :true_peak, keyword_init: true) do
    def pass? = status == :pass

    # :error is an operational failure (docker down), never a verdict on the MP4.
    def fail? = %i[fail error].include?(status)

    def error? = status == :error

    def skip? = status == :skip

    def line = "loudness gate: #{status}: #{reason}"
  end

  class LoudnessError < StandardError; end

  module_function

  # True when the board says it has no audio: `audio: "none"`, or no scene
  # narrates and no music bed is set.
  def declared_silent?(board)
    return true if board['audio'].to_s == 'none'

    narrated = Array(board['scenes']).any? { |s| !s.dig('narration', 'text').to_s.strip.empty? }
    !narrated && !board['music']
  end

  # The container argv measuring `mp4` (mounted read-only at /src).
  def argv(mp4)
    ChangeDocker.run_command(network: 'none', image: ChangeDocker::FFMPEG_IMAGE,
                             args: [ '-hide_banner', '-nostdin', '-nostats', '-i', "#{WORK}/#{File.basename(mp4)}",
                                     '-map', '0:a:0', '-af', 'ebur128=peak=true', '-f', 'null', '-' ],
                             mounts: { File.dirname(File.expand_path(mp4)) => WORK }, workdir: WORK)
  end

  # { integrated:, true_peak: } from the ebur128 summary, or nil when the
  # output has no summary (no audio stream to measure).
  def parse(output)
    summary = output.to_s.split(/Summary:/).last
    return nil unless output.to_s.include?('Summary:')

    i = summary[/Integrated loudness:\s*I:\s*(-?(?:\d+(?:\.\d+)?|inf))\s*LUFS/m, 1]
    peak = summary[/True peak:\s*Peak:\s*(-?(?:\d+(?:\.\d+)?|inf))\s*dBFS/m, 1]
    return nil unless i

    { integrated: number(i), true_peak: peak ? number(peak) : nil }
  end

  def number(text) = text.include?('inf') ? -Float::INFINITY : Float(text)

  # Grades one measurement. `measured` is parse's result (nil for no audio).
  def grade(measured, silent: false)
    return Result.new(status: :skip, reason: 'board declares no audio (audio: none, or no narration and no music)') if silent
    return Result.new(status: :fail, reason: 'the board has audio but the master has no audio stream') unless measured

    i = measured[:integrated]
    tp = measured[:true_peak]
    values = { integrated: i, true_peak: tp }
    if i <= SILENCE_FLOOR
      return Result.new(status: :fail, reason: "no measurable audio (integrated #{fmt(i)} LUFS, at or under #{SILENCE_FLOOR.to_i})", **values)
    end

    problems = []
    problems << "integrated #{fmt(i)} LUFS outside #{TARGET_I.to_i} +/- #{TOLERANCE_LU} LU" if (i - TARGET_I).abs > TOLERANCE_LU + 1e-9
    problems << "true peak #{fmt(tp)} dBTP above #{MAX_TP} dBTP" if tp && tp > MAX_TP + 1e-9
    reason = problems.empty? ? "integrated #{fmt(i)} LUFS, true peak #{fmt(tp)} dBTP" : problems.join('; ')
    Result.new(status: problems.empty? ? :pass : :fail, reason: reason, **values)
  end

  def fmt(value) = value.nil? ? 'n/a' : format('%.1f', value)

  # Measures and grades `mp4` for `board`. `docker` is called with an argv
  # and returns [output, status]; a declared-silent board runs no docker.
  def check(mp4, board, docker: ->(a) { Open3.capture2e(*a) })
    return grade(nil, silent: true) if declared_silent?(board)

    output, status = docker.call(argv(mp4))
    if !status.success? && !output.to_s.include?('matches no streams')
      return Result.new(status: :error, reason: "could not measure: #{output.to_s.lines.last(3).join.strip}")
    end

    grade(parse(output))
  end

  # check, cached beside the MP4 (loudness.json) by its SHA-256 and the
  # board's silent declaration, so a cached render reruns no docker.
  def cached_check(mp4, board, docker: ->(a) { Open3.capture2e(*a) })
    path = File.join(File.dirname(mp4), CACHE)
    key = { 'sha256' => Digest::SHA256.file(mp4).hexdigest, 'silent' => declared_silent?(board) }
    saved = File.file?(path) ? JSON.parse(File.read(path), allow_nan: true) : {}
    return from_h(saved['result']) if saved.slice('sha256', 'silent') == key && saved['result']

    result = check(mp4, board, docker: docker)
    return result if result.error?

    File.write(path, JSON.generate(key.merge('result' => result.to_h), allow_nan: true))
    result
  end

  def from_h(hash)
    Result.new(status: hash['status'].to_sym, reason: hash['reason'], integrated: hash['integrated'], true_peak: hash['true_peak'])
  end
end
