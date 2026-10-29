# frozen_string_literal: true

# Caption timing from ElevenLabs character alignment: word spans, SRT cues
# (at most 42 characters per line, 2 lines per cue), and music duck spans
# per scene offset for the composer.
module WalkthroughCaptions
  MAX_LINE = 42
  MAX_LINES = 2
  # A silence longer than this closes the open cue, so a cue never spans a
  # pause or a silent scene and never shows later narration early.
  MAX_GAP_MS = 1000

  module_function

  # alignment: { characters, character_start_times_seconds,
  # character_end_times_seconds }. Returns [{ text:, start_ms:, end_ms: }].
  def word_spans(alignment, offset_ms: 0)
    chars = alignment.fetch('characters')
    starts = alignment.fetch('character_start_times_seconds')
    ends = alignment.fetch('character_end_times_seconds')
    words = []
    current = nil
    chars.each_with_index do |ch, i|
      if ch.match?(/\s/)
        words << current if current
        current = nil
        next
      end
      current ||= { text: +'', start_ms: ms(starts[i]) + offset_ms }
      current[:text] << ch
      current[:end_ms] = ms(ends[i]) + offset_ms
    end
    words << current if current
    words
  end

  def ms(seconds) = (seconds.to_f * 1000).round

  # Greedy packing of words into cues of up to MAX_LINES lines of MAX_LINE.
  def cues(words)
    out = []
    lines = []
    line = nil
    first = nil
    last = nil
    words.each do |w|
      if line && w[:start_ms] - last > MAX_GAP_MS
        lines << line
        out << { start_ms: first, end_ms: last, lines: lines }
        lines = []
        line = nil
        first = nil
      end
      if line && "#{line} #{w[:text]}".length <= MAX_LINE
        line = "#{line} #{w[:text]}"
      else
        lines << line if line
        if lines.length == MAX_LINES
          out << { start_ms: first, end_ms: last, lines: lines }
          lines = []
          first = nil
        end
        line = w[:text]
      end
      first ||= w[:start_ms]
      last = w[:end_ms]
    end
    lines << line if line
    out << { start_ms: first, end_ms: last, lines: lines } unless lines.empty?
    out
  end

  def srt(cue_list)
    cue_list.each_with_index.map do |c, i|
      "#{i + 1}\n#{timestamp(c[:start_ms])} --> #{timestamp(c[:end_ms])}\n#{c[:lines].join("\n")}\n"
    end.join("\n")
  end

  # WebVTT sidecar of the same cues: a WEBVTT header and dot milliseconds.
  def vtt(srt_text) = "WEBVTT\n\n#{srt_text.gsub(/(\d{2}:\d{2}:\d{2}),(\d{3})/, '\\1.\\2')}"

  def timestamp(total_ms)
    h, rem = total_ms.divmod(3_600_000)
    m, rem = rem.divmod(60_000)
    s, msr = rem.divmod(1000)
    format('%<h>02d:%<m>02d:%<s>02d,%<ms>03d', h: h, m: m, s: s, ms: msr)
  end

  # scenes: [{ offset_ms:, alignment:, duck_db: }]. A duck span covers the
  # first to last spoken character of each scene, shifted by its offset.
  def duck_spans(scenes)
    scenes.filter_map do |s|
      words = word_spans(s.fetch(:alignment), offset_ms: s.fetch(:offset_ms))
      next if words.empty?

      { start_ms: words.first[:start_ms], end_ms: words.last[:end_ms], db: s.fetch(:duck_db, -12) }
    end
  end
end
