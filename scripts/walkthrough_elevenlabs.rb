# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'uri'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_env'

# ElevenLabs REST client for walkthrough narration and music. Uses Net::HTTP
# with the xi-api-key header; the key is never logged and is scrubbed from
# every raised message. Request building and response decoding are pure so
# they test without a network; the transport is injectable.
module WalkthroughElevenlabs
  BASE = 'https://api.elevenlabs.io'
  MUSIC_MIN_MS = 3_000
  MUSIC_MAX_MS = 600_000
  SECTION_MIN_MS = 3_000
  SECTION_MAX_MS = 120_000
  MAX_RETRIES = 3
  TTS_USD_PER_1K = { multilingual: 0.08, flash: 0.04 }.freeze
  MUSIC_USD_PER_MIN = 0.15

  class Error < StandardError; end
  class AuthError < Error; end
  class QuotaError < Error; end
  class RequestError < Error; end
  class RateLimitError < Error; end

  Request = Struct.new(:method, :path, :query, :body, keyword_init: true) do
    def uri
      u = URI.join(BASE, path)
      u.query = URI.encode_www_form(query) unless query.nil? || query.empty?
      u
    end
  end

  DEFAULT_TRANSPORT = lambda do |request, key|
    uri = request.uri
    http_req = Net::HTTP::Post.new(uri)
    http_req['xi-api-key'] = key
    http_req['Content-Type'] = 'application/json'
    http_req.body = JSON.generate(request.body)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 300) { |h| h.request(http_req) }
  end

  module_function

  def tts_request(text:, voice_id:, model:, output_format:, settings: nil)
    body = { 'text' => text, 'model_id' => model }
    body['voice_settings'] = settings if settings
    Request.new(method: :post, path: "/v1/text-to-speech/#{URI.encode_www_form_component(voice_id)}/with-timestamps",
                query: { 'output_format' => output_format }, body: body)
  end

  def music_request(length_ms:, model:, prompt: nil, composition_plan: nil)
    raise RequestError, 'music needs exactly one of prompt or composition_plan' if prompt.nil? == composition_plan.nil?

    body = { 'model_id' => model }
    if composition_plan
      validate_plan!(composition_plan)
      body['composition_plan'] = composition_plan
    else
      body['prompt'] = prompt
      body['music_length_ms'] = clamp_music_ms(length_ms)
    end
    Request.new(method: :post, path: '/v1/music', query: {}, body: body)
  end

  def clamp_music_ms(ms) = Integer(ms).clamp(MUSIC_MIN_MS, MUSIC_MAX_MS)

  def validate_plan!(plan)
    raise RequestError, 'composition_plan must not carry a seed' if plan.key?('seed') || plan.key?(:seed)

    sections = plan['sections'] || plan[:sections] || []
    sections.each_with_index do |s, i|
      ms = s['duration_ms'] || s[:duration_ms]
      next if ms.is_a?(Integer) && ms.between?(SECTION_MIN_MS, SECTION_MAX_MS)

      raise RequestError, "composition_plan section #{i} duration_ms must be #{SECTION_MIN_MS}..#{SECTION_MAX_MS}"
    end
    plan
  end

  # Decodes a with-timestamps JSON body into audio bytes, alignment, and the
  # measured duration from the last character end time.
  def decode_tts(json_body)
    data = JSON.parse(json_body)
    audio = Base64.decode64(data.fetch('audio_base64'))
    alignment = data['normalized_alignment'] || data['alignment'] ||
                raise(RequestError, 'tts response carried no alignment')
    ends = alignment['character_end_times_seconds'] || []
    { audio: audio, alignment: alignment, measured_ms: ((ends.last || 0) * 1000).round }
  rescue JSON::ParserError, KeyError => e
    raise RequestError, "tts response malformed: #{e.class}"
  end

  def audio_key(text:, voice_id:, model:, output_format:, settings: nil)
    WalkthroughCache.key(text: text, voice_id: voice_id, model: model, output_format: output_format,
                         settings: settings)
  end

  def music_key(music_block, total_ms)
    WalkthroughCache.key(music: music_block, total_ms: total_ms)
  end

  def tts(text:, voice_id:, model:, output_format:, cache_root:, settings: nil, transport: DEFAULT_TRANSPORT,
          sleeper: method(:sleep))
    key = audio_key(text: text, voice_id: voice_id, model: model, output_format: output_format, settings: settings)
    align_path = WalkthroughCache.path(cache_root, :audio, key, 'alignment.json')
    measured = nil
    audio_path = WalkthroughCache.fetch(cache_root, :audio, key, 'mp3') do |tmp|
      req = tts_request(text: text, voice_id: voice_id, model: model, output_format: output_format,
                        settings: settings)
      decoded = decode_tts(perform(req, transport: transport, sleeper: sleeper))
      File.binwrite(tmp, decoded[:audio])
      File.write(align_path, JSON.generate(decoded[:alignment]))
      measured = decoded[:measured_ms]
    end
    measured ||= measured_from(align_path)
    { key: key, audio: audio_path, alignment: align_path, measured_ms: measured }
  end

  def measured_from(align_path)
    return 0 unless File.exist?(align_path)

    ends = JSON.parse(File.read(align_path))['character_end_times_seconds'] || []
    ((ends.last || 0) * 1000).round
  end

  def music(length_ms:, model:, cache_root:, prompt: nil, composition_plan: nil, transport: DEFAULT_TRANSPORT,
            sleeper: method(:sleep))
    block = { prompt: prompt, composition_plan: composition_plan, model: model }
    key = music_key(block, length_ms)
    req = music_request(prompt: prompt, composition_plan: composition_plan, length_ms: length_ms, model: model)
    path = WalkthroughCache.fetch(cache_root, :music, key, 'mp3') do |tmp|
      File.binwrite(tmp, perform(req, transport: transport, sleeper: sleeper))
    end
    { key: key, path: path }
  end

  def estimate(chars:, music_ms:, model:)
    rate = model.to_s.include?('flash') || model.to_s.include?('turbo') ? TTS_USD_PER_1K[:flash] : TTS_USD_PER_1K[:multilingual]
    tts_usd = chars / 1000.0 * rate
    music_usd = music_ms / 60_000.0 * MUSIC_USD_PER_MIN
    { tts_usd: tts_usd.round(4), music_usd: music_usd.round(4), total_usd: (tts_usd + music_usd).round(4) }
  end

  def format_estimate(est)
    format('ElevenLabs estimate: narration $%<t>.2f, music $%<m>.2f, total $%<s>.2f',
           t: est[:tts_usd], m: est[:music_usd], s: est[:total_usd])
  end

  def perform(request, transport:, sleeper:, key: WalkthroughEnv.elevenlabs_key!)
    attempt = 0
    loop do
      response = begin
        transport.call(request, key)
      rescue StandardError => e
        raise RequestError, scrub("transport failed: #{e.class}: #{e.message}", key)
      end
      code = response.code.to_i
      return response.body if code.between?(200, 299)

      if code == 429 && attempt < MAX_RETRIES
        attempt += 1
        sleeper.call(retry_after(response, attempt))
        next
      end
      raise error_for(code, response.body, key)
    end
  end

  def retry_after(response, attempt)
    header = response.respond_to?(:[]) ? response['retry-after'] : nil
    value = Float(header, exception: false)
    value&.positive? ? value : 2**attempt
  end

  def error_for(code, body, key)
    detail = scrub(error_detail(body), key)
    klass = { 401 => AuthError, 402 => QuotaError, 429 => RateLimitError }.fetch(code, RequestError)
    hint = detail.match?(/output_format|format/i) ? ' (the output format may need a higher plan; default mp3_44100_128)' : ''
    klass.new("ElevenLabs HTTP #{code}: #{detail}#{hint}")
  end

  def error_detail(body)
    parsed = JSON.parse(body.to_s)
    d = parsed['detail'] || parsed
    d.is_a?(Hash) ? (d['message'] || JSON.generate(d)) : d.to_s
  rescue JSON::ParserError
    body.to_s[0, 300]
  end

  def scrub(text, key)
    return text.to_s if key.nil? || key.empty?

    text.to_s.gsub(key, '[REDACTED]')
  end
end
