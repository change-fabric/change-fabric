# frozen_string_literal: true

require 'base64'
require 'optparse'
require 'json'
require 'net/http'
require 'uri'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_captions'
require_relative 'walkthrough_env'
require_relative 'walkthrough_storyboard'

# ElevenLabs REST client for narration and music (cf:narrate, cf:music, and
# the walkthrough render). Uses Net::HTTP
# with the xi-api-key header; the key is never logged and is scrubbed from
# every raised message. Request building and response decoding are pure so
# they test without a network; the transport is injectable.
module ElevenLabs
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
    body['voice_settings'] = settings if settings && !settings.empty?
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

module ElevenLabs
  # Command line entry: `narrate` and `music` subcommands over the library.
  # run returns the exit code: 0 ok, 1 a named failure, 2 usage.
  module Cli
    DEFAULT_MODEL = 'eleven_multilingual_v2'
    DEFAULT_OUTPUT_FORMAT = 'mp3_44100_128'
    COMMANDS = %w[narrate music].freeze
    DEFAULT_MUSIC_MODEL = 'music_v1'
    USAGE = 'usage: elevenlabs.rb narrate|music [options] (--cache DIR sets the cache root, default .cache)'

    class UsageError < StandardError; end

    module_function

    def run(argv, out: $stdout, transport: DEFAULT_TRANSPORT, sleeper: method(:sleep))
      args = argv.dup
      command = args.shift
      unless COMMANDS.include?(command)
        out.puts(USAGE)
        return 2
      end
      WalkthroughEnv.load_secrets
      send(command, parse(args), out, transport, sleeper)
      0
    rescue UsageError, Error, OptionParser::ParseError, WalkthroughEnv::MissingKeyError => e
      out.puts("error: #{e.message}")
      1
    end

    def parse(args)
      opts = { cache: '.cache' }
      OptionParser.new do |o|
        o.on('--text TEXT') { |v| opts[:text] = v }
        o.on('--file PATH') { |v| opts[:file] = v }
        o.on('--storyboard PATH') { |v| opts[:storyboard] = v }
        o.on('--scene ID') { |v| opts[:scene] = v }
        o.on('--voice ID') { |v| opts[:voice] = v }
        o.on('--model ID') { |v| opts[:model] = v }
        o.on('--format NAME') { |v| opts[:format] = v }
        o.on('--prompt TEXT') { |v| opts[:prompt] = v }
        o.on('--plan PATH') { |v| opts[:plan] = v }
        o.on('--duration-ms MS', Integer) { |v| opts[:duration_ms] = v }
        o.on('--cache DIR') { |v| opts[:cache] = v }
        o.on('--estimate-only') { opts[:estimate_only] = true }
      end.parse!(args)
      opts
    end

    def narrate(opts, out, transport, sleeper)
      items = narration_items(opts)
      pending = items.reject { |item| cached?(opts[:cache], item) }.sum { |item| item[:text].length }
      model = items.first[:model]
      out.puts(ElevenLabs.format_estimate(ElevenLabs.estimate(chars: pending, music_ms: 0, model: model)))
      return if opts[:estimate_only]

      items.each do |item|
        res = ElevenLabs.tts(**item.except(:label), cache_root: opts[:cache], transport: transport, sleeper: sleeper)
        out.puts("scene #{item[:label]}:") if item[:label]
        out.puts("audio: #{res[:audio]}", "alignment: #{res[:alignment]}", "srt: #{write_srt(res, opts[:cache])}")
      end
    end

    def music(opts, out, transport, sleeper)
      spec = music_spec(opts)
      block = { prompt: spec[:prompt], composition_plan: spec[:composition_plan], model: spec[:model] }
      path = WalkthroughCache.path(opts[:cache], :music, ElevenLabs.music_key(block, spec[:length_ms]), 'mp3')
      pending_ms = File.file?(path) ? 0 : spec[:length_ms]
      out.puts(ElevenLabs.format_estimate(ElevenLabs.estimate(chars: 0, music_ms: pending_ms, model: spec[:model])))
      return if opts[:estimate_only]

      res = ElevenLabs.music(**spec, cache_root: opts[:cache], transport: transport, sleeper: sleeper)
      out.puts("music: #{res[:path]}")
    end

    # The music request: a prompt with a duration, a composition plan file
    # (its length is the sum of its sections), or a storyboard's music block
    # sized to its timeline.
    def music_spec(opts)
      raise UsageError, 'music needs exactly one of --prompt, --plan, --storyboard' unless %i[prompt plan storyboard].count { |k| opts[k] } == 1

      spec = source_spec(opts)
      spec.merge(model: opts[:model] || spec[:model] || DEFAULT_MUSIC_MODEL, length_ms: ElevenLabs.clamp_music_ms(spec[:length_ms]))
    end

    def source_spec(opts)
      return storyboard_music(opts) if opts[:storyboard]

      if opts[:plan]
        plan = ElevenLabs.validate_plan!(JSON.parse(File.read(opts[:plan])))
        return { composition_plan: plan, length_ms: Array(plan['sections']).sum { |sec| sec['duration_ms'].to_i } }
      end
      { prompt: opts[:prompt], length_ms: opts[:duration_ms] || raise(UsageError, '--prompt needs --duration-ms') }
    end

    def storyboard_music(opts)
      board = JSON.parse(File.read(opts[:storyboard]))
      block = board['music'] || raise(UsageError, 'the storyboard has no music block')
      { prompt: block['prompt'], composition_plan: block['composition_plan'], model: block['model'],
        length_ms: WalkthroughStoryboard.timeline(board)['total_ms'] }
    end

    def cached?(cache, item)
      key = ElevenLabs.audio_key(**item.slice(:text, :voice_id, :model, :output_format, :settings))
      File.file?(WalkthroughCache.path(cache, :audio, key, 'mp3'))
    end

    # One item per narrated unit: the text or script file, or each narrated
    # storyboard scene (all, or the one named by --scene), in order.
    def narration_items(opts)
      sources = %i[text file storyboard].count { |k| opts[k] }
      raise UsageError, 'narrate needs exactly one of --text, --file, --storyboard' unless sources == 1

      return storyboard_items(opts) if opts[:storyboard]

      text = opts[:text] || File.read(opts[:file]).strip
      [ item(text, opts, {}) ]
    end

    def storyboard_items(opts)
      board = JSON.parse(File.read(opts[:storyboard]))
      scenes = WalkthroughStoryboard.scenes(board).select { |sc| !sc.dig('narration', 'text').to_s.strip.empty? }
      scenes = scenes.select { |sc| sc['id'] == opts[:scene] } if opts[:scene]
      raise UsageError, "no narrated scene #{opts[:scene]}" if scenes.empty?

      scenes.map { |sc| item(sc.dig('narration', 'text'), opts, board['voice'] || {}).merge(label: sc['id'], settings: board.dig('voice', 'settings') || {}) }
    end

    def item(text, opts, board_voice)
      voice = opts[:voice] || board_voice['voice_id'] || raise(UsageError, 'narrate needs --voice <voice_id>')
      { text: text, voice_id: voice, model: opts[:model] || board_voice['model'] || DEFAULT_MODEL,
        output_format: opts[:format] || board_voice['output_format'] || DEFAULT_OUTPUT_FORMAT }
    end

    def write_srt(res, cache)
      alignment = JSON.parse(File.read(res[:alignment]))
      path = WalkthroughCache.path(cache, :audio, res[:key], 'srt')
      File.write(path, WalkthroughCaptions.srt(WalkthroughCaptions.cues(WalkthroughCaptions.word_spans(alignment))))
      path
    end
  end
end

exit(ElevenLabs::Cli.run(ARGV)) if __FILE__ == $PROGRAM_NAME
