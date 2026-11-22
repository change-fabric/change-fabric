# frozen_string_literal: true

require_relative 'change_flow_selector'
require_relative 'change_flake_triage'

# Suggest-only selector help. When a step's wait times out on a selector that
# matches nothing, the flow runtime hands back raw facts about the elements
# that are there (see `cfCandidates` in ChangeFlowCompiler). This turns them
# into at most three replacement selectors for a human to read.
#
# A suggestion never changes a status: the case still fails. Nothing here
# writes a selector into a suite, and `steps[].alt` is not a thing; a fallback
# is only ever authored by a person.
#
# Page text is untrusted and can hold a secret, so every value that reaches a
# result goes through `safe`: the case's own secret values masked first,
# control characters dropped, credential shapes and long opaque tokens
# redacted, then clipped. The raw candidate list is never kept.
module ChangeSelectorSuggestions
  TOP = 3
  CLIP = 80
  REDACTED = '[redacted]'
  PIERCE = 'pierce/'
  OPAQUE = /\b(?=[\w-]*\d)(?=[\w-]*[a-zA-Z])[\w-]{24,}\b/
  # An id a framework made up (`:r1:`, `ember123`, uuid, long hex or digits)
  # is not stable across runs.
  GENERATED_ID = /\A(?::|.*\d{3,}|.*\h{8,}|(?:ember|react|radix|headlessui|mui)[-:\w]*\d)/i
  # Base stability of each way to name an element, before uniqueness and
  # relevance adjust it.
  STABILITY = { 'testid' => 0.9, 'id' => 0.8, 'label' => 0.7, 'text' => 0.5 }.freeze

  CRED_NAME = 'token|secret|passw(?:or)?d|pwd|passphrase|api[_-]?key|access[_-]?key|private[_-]?key|credential|session[_-]?id|authorization|cookie|bearer'
  # A credential key, its separator, then a value: triple-quoted, quoted
  # (through the closing quote, escapes and doubled quotes honored, spaces
  # kept) or bare to the end of the line.
  CRED_PAIR = /(["']?\w{0,40}(?:#{CRED_NAME})\w{0,40}["']?\s*[:=]\s*)("{3}.*?(?:"{3}|\z)|'{3}.*?(?:'{3}|\z)|"(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.|'')*'?|[^\n]*)/i
  CRED_HEADER = /\b(?:set-)?cookie\s*[:=][^\n]*|\bauthorization\s*[:=][^\n]*|\b(?:bearer|basic)\s+[\w.~+\/=-]{8,}/i
  UNCLOSED = /(?:#{CRED_NAME})\w{0,40}["']?\s*[:=]\s*("{3}|'{3}|"|')(?:(?!\1)[^\\]|\\.)*\\?\z/i
  EMPTY_OR_BLOCK = /[:=]\s*(?:[|>][+-]?)?\s*\z/
  URL_USERINFO = %r{(\b[a-z][a-z0-9+.-]*://)[^/\s]*@}i
  PRIVATE_KEY = /-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----.*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|\z)/m
  INTERPOLATION = /\$\{[^}]*\}/

  Suggestion = Struct.new(:selector, :kind, :score, :matches, keyword_init: true)

  module_function

  # Line-oriented masking, before any clipping. Keeps line breaks so a caller
  # can mask a whole diff. A value is masked through its closing quote, so
  # `"password": "a b c"` loses every word. A quote left open on a line masks
  # the lines after it until it closes, a block scalar (`key: |`) masks its
  # indented lines, and a private key block, a credential header, an auth
  # scheme, URL userinfo and `${...}` are masked wherever they appear.
  def mask(value, secrets: [])
    text = value.to_s.dup.scrub
    secrets.map(&:to_s).reject { |secret| secret.length < 3 }.sort_by { |secret| -secret.length }.each do |secret|
      text = text.gsub(secret, REDACTED)
    end
    text = text.gsub(PRIVATE_KEY, REDACTED).gsub(URL_USERINFO) { "#{Regexp.last_match(1)}#{REDACTED}@" }
    open_quote = nil
    block_indent = nil
    first = false
    text.split("\n", -1).map do |line|
      indent = line[/\A[ \t]*/].length
      if block_indent && (line.strip.empty? || indent > block_indent || first || (indent == block_indent && line.lstrip.start_with?('- ')))
        first &&= line.strip.empty?
        REDACTED
      elsif open_quote
        quote = open_quote
        closed = line.index(/(?<!\\)#{Regexp.escape(quote)}/)
        open_quote = nil if closed
        closed ? "#{REDACTED}#{mask_line(line[(closed + quote.length)..])}" : REDACTED
      else
        block_indent = nil
        masked = mask_line(line)
        open_quote = line[UNCLOSED, 1]
        block_indent = indent if (first = masked != line && line.match?(EMPTY_OR_BLOCK))
        masked
      end
    end.join("\n")
  end

  def mask_line(line)
    line.gsub(CRED_HEADER, REDACTED).gsub(CRED_PAIR) { "#{Regexp.last_match(1)}#{REDACTED}" }.gsub(INTERPOLATION, REDACTED)
  end

  # One shared clip-and-redact for anything from the page, the env or the
  # case. `secrets` are exact values to mask wherever they appear.
  def safe(value, secrets: [], max: CLIP)
    text = mask(value, secrets: secrets)
    text = text.gsub(/[[:cntrl:]]/, ' ').gsub(OPAQUE, REDACTED).gsub(ChangeFlakeTriage::SECRET, REDACTED)
    text = text.squeeze(' ').strip
    text.length > max ? "#{text[0, max]}..." : text
  end

  # `raw` is a step record's `candidates` hash (or nil). Returns the entry for
  # the case result's `selector_suggestions`, or nil when the step has nothing
  # to suggest about (no selector, or the runtime gathered nothing).
  def build(step_index:, selector:, raw:, secrets: [])
    return nil unless raw.is_a?(Hash) && selector.is_a?(String) && !selector.strip.empty?

    items = Array(raw['items']).grep(Hash)
    candidates = items.select { |item| item['scope'] != 'frame' }.map { |item| scrub(item, secrets) }
    ranked = rank(candidates, hints(selector))
    { 'step' => Integer(step_index), 'failed' => safe(selector, secrets: secrets, max: 120),
      'candidates' => ranked.filter_map { |entry| describe(entry, secrets) }.first(TOP),
      'note' => note(items, ranked, raw) }
  rescue ArgumentError, TypeError
    nil
  end

  # Masking happens on the whole value, before any clipping: a field the
  # redaction would change (a secret, a token) is dropped from the candidate.
  def scrub(item, secrets)
    item.to_h { |key, value| [ key, value.is_a?(String) && safe(value, secrets: secrets, max: 200) != value ? nil : value ] }
  end

  def note(items, ranked, raw)
    parts = []
    parts << 'the page had no matching elements to suggest' if items.empty?
    parts << 'no valid candidate selector' if items.any? && ranked.empty?
    frames = raw['frames'].to_i
    parts << "#{frames} iframe(s) not searched" if frames.positive?
    parts << 'search was truncated' if raw['truncated']
    parts.empty? ? nil : parts.join('; ')
  end

  # What the failed selector says about the element it wanted: its tag, the
  # words in its ids, classes and attribute values, and any text.
  def hints(selector)
    plain = selector.delete_prefix(PIERCE)
    tag = plain[/\A[a-z][a-z0-9-]*/]
    words = plain.scan(/[A-Za-z][A-Za-z0-9]+/).map(&:downcase).uniq - %w[text has is nth pierce]
    { tag: tag, words: words }
  end

  # Candidate selectors for every element, deduplicated by selector (the same
  # selector from two elements is one suggestion with a larger `matches`),
  # scored, and ordered best first with the selector as the tie-break so the
  # same page always gives the same answer.
  def rank(items, hint)
    found = {}
    seen = Hash.new(0)
    items.each do |item|
      forms(item).each do |selector, kind, count|
        entry = (found[selector] ||= Suggestion.new(selector: selector, kind: kind, score: 0.0, matches: 0))
        seen[selector] += 1
        entry.matches = [ entry.matches, count, seen[selector] ].max
        entry.score = [ entry.score, score(item, kind, hint) ].max
      end
    end
    found.values.each { |entry| entry.score *= 0.3 if entry.matches > 1 }
    found.values.sort_by { |entry| [ -entry.score, entry.selector ] }
  end

  # [selector, kind, how many elements it matches] per way to name the item.
  # A selector this grammar would refuse is dropped, never offered.
  def forms(item)
    prefix = item['scope'] == 'shadow' ? PIERCE : ''
    tag = item['tag'].to_s[/\A[a-z][a-z0-9-]*\z/] || '*'
    out = []
    out << [ "#{prefix}[data-testid=#{quote(item['testid'])}]", 'testid', item['testidCount'].to_i ] if exact?(item['testid'])
    out << [ "#{prefix}##{item['id']}", 'id', item['idCount'].to_i ] if usable_id?(item['id'])
    out << [ "#{prefix}#{tag}[aria-label=#{quote(item['label'])}]", 'label', 1 ] if exact?(item['label'])
    out << [ "#{prefix}#{tag}:has-text(#{quote(item['text'][0, CLIP])})", 'text', 1 ] if present?(item['text']) && prefix.empty? && tag != '*'
    out.select { |selector, _, _| valid?(selector) }
  end

  def present?(value) = value.is_a?(String) && !value.strip.empty?

  # An attribute value that is safe to match exactly: no edge whitespace or
  # control characters to normalize away.
  def exact?(value) = present?(value) && value == value.strip && !value.match?(/[[:cntrl:]]/)

  def usable_id?(id) = present?(id) && id.match?(/\A[A-Za-z_][\w-]*\z/) && !id.match?(GENERATED_ID)

  def quote(value) = "\"#{value.to_s.gsub(/[\\"]/) { |char| "\\#{char}" }}\""

  def valid?(selector)
    ChangeFlowSelector.locator(selector)
    true
  rescue ChangeFlowSelector::Error
    false
  end

  def score(item, kind, hint)
    base = STABILITY.fetch(kind)
    haystack = [ item['id'], item['testid'], item['label'], item['text'] ].compact.join(' ').downcase
    shared = hint[:words].count { |word| haystack.include?(word) }
    base + (hint[:tag] && hint[:tag] == item['tag'] ? 0.2 : 0.0) + [ shared, 3 ].min * 0.1
  end

  # The reader-facing candidate. A selector the redaction would alter held a
  # secret or an opaque token; it is dropped, not shown mangled.
  def describe(entry, secrets)
    shown = safe(entry.selector, secrets: secrets, max: 160)
    return nil unless shown == entry.selector

    { 'selector' => shown, 'by' => entry.kind,
      'matches' => entry.matches, 'score' => entry.score.round(2) }
  end

  private_class_method :note, :hints, :rank, :forms, :present?, :usable_id?, :quote, :valid?, :score, :describe
end
