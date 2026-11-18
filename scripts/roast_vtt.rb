# frozen_string_literal: true

# The WebVTT side of cf:roast --audio: a strict-enough parser, the structural
# caption checks the free gate runs, a cue shift for the gate's edge trim, and
# the m:ss.s stamp every audio finding cites. Structure only: word-boundary
# timing needs bound alignment and lives in the word check.
module RoastVtt
  Cue = Struct.new(:index, :start_ms, :end_ms, :text, keyword_init: true)

  # A cue overlapping detected speech by less than this is outside speech.
  MIN_SPEECH_OVERLAP_MS = 100
  # Speech this far before the first cue or after the last is uncaptioned,
  # and the last cue may end this far past the audio.
  EDGE_TOLERANCE_MS = 250
  TIMESTAMP = /(?:(\d+):)?(\d{2}):(\d{2})\.(\d{3})/
  TIMING = /\A\s*(#{TIMESTAMP})\s+-->\s+(#{TIMESTAMP})(?:\s+.*)?\z/

  class ParseError < StandardError; end

  module_function

  def parse_file(path) = parse(File.read(path, encoding: 'bom|utf-8'))

  # Cues in file order, indexed from 1. Header metadata, NOTE, STYLE and
  # REGION blocks are skipped; cue settings are ignored; multi-line text is
  # joined with a space.
  def parse(text)
    blocks = text.to_s.sub(/\A﻿/, '').gsub("\r\n", "\n").split(/\n[ \t]*\n+/)
    raise ParseError, 'not a WebVTT file (no WEBVTT header)' unless blocks.first.to_s.start_with?('WEBVTT')

    blocks.drop(1).filter_map { |b| cue_lines(b) }.each_with_index.map do |(timing, lines), i|
      start_ms, end_ms = timing
      Cue.new(index: i + 1, start_ms: start_ms, end_ms: end_ms, text: lines.map(&:strip).reject(&:empty?).join(' '))
    end
  end

  def cue_lines(block)
    lines = block.split("\n")
    return nil if lines.empty? || lines.first.match?(/\A(NOTE|STYLE|REGION)\b/)

    at = lines.index { |l| l.include?('-->') }
    return nil unless at && at <= 1

    m = TIMING.match(lines[at]) or raise ParseError, "bad cue timing line: #{lines[at].strip.inspect}"
    [ [ ms(m[1]), ms(m[6]) ], lines.drop(at + 1) ]
  end

  def ms(stamp)
    m = TIMESTAMP.match(stamp)
    (((m[1].to_i * 3600) + (m[2].to_i * 60) + m[3].to_i) * 1000) + m[4].to_i
  end

  # m:ss.s, the stamp every audio finding cites.
  def mmss(ms)
    tenths = (ms.to_f / 100).round
    format('%<m>d:%<s>04.1f', m: tenths / 600, s: (tenths % 600) / 10.0)
  end

  def stamp(ms)
    ms = ms.round
    format('%<h>02d:%<m>02d:%<s>02d.%<f>03d', h: ms / 3_600_000, m: (ms / 60_000) % 60, s: (ms / 1000) % 60, f: ms % 1000)
  end

  def shift(cues, delta_ms) = cues.map { |c| c.dup.tap { |n| n.start_ms += delta_ms; n.end_ms += delta_ms } }

  def render(cues)
    body = cues.map { |c| "#{stamp(c.start_ms)} --> #{stamp(c.end_ms)}\n#{c.text}" }
    "WEBVTT\n\n#{body.join("\n\n")}\n"
  end

  # Structural failures: [{ rule:, cue:, at:, detail: }]. speech is
  # [[start_ms, end_ms], ...] from silence detection on the same audio.
  def structure(cues, duration_ms:, speech:)
    return [ failure('no_cues', nil, 0, 'the caption file has no cues') ] if cues.empty?

    out = cues.flat_map { |c| cue_failures(c, duration_ms, speech) }
    cues.each_cons(2) do |a, b|
      out << failure('cue_order', b, b.start_ms, "starts before cue #{a.index}") if b.start_ms < a.start_ms
      out << failure('cue_overlap', b, b.start_ms, "overlaps cue #{a.index}") if b.start_ms >= a.start_ms && b.start_ms < a.end_ms
    end
    out + uncaptioned(cues, speech)
  end

  def cue_failures(cue, duration_ms, speech)
    out = []
    out << failure('cue_span', cue, cue.start_ms, 'start is not before end') unless cue.start_ms < cue.end_ms
    out << failure('cue_negative', cue, cue.start_ms, 'starts before 0:00.0') if cue.start_ms.negative?
    out << failure('cue_past_end', cue, cue.end_ms, "ends after the audio (#{mmss(duration_ms)})") if cue.end_ms > duration_ms + EDGE_TOLERANCE_MS
    heard = speech.sum { |s, e| [ [ e, cue.end_ms ].min - [ s, cue.start_ms ].max, 0 ].max }
    out << failure('cue_outside_speech', cue, cue.start_ms, "overlaps speech by #{heard} ms") if heard < MIN_SPEECH_OVERLAP_MS
    out
  end

  def uncaptioned(cues, speech)
    return [] if speech.empty?

    first = cues.map(&:start_ms).min
    last = cues.map(&:end_ms).max
    out = []
    lead = speech.first.first
    tail = speech.last.last
    out << failure('uncaptioned_speech', nil, lead, "speech starts #{first - lead} ms before the first cue") if lead < first - EDGE_TOLERANCE_MS
    out << failure('uncaptioned_speech', nil, last, "speech ends #{tail - last} ms after the last cue") if tail > last + EDGE_TOLERANCE_MS
    out
  end

  def failure(rule, cue, at_ms, detail) = { 'rule' => rule, 'cue' => cue&.index, 'at' => mmss(at_ms), 'detail' => detail }

  private_class_method :cue_lines, :cue_failures, :uncaptioned, :failure
end
