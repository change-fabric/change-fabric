# frozen_string_literal: true

require_relative 'change_schema'

# Deterministic kind inference for cf:roast, used only when no source (flag,
# storyboard review, CHANGE.md) names a kind. Cheap cues first: a storyboard
# reads as explainer, promo, or demo by its narration; a text reads as email,
# pr, post, or doc by its shape. One cue-bearing candidate is an inference with
# a confidence (high for a strong cue, medium for a weak one). Zero or several
# candidates are ambiguous: it raises instead of guessing.
module RoastKind
  Inference = Struct.new(:kind, :confidence, :reason)

  class Ambiguous < StandardError
    attr_reader :candidates

    def initialize(candidates)
      @candidates = candidates
      super("roast: kind is ambiguous: candidates #{candidates.join(', ')}; pass --kind")
    end
  end

  VIDEO_KINDS = %w[explainer promo demo].freeze
  TEXT_KINDS = %w[email doc pr post].freeze
  PROMO_CUES = /\b(get started|sign up|start (?:your )?free|try it (?:free|today)|book a demo|download|install|buy|subscribe|pricing)\b/i
  DEMO_CUES = /\b(click|tap|type|press|drag|select|watch it|running|live)\b/i
  EMAIL_HEADER = /\A\s*(?:subject|to|from|cc|date):/i
  EMAIL_GREETING = /\A\s*(?:hi|hello|hey|dear|good (?:morning|afternoon))\b/i
  PR_STRONG = /^\#{1,3}\s*(?:test plan|testing|how (?:was this|to) test(?:ed)?)\b|\b(?:closes|fixes|resolves)\s+\#\d+/i
  PR_WEAK = /^\#{1,3}\s*(?:summary|changes|what changed|motivation)\b/i
  POST_STRONG = /(?:^|\s)\#[a-z]\w+|(?:^|\s)@\w+/
  DOC_WEAK = /^\#{1,2}\s+\S.*(?:\n.*)*?^\#{2,3}\s+\S/

  module_function

  # The single Inference, nil when only image inputs carry no cue at all, or
  # raises Ambiguous. `texts` are the file contents paired with their paths.
  def infer(storyboard: nil, texts: [])
    verdicts = []
    verdicts << board_verdict(storyboard) if storyboard
    verdicts.concat(texts.map { |path, body| text_verdict(path, body) })
    return nil if verdicts.empty?

    merge(verdicts)
  end

  def merge(verdicts)
    kinds = verdicts.flat_map(&:first).uniq
    sure = verdicts.map { |v| v.first.size == 1 }.all?
    raise Ambiguous, kinds unless sure && kinds.size == 1

    Inference.new(kinds.first, verdicts.map { |v| v[1] }.include?('medium') ? 'medium' : 'high', verdicts.map(&:last).join('; '))
  end

  # [candidates, confidence, reason] from a storyboard's narration.
  def board_verdict(board)
    scenes = board.is_a?(Hash) ? Array(board['scenes']) : []
    spoken = scenes.map { |s| s.is_a?(Hash) ? (s.dig('narration', 'text') || s['narration']).to_s : '' }.join(' ')
    found = []
    found << 'promo' if spoken.match?(PROMO_CUES)
    found << 'demo' if spoken.match?(DEMO_CUES)
    return [ VIDEO_KINDS, 'low', 'storyboard has no promo or demo cue' ] if found.empty?

    [ found, 'medium', "storyboard narration reads as #{found.join(' and ')}" ]
  end

  def text_verdict(path, body)
    text = body.to_s
    strong = strong_kinds(path, text)
    return [ strong, 'high', "#{File.basename(path)} has a strong #{strong.join(' and ')} cue" ] unless strong.empty?

    weak = weak_kinds(text)
    return [ weak, 'medium', "#{File.basename(path)} reads as #{weak.join(' or ')}" ] unless weak.empty?

    [ TEXT_KINDS, 'low', "#{File.basename(path)} has no kind cue" ]
  end

  def strong_kinds(path, text)
    found = []
    found << 'email' if File.extname(path.to_s).casecmp('.eml').zero? || text.match?(EMAIL_HEADER)
    found << 'pr' if text.match?(PR_STRONG)
    found << 'post' if found.empty? && text.match?(POST_STRONG) && text.size <= 3000 && !text.match?(/^\#{1,6}\s/)
    found
  end

  def weak_kinds(text)
    found = []
    found << 'email' if text.match?(EMAIL_GREETING)
    found << 'pr' if text.match?(PR_WEAK)
    found << 'doc' if text.match?(DOC_WEAK) && found.empty?
    found
  end
end
