# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require_relative 'elevenlabs'

# The one spend contract for cf:roast --audio. Every paid call (judge,
# transcription, calibration probe, re-voice) reserves an upper bound in
# DIR/spend.json before it runs and settles its real cost after; nothing else
# authorizes a call, and an estimate never does. Every operation takes an
# exclusive flock on DIR/spend.lock, a file that is never renamed or replaced,
# then re-reads spend.json, writes spend.json.tmp, fsyncs it and renames it
# over spend.json. A call that settles above its reservation halts the batch
# until a human recalibrates and clears `halted`. An unreadable spend.json
# reads as the cap reached.
class RoastAudioLedger
  # USD per 1M tokens, standard tier, https://developers.openai.com/api/docs/pricing (checked 2026-11-18).
  AUDIO_PRICES = {
    'gpt-audio-1.5' => { audio_in: 32.0, text_in: 2.5, text_out: 10.0 },
    'gpt-audio-mini' => { audio_in: 10.0, text_in: 0.6, text_out: 2.4 }
  }.freeze
  # USD per minute of audio, https://developers.openai.com/api/docs/pricing (checked 2026-11-18):
  # "gpt-transcribe | Transcription | - | - | $0.0045 / minute". Billed by the
  # minute, so the bound rounds the clip up to whole minutes.
  TRANSCRIBE_USD_PER_MINUTE = { 'gpt-transcribe' => 0.0045 }.freeze
  # Audio tokens per second of input. Calibrated 2026-11-18 on gpt-audio-1.5:
  # one probe of a 0.549 s mp3 billed 5 audio tokens (9.1/s); rounded up to 10
  # because usage counts whole tokens. Judge reservations use twice this.
  MEASURED_AUDIO_TOKENS_PER_SECOND = 10.0
  # The judge reserves this multiple of the measured rate.
  AUDIO_RATE_MARGIN = 2
  # The calibration probe's only pre-calibration bound: an assumed worst case.
  PROBE_TOKENS_PER_SECOND = 1000
  PROBE_MAX_OUTPUT_TOKENS = 16
  MAX_OUTPUT_TOKENS = 4000
  # Chat formatting tokens around the messages, on top of the text bytes.
  MESSAGE_OVERHEAD_TOKENS = 64
  OPS = %w[judge transcribe probe regen].freeze
  COUNTED = %w[settled reserved uncertain].freeze

  class UnboundedCost < StandardError; end
  class Refused < StandardError; end
  # Raised inside a spend block for a failure before the request left (a
  # missing key, a request build error): the reservation is released and the
  # original error (its cause) is re-raised.
  class PreDispatch < StandardError; end

  attr_reader :dir, :cap_usd, :max_usd

  def initialize(dir, cap_usd:, max_usd:)
    @dir = dir
    @cap_usd = cap_usd
    @max_usd = max_usd
  end

  # ElevenLabs USD per 1K characters: the same rate ElevenLabs.estimate uses.
  def self.regen_rate(model) = ElevenLabs::TTS_USD_PER_1K[model.to_s.include?('flash') || model.to_s.include?('turbo') ? :flash : :multilingual]

  # { usd:, basis: } for one call, or UnboundedCost when a rate or quantity is unknown.
  def self.bound(op, **basis)
    case op
    when 'judge' then judge_bound(basis)
    when 'probe' then probe_bound(basis)
    when 'transcribe' then transcribe_bound(basis)
    when 'regen' then regen_bound(basis)
    else raise UnboundedCost, "unknown paid operation #{op.inspect}"
    end
  end

  # The calibrated rate, a method so tests can stand one in.
  def self.measured_rate = MEASURED_AUDIO_TOKENS_PER_SECOND

  # Text is bounded at one token per UTF-8 byte (a token always covers at
  # least one byte) plus the message overhead, at the text input rate it is
  # billed at. Audio is bounded at twice the measured rate.
  def self.judge_bound(basis)
    price = AUDIO_PRICES[basis[:model]] or raise UnboundedCost, "no price for #{basis[:model].inspect}; refusing an unbounded call"
    rate = measured_rate or raise UnboundedCost, 'no measured audio token rate yet (MEASURED_AUDIO_TOKENS_PER_SECOND); refusing an unbounded judge call'
    duration = known!(basis, :duration_s)
    audio = (duration * AUDIO_RATE_MARGIN * rate).ceil
    text = known!(basis, :prompt_bytes) + MESSAGE_OVERHEAD_TOKENS
    output = basis[:max_output_tokens] || MAX_OUTPUT_TOKENS
    usd = ((audio * price[:audio_in]) + (text * price[:text_in]) + (output * price[:text_out])) / 1e6
    { usd: usd.round(6), basis: basis.merge(provider: 'openai', audio_tokens: audio, text_tokens: text, output_tokens: output) }
  end

  def self.probe_bound(basis)
    price = AUDIO_PRICES.fetch('gpt-audio-1.5')
    audio = (known!(basis, :duration_s) * PROBE_TOKENS_PER_SECOND).ceil
    text = known!(basis, :prompt_bytes) + MESSAGE_OVERHEAD_TOKENS
    usd = ((audio * price[:audio_in]) + (text * price[:text_in]) + (PROBE_MAX_OUTPUT_TOKENS * price[:text_out])) / 1e6
    { usd: usd.round(6), basis: basis.merge(provider: 'openai', model: 'gpt-audio-1.5', audio_tokens: audio, text_tokens: text, output_tokens: PROBE_MAX_OUTPUT_TOKENS) }
  end

  def self.transcribe_bound(basis)
    rate = TRANSCRIBE_USD_PER_MINUTE[basis[:model]] or raise UnboundedCost, "no transcription price for #{basis[:model].inspect}; refusing an unbounded call"
    minutes = (known!(basis, :duration_s) / 60.0).ceil
    { usd: (minutes * rate).round(6), basis: basis.merge(provider: 'openai', minutes: minutes) }
  end

  def self.regen_bound(basis)
    chars = known!(basis, :chars)
    { usd: (chars / 1000.0 * regen_rate(basis[:model])).round(6), basis: basis.merge(provider: 'elevenlabs') }
  end

  def self.known!(basis, key)
    value = basis[key]
    raise UnboundedCost, "unknown #{key}; refusing an unbounded call" unless value.is_a?(Numeric) && value.finite? && !value.negative?

    value
  end

  # Real cost from the same basis and the provider's usage. nil when usage
  # is missing, which leaves the entry uncertain.
  def self.actual(entry, usage)
    basis = entry['basis'].transform_keys(&:to_sym)
    case entry['op']
    when 'judge', 'probe' then tokens_usd(basis, usage)
    when 'transcribe' then (basis[:minutes] * TRANSCRIBE_USD_PER_MINUTE.fetch(basis[:model])).round(6)
    when 'regen' then entry['reserved_usd']
    end
  end

  def self.tokens_usd(basis, usage)
    return nil unless usage.is_a?(Hash) && usage['prompt_tokens'] && usage['completion_tokens']

    price = AUDIO_PRICES.fetch(basis[:model])
    audio = usage.dig('prompt_tokens_details', 'audio_tokens').to_i
    text = usage['prompt_tokens'].to_i - audio
    ((audio * price[:audio_in]) + (text * price[:text_in]) + (usage['completion_tokens'].to_i * price[:text_out])) / 1e6
  end

  private_class_method :judge_bound, :probe_bound, :transcribe_bound, :regen_bound, :known!, :tokens_usd

  def spend_path = File.join(dir, 'spend.json')
  def lock_path = File.join(dir, 'spend.lock')

  # The data, read under the lock. Raises Refused when unreadable.
  def read = locked { |data| data }

  def committed(data = read) = data['entries'].select { |e| COUNTED.include?(e['status']) }.sum { |e| e['status'] == 'settled' ? e['actual_usd'] : e['reserved_usd'] }

  # Reserves bound (from .bound) for op; returns the entry id, or raises Refused.
  def reserve(op, bound, clip: nil, round: nil)
    raise ArgumentError, "unknown op #{op}" unless OPS.include?(op)

    locked do |data|
      h = data['halted']
      raise Refused, "spend halted: entry #{h['entry']} cost $#{h['actual']} over its $#{h['reserved']} reservation; recalibrate and clear halted in #{spend_path}" if h
      raise Refused, "$#{fmt(bound[:usd])} would pass the $#{fmt(max_usd)} per-call ceiling" if bound[:usd] > max_usd + 1e-9

      used = committed(data)
      raise Refused, "$#{fmt(used)} committed + $#{fmt(bound[:usd])} would pass the $#{fmt(cap_usd)} run cap" if used + bound[:usd] > cap_usd + 1e-9

      id = "e#{data['entries'].size + 1}-#{SecureRandom.hex(3)}"
      data['entries'] << { 'id' => id, 'op' => op, 'clip' => clip, 'round' => round, 'reserved_usd' => bound[:usd], 'actual_usd' => nil,
                           'status' => 'reserved', 'basis' => JSON.parse(JSON.generate(bound[:basis])) }
      id
    end
  end

  # Settles id from usage. Missing usage marks it uncertain; a cost above the
  # reservation halts the batch. Returns the entry.
  def settle(id, usage)
    locked do |data|
      e = entry!(data, id)
      cost = self.class.actual(e, usage)
      if cost.nil?
        e['status'] = 'uncertain'
      else
        e['actual_usd'] = cost.round(6)
        e['status'] = 'settled'
        data['halted'] = { 'entry' => id, 'reserved' => e['reserved_usd'], 'actual' => e['actual_usd'], 'basis' => e['basis'] } if cost > e['reserved_usd'] + 1e-9
      end
      e
    end
  end

  def uncertain(id) = mark(id, 'uncertain')

  # Only for a failure before dispatch: the reservation stops counting.
  def release(id) = mark(id, 'released')

  # Reserve, run the block, settle. The block gets the entry id and returns
  # [result, usage]. A PreDispatch error releases the reservation; any other
  # error leaves it uncertain (counted in full) and re-raises.
  def spend(op, bound, clip: nil, round: nil)
    id = reserve(op, bound, clip: clip, round: round)
    begin
      result, usage = yield(id)
    rescue PreDispatch => e
      release(id)
      raise e.cause || e
    rescue StandardError
      uncertain(id)
      raise
    end
    settle(id, usage)
    result
  end

  private

  def mark(id, status)
    locked do |data|
      entry!(data, id)['status'] = status
    end
  end

  def entry!(data, id) = data['entries'].find { |e| e['id'] == id } || raise(Refused, "no ledger entry #{id}")

  def fmt(usd) = format('%.4f', usd)

  # Exclusive lock on the stable spend.lock, a fresh read, then an atomic
  # replace of spend.json when the block changed it.
  def locked
    FileUtils.mkdir_p(dir)
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      data = load
      before = JSON.generate(data)
      result = yield data
      write(data) unless JSON.generate(data) == before
      result
    end
  end

  def load
    return { 'cap_usd' => cap_usd, 'halted' => nil, 'entries' => [] } unless File.exist?(spend_path)

    data = JSON.parse(File.read(spend_path))
    raise Refused, "#{spend_path} is not a spend ledger; treating the cap as reached" unless data.is_a?(Hash) && data['entries'].is_a?(Array)

    data.merge('cap_usd' => cap_usd)
  rescue JSON::ParserError, SystemCallError => e
    raise Refused, "#{spend_path} is unreadable (#{e.class}); treating the cap as reached"
  end

  def write(data)
    tmp = "#{spend_path}.tmp"
    File.open(tmp, 'w') do |f|
      f.write("#{JSON.pretty_generate(data)}\n")
      f.flush
      f.fsync
    end
    File.rename(tmp, spend_path)
  end
end
