# frozen_string_literal: true

require 'did_you_mean'

# Word times from a cf:narrate character alignment, so a storyboard op can
# land on a spoken word instead of a hand-counted millisecond. Times are
# local to the narration clip (0 is where the voice line starts).
module WalkthroughWords
  # A word (or its nth occurrence) the narration never says.
  class Missing < StandardError; end

  CANDIDATES = 3

  module_function

  # Lowercased, punctuation stripped; apostrophes inside a word are kept
  # out too, so "don't" matches "dont" and "Don't".
  def normalize(text) = text.to_s.downcase.gsub(/[^\p{Alnum}]/, '')

  # Ordered [{ word:, nth:, start_ms:, end_ms: }] from an ElevenLabs
  # alignment hash (characters plus per-character start and end seconds).
  # nth counts occurrences of the same normalized word, from 1.
  def from_alignment(json)
    chars = json.fetch('characters')
    starts = json.fetch('character_start_times_seconds')
    ends = json.fetch('character_end_times_seconds')
    spans(chars, starts, ends).each_with_object([ [], Hash.new(0) ]) do |span, (out, seen)|
      word = normalize(span[:text])
      next if word.empty?

      out << { word: word, nth: seen[word] += 1, start_ms: span[:start_ms], end_ms: span[:end_ms] }
    end.first
  end

  def spans(chars, starts, ends)
    out = []
    current = nil
    chars.each_with_index do |ch, i|
      if ch.match?(/\s/)
        out << current if current
        current = nil
        next
      end
      current ||= { text: +'', start_ms: ms(starts[i]) }
      current[:text] << ch
      current[:end_ms] = ms(ends[i])
    end
    current ? out << current : out
  end

  def ms(seconds) = (seconds.to_f * 1000).round

  # start_ms of the nth occurrence of word, or Missing naming the nearest
  # words the narration does say.
  def at(words, word, nth = 1)
    key = normalize(word)
    hit = words.find { |w| w[:word] == key && w[:nth] == nth }
    return hit[:start_ms] if hit

    count = words.count { |w| w[:word] == key }
    raise Missing, "#{word.inspect} is said #{count} time(s), so nth #{nth} does not exist" if count.positive?

    raise Missing, "#{word.inspect} is not in the narration; nearest: #{nearest(words, key).join(', ')}"
  end

  def nearest(words, key)
    words.map { |w| w[:word] }.uniq.min_by(CANDIDATES) { |w| [ DidYouMean::Levenshtein.distance(key, w), w ] }
  end
end
