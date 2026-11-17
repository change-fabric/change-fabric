# frozen_string_literal: true

require_relative 'walkthrough_duck'

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

  # A cue shorter than this, or with fewer than MIN_WORDS words, is an
  # orphan (a sentence's last word spilled into its own flash of a cue) and
  # is merged into a neighbour.
  MIN_CUE_MS = 1000
  MIN_WORDS = 2
  SENTENCE_END = /[.!?:]\z/

  # Greedy packing of words into cues of up to MAX_LINES lines of MAX_LINE,
  # then orphan merging.
  def cues(words)
    no_overlap(merge_orphans(groups(words)).map { |g| cue(g) })
  end

  # Word groups, one per cue: a group closes at a sentence end, a silence
  # over MAX_GAP_MS, or when its next word would need a third line.
  def groups(words)
    words.each_with_object([]) do |w, out|
      last = out.last
      open = last && !last.last[:text].match?(SENTENCE_END) && w[:start_ms] - last.last[:end_ms] <= MAX_GAP_MS
      if open && fits?(last + [ w ]) then last << w
      else out << [ w ]
      end
    end
  end

  def lines(group)
    group.each_with_object([]) do |w, out|
      if out.last && "#{out.last} #{w[:text]}".length <= MAX_LINE then out[-1] = "#{out.last} #{w[:text]}"
      else out << w[:text]
      end
    end
  end

  def fits?(group) = lines(group).length <= MAX_LINES

  def cue(group) = { start_ms: group.first[:start_ms], end_ms: group.last[:end_ms], lines: lines(group) }

  def orphan?(group) = group.length < MIN_WORDS || group.last[:end_ms] - group.first[:start_ms] < MIN_CUE_MS

  # Two adjacent groups belong together when the first does not end a
  # sentence and no long silence separates them.
  def joinable?(head, tail)
    !head.last[:text].match?(SENTENCE_END) && tail.first[:start_ms] - head.last[:end_ms] <= MAX_GAP_MS
  end

  # Folds each orphan into the previous cue of its sentence, else the next.
  # When the two do not fit one cue, the words are rebalanced across both so
  # neither is an orphan. Timings stay the aligned word timings.
  def merge_orphans(groups)
    out = groups.map(&:dup)
    i = 0
    while i < out.length
      if orphan?(out[i]) && (joined = join_at(out, i))
        out[joined[0], 2] = joined[1]
        i = [ joined[0] - 1, 0 ].max
      else
        i += 1
      end
    end
    out
  end

  def join_at(out, i)
    [ i - 1, i ].each do |k|
      next unless k >= 0 && k + 1 < out.length && joinable?(out[k], out[k + 1])

      both = out[k] + out[k + 1]
      return [ k, [ both ] ] if fits?(both)

      split = rebalance(both)
      return [ k, split ] if split
    end
    nil
  end

  # The latest split of `words` into two cues that both fit and neither is
  # an orphan, or nil.
  def rebalance(words)
    (words.length - MIN_WORDS).downto(MIN_WORDS).each do |n|
      head = words.first(n)
      tail = words.drop(n)
      return [ head, tail ] if fits?(head) && fits?(tail) && !orphan?(head) && !orphan?(tail)
    end
    nil
  end

  # Aligned word timings can overlap (a sentence's last word is stretched
  # over its trailing punctuation while the next word starts on the real
  # onset, and a scene's tail can run past the next scene's offset). Each
  # cue starts no earlier than the previous one ends; a cue squeezed to
  # nothing keeps a 1 ms span so it stays valid.
  def no_overlap(cue_list)
    prev_end = nil
    cue_list.map do |c|
      start = prev_end && c[:start_ms] < prev_end ? prev_end : c[:start_ms]
      stop = [ c[:end_ms], start + 1 ].max
      prev_end = stop
      c.merge(start_ms: start, end_ms: stop)
    end
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

  # scenes: [{ offset_ms:, alignment:, duck_db:, attack_ms:, release_ms: }]. A
  # duck span covers the first to last spoken character of each scene, shifted
  # by its offset; WalkthroughDuck ramps and merges them.
  def duck_spans(scenes)
    scenes.filter_map do |s|
      words = word_spans(s.fetch(:alignment), offset_ms: s.fetch(:offset_ms))
      next if words.empty?

      { start_ms: words.first[:start_ms], end_ms: words.last[:end_ms], db: s[:duck_db] || WalkthroughDuck::DEFAULT_DB,
        attack_ms: s[:attack_ms] || WalkthroughDuck::DEFAULT_ATTACK_MS, release_ms: s[:release_ms] || WalkthroughDuck::DEFAULT_RELEASE_MS }
    end
  end
end
