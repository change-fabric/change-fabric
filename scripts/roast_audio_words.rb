# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require_relative 'cf_provider_error'
require_relative 'roast' unless defined?(Roast::Cli)
require_relative 'roast_audio_ledger'
require_relative 'roast_vtt'
require_relative 'walkthrough_captions'
require_relative 'walkthrough_env'

# The word check of cf:roast --audio: what was spoken against the captions.
# A bound ElevenLabs alignment (its sidecar ties it to these exact audio bytes
# and to its own content) gives the heard words with times, so cue word
# boundaries are checked to +/-250 ms. Without one, the gated clip is
# transcribed once by gpt-transcribe (no caption hint, so the captions cannot
# steer what is heard), the reply is cached by audio and model, and timing is
# reported unverified. Either way a normalized LCS word diff yields ops with
# stable ids mapped to cues, and a rebuttal file can excuse a substitution
# only with checkable evidence.
module RoastAudioWords
  TRANSCRIBE_URL = 'https://api.openai.com/v1/audio/transcriptions'
  TRANSCRIBE_MODEL = 'gpt-transcribe'
  TIMING_TOLERANCE_MS = 250
  KINDS = %w[missing extra substituted cue_timing].freeze
  REASONS = %w[proper_noun number_format homophone].freeze
  HOMOPHONES = [ %w[their there], %w[their they're], %w[there they're], %w[to too], %w[to two], %w[too two], %w[its it's],
                 %w[your you're], %w[whose who's], %w[then than], %w[affect effect], %w[break brake], %w[right write],
                 %w[weather whether], %w[for four], %w[by buy], %w[hear here], %w[know no], %w[new knew], %w[one won],
                 %w[sight site], %w[cite site], %w[peak peek], %w[principal principle], %w[stationary stationery] ].map(&:sort).freeze
  ONES = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen].freeze
  TENS = %w[_ _ twenty thirty forty fifty sixty seventy eighty ninety].freeze

  class WordsError < StandardError; end

  module_function

  # ---- provenance ----------------------------------------------------------

  # Sorted-key JSON, so a hash of it does not depend on key order.
  def canonical(value)
    case value
    when Hash then "{#{value.keys.map(&:to_s).sort.map { |k| "#{JSON.generate(k)}:#{canonical(value.key?(k) ? value[k] : value[k.to_sym])}" }.join(',')}}"
    when Array then "[#{value.map { |v| canonical(v) }.join(',')}]"
    else JSON.generate(value)
    end
  end

  def sha256(value) = Digest::SHA256.hexdigest(canonical(value))

  # { status: 'verified'|'unbound'|'mismatch'|'absent', alignment:, generator: }.
  # Verified needs a sidecar whose audio_sha256 is the given audio's digest and
  # whose alignment_sha256 is the digest of its own alignment's canonical JSON.
  # A bare alignment JSON (no binding) is unbound.
  def provenance(path, audio_sha256:)
    return { status: 'absent' } unless path && File.file?(path)

    data = JSON.parse(File.read(path))
    return { status: 'unbound' } unless data.is_a?(Hash) && data['alignment'].is_a?(Hash) && data['audio_sha256']
    return { status: 'mismatch', reason: 'audio_sha256 is not this audio' } unless data['audio_sha256'] == audio_sha256
    return { status: 'mismatch', reason: 'alignment_sha256 does not match its alignment' } unless data['alignment_sha256'] == sha256(data['alignment'])

    { status: 'verified', alignment: data['alignment'], generator: data['generator'] }
  rescue JSON::ParserError
    { status: 'unbound', reason: 'alignment file is not JSON' }
  end

  # Word spans from a verified alignment, shifted by the gate's trim delta.
  def spans(alignment, offset_ms: 0) = WalkthroughCaptions.word_spans(alignment, offset_ms: offset_ms)

  # ---- normalize and diff ----------------------------------------------------

  def number_words(n)
    return ONES[n] if n < 20
    return [ TENS[n / 10], n % 10 > 0 ? ONES[n % 10] : nil ].compact.join(' ') if n < 100
    return [ ONES[n / 100], 'hundred', n % 100 > 0 ? number_words(n % 100) : nil ].compact.join(' ') if n < 1000
    return [ number_words(n / 1000), 'thousand', n % 1000 > 0 ? number_words(n % 1000) : nil ].compact.join(' ') if n < 1_000_000

    n.to_s
  end

  # Downcased tokens with punctuation stripped, quotes straightened, hyphens
  # as spaces, and digits spelled out, so "Twenty-one" and "21" agree.
  def tokens(text)
    text.to_s.downcase.tr("‘’“”", %q(''"")).gsub(/[‐-―-]/, ' ')
        .gsub(/(\d),(\d{3})/, '\1\2').gsub(/\d+/) { |d| " #{number_words(d.to_i)} " }
        .gsub(/[^a-z0-9' ]/, ' ').split.map { |t| t.gsub(/\A'+|'+\z/, '') }.reject(&:empty?)
  end

  # Expected words from cues: [{ word:, cue: }].
  def expected(cues) = cues.flat_map { |c| tokens(c.text).map { |w| { word: w, cue: c.index } } }

  # Heard words: [{ word:, start_ms:, end_ms: }] (times nil from a transcript).
  def heard_from_spans(spans) = spans.flat_map { |s| tokens(s[:text]).map { |w| { word: w, start_ms: s[:start_ms], end_ms: s[:end_ms] } } }

  def heard_from_text(text) = tokens(text).map { |w| { word: w, start_ms: nil, end_ms: nil } }

  # LCS alignment as [[:eq|:del|:ins, exp_index, heard_index], ...].
  def align(exp, heard)
    n = exp.size
    m = heard.size
    t = Array.new(n + 1) { Array.new(m + 1, 0) }
    (n - 1).downto(0) do |i|
      (m - 1).downto(0) do |j|
        t[i][j] = exp[i][:word] == heard[j][:word] ? t[i + 1][j + 1] + 1 : [ t[i + 1][j], t[i][j + 1] ].max
      end
    end
    out = []
    i = j = 0
    while i < n || j < m
      if i < n && j < m && exp[i][:word] == heard[j][:word] then out << [ :eq, i, j ]; i += 1; j += 1
      elsif j < m && (i == n || t[i][j + 1] >= t[i + 1][j]) then out << [ :ins, nil, j ]; j += 1
      else out << [ :del, i, nil ]; i += 1
      end
    end
    out
  end

  # Word ops from the alignment: a run of deletions and insertions between
  # matches pairs up as substitutions, the rest stay missing or extra.
  def diff(exp, heard, cues)
    by_index = cues.to_h { |c| [ c.index, c ] }
    ops = []
    steps = align(exp, heard)
    steps.chunk_while { |a, b| a[0] != :eq && b[0] != :eq }.each do |run|
      next if run.first[0] == :eq

      dels = run.select { |s| s[0] == :del }.map { |s| exp[s[1]] }
      inss = run.select { |s| s[0] == :ins }.map { |s| heard[s[2]] }
      anchor = dels.first || nearest_expected(steps, run, exp)
      dels.zip(inss).each { |d, h| ops << op(h ? 'substituted' : 'missing', d, h, by_index) }
      inss.drop(dels.size).each { |h| ops << op('extra', anchor, h, by_index) }
    end
    ops
  end

  def nearest_expected(steps, run, exp)
    before = steps.take_while { |s| !s.equal?(run.first) }.reverse.find { |s| s[1] }
    after = steps.drop_while { |s| !s.equal?(run.last) }.find { |s| s[1] }
    exp[(before || after)&.at(1) || 0]
  end

  def op(kind, exp, heard, by_index)
    cue = exp ? exp[:cue] : by_index.keys.first
    at = heard&.dig(:start_ms) || by_index[cue]&.start_ms || 0
    { 'kind' => kind, 'cue' => cue, 'at' => RoastVtt.mmss(at), 'expected' => kind == 'extra' ? nil : exp[:word], 'heard' => heard&.dig(:word) }
  end

  # cue_timing ops: with timed heard words, a cue's first and last matched
  # words must sit within the tolerance of its start and end.
  def timing(exp, heard, cues)
    matched = align(exp, heard).select { |s| s[0] == :eq }
    cues.flat_map do |c|
      pairs = matched.select { |_, i, _| exp[i][:cue] == c.index }
      next [] if pairs.empty?

      first = heard[pairs.first[2]]
      last = heard[pairs.last[2]]
      out = []
      out << timing_op(c, 'start', c.start_ms, first[:start_ms], first[:word]) if pairs.first[1] == exp.index { |e| e[:cue] == c.index } && (first[:start_ms] - c.start_ms).abs > TIMING_TOLERANCE_MS
      out << timing_op(c, 'end', c.end_ms, last[:end_ms], last[:word]) if pairs.last[1] == exp.rindex { |e| e[:cue] == c.index } && (last[:end_ms] - c.end_ms).abs > TIMING_TOLERANCE_MS
      out
    end
  end

  def timing_op(cue, edge, cue_ms, word_ms, word)
    { 'kind' => 'cue_timing', 'cue' => cue.index, 'at' => RoastVtt.mmss(cue_ms), 'expected' => "#{edge} #{RoastVtt.mmss(cue_ms)}",
      'heard' => "#{word} at #{RoastVtt.mmss(word_ms)} (#{word_ms - cue_ms} ms)" }
  end

  # Stable ids: identical tuples are told apart by their ordinal, in order.
  def with_ids(ops)
    seen = Hash.new(0)
    ops.map do |o|
      tuple = o.values_at('kind', 'cue', 'expected', 'heard').join('|')
      ordinal = seen[tuple]
      seen[tuple] += 1
      { 'id' => Digest::SHA256.hexdigest("#{tuple}|#{ordinal}")[0, 12] }.merge(o)
    end
  end

  # ---- rebuttals ---------------------------------------------------------------

  # [valid rebuttals, warnings]. A rebuttal counts only when its inputs are
  # the current audio and captions, its op exists, its reason is allowed for
  # that op, and its evidence checks out.
  def rebuttals(path, ops:, source:, source_id:, inputs:, brief:, pronunciations: {})
    return [ [], [] ] unless path && File.file?(path)

    data = JSON.parse(File.read(path))
    stale = data['source_id'] != source_id || data['inputs'] != inputs
    by_id = ops.to_h { |o| [ o['id'], o ] }
    valid = []
    warnings = []
    Array(data['rebuttals']).each do |r|
      problem = rebuttal_problem(r, by_id[r['op_id']], source, stale, brief, pronunciations)
      problem ? warnings << "rebuttal #{r['op_id']} ignored: #{problem}" : valid << r.slice('op_id', 'reason', 'evidence')
    end
    [ valid, warnings ]
  rescue JSON::ParserError
    [ [], [ "rebuttal file #{path} is not JSON; ignored" ] ]
  end

  def rebuttal_problem(rebuttal, op, source, stale, brief, pronunciations)
    return 'its inputs are not the current audio and captions' if stale
    return 'unknown op id' unless op
    return "#{op['kind']} ops cannot be rebutted" unless op['kind'] == 'substituted'
    return 'ops from bound alignment cannot be rebutted' unless source == 'transcribe'
    return "reason must be one of #{REASONS.join(', ')}" unless REASONS.include?(rebuttal['reason'])

    evidence_problem(rebuttal['reason'], rebuttal['evidence'].to_s, op, brief, pronunciations)
  end

  def evidence_problem(reason, evidence, op, brief, pronunciations)
    case reason
    when 'proper_noun'
      term = op['expected']
      named = pronunciations.keys.any? { |k| tokens(k).include?(term) } || brief.to_s.lines.any? { |l| tokens(l).include?(term) }
      return "#{term.inspect} is not a manifest pronunciation key or spelled in the brief" unless named
      return "evidence does not name #{term.inspect}" unless tokens(evidence).include?(term)
    when 'number_format'
      a, b = evidence.split('=', 2).map(&:strip)
      return 'evidence must give both written forms as "A = B"' unless a && b && !a.empty? && !b.empty?
      return 'the two forms do not normalize equal' unless tokens(a) == tokens(b)
      covered = tokens(a) | tokens(b)
      return 'the forms must account for both the expected and the heard word' unless covered.include?(op['expected']) && covered.include?(op['heard'])
    when 'homophone'
      pair = evidence.split(%r{[/,]}).map { |w| tokens(w).first }.compact.sort
      return 'evidence must give the pair as "a/b"' unless pair.size == 2
      return 'the pair is not this op' unless pair == [ op['expected'], op['heard'] ].sort
      return 'not a known homophone pair' unless HOMOPHONES.include?(pair)
    end
    nil
  end

  # ---- transcription -------------------------------------------------------------

  def cache_path(clip_dir, audio_sha256, model) = File.join(clip_dir, 'cache', "transcribe-#{audio_sha256}-#{model}.json")

  def transcribe_bound(duration_s, model: TRANSCRIBE_MODEL) = RoastAudioLedger.bound('transcribe', model: model, duration_s: duration_s)

  # The cached provider reply, or one paid call through the ledger. The raw
  # reply is all the cache holds, so captions, rebuttals and the brief never
  # invalidate it.
  def transcript(audio, audio_sha256:, duration_s:, clip_dir:, ledger:, id:, http: nil, model: TRANSCRIBE_MODEL, round: nil)
    path = cache_path(clip_dir, audio_sha256, model)
    return JSON.parse(File.read(path)) if File.file?(path)

    body = ledger.spend('transcribe', transcribe_bound(duration_s, model: model), clip: id, round: round) do
      [ post_transcription(audio, model, http), { 'seconds' => duration_s } ]
    end
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(body))
    body
  end

  # Called only from inside ledger.spend. No prompt is sent: a caption hint
  # would bias the transcript toward the text it is checked against.
  def post_transcription(audio, model, http)
    uri = URI(TRANSCRIBE_URL)
    begin
      key = WalkthroughEnv.openai_key!
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{key}"
      req.set_form([ [ 'model', model ], [ 'response_format', 'json' ], [ 'file', File.open(audio, 'rb'), { filename: File.basename(audio) } ] ], 'multipart/form-data')
    rescue StandardError
      raise RoastAudioLedger::PreDispatch, 'transcription request not sent'
    end
    response = Roast.transport { (http || Roast.default_http(uri)).request(req) }
    failure = CfProviderError.from_response(provider: 'openai', response: response, key: key)
    raise failure if failure

    body = JSON.parse(response.body)
    raise WordsError, 'transcription reply has no text' unless body['text'].is_a?(String)

    body
  end

  # ---- the check -----------------------------------------------------------------

  # Builds words.json for a clip from its passing gate record. alignment:
  # provenance's result for the clip's current alignment.
  def check(gate:, alignment:, clip_dir:, id:, ledger:, response_file:, brief:, pronunciations: {}, http: nil)
    raise WordsError, 'the word check needs a passing gate' unless gate['status'] == 'pass'

    cues = RoastVtt.parse_file(gate['output']['vtt'])
    inputs = { 'audio_sha256' => gate['deps']['audio_sha256'], 'vtt_sha256' => gate['deps']['vtt_sha256'] }
    exp = expected(cues)
    if alignment[:status] == 'verified'
      heard = heard_from_spans(spans(alignment[:alignment], offset_ms: gate.dig('derived_from', 'trim_delta_ms').to_i))
      source = 'alignment'
      raw = diff(exp, heard, cues) + timing(exp, heard, cues)
    else
      out = gate['output']
      body = transcript(out['audio'], audio_sha256: out['audio_sha256'], duration_s: gate.dig('measurements', 'output', 'duration_s') || gate.dig('measurements', 'source', 'duration_s'),
                                      clip_dir: clip_dir, ledger: ledger, id: id, http: http)
      heard = heard_from_text(body['text'])
      source = 'transcribe'
      raw = diff(exp, heard, cues)
    end
    ops = with_ids(raw)
    valid, warnings = rebuttals(response_file, ops: ops, source: source, source_id: id, inputs: inputs, brief: brief, pronunciations: pronunciations)
    rebutted = valid.map { |r| r['op_id'] }.uniq
    { 'deps' => gate['deps'].merge('rebuttal_sha256' => sha256(valid)), 'source_id' => id, 'source' => source,
      'timing' => source == 'alignment' ? 'verified' : 'unverified', 'alignment' => alignment[:status],
      'ops' => ops.map { |o| o.merge('rebutted' => rebutted.include?(o['id'])) },
      'counts' => { 'raw' => ops.size, 'rebutted' => rebutted.size, 'accepted' => ops.size - rebutted.size }, 'warnings' => warnings }
  end

  private_class_method :nearest_expected, :op, :timing_op, :rebuttal_problem, :evidence_problem, :post_transcription
end
