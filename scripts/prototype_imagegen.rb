# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'securerandom'
require 'uri'
require_relative 'walkthrough_cache'
require_relative 'walkthrough_env'

# In-screen imagery for cf:prototype (avatars, product photos, hero art) and
# cf:design moodboards, from the OpenAI Images API. Never UI: screens stay
# HTML/CSS. Every output is cached by content hash, so a cached run needs no
# key and costs nothing; callers print `estimate` before any paid call.
module PrototypeImagegen
  class AttemptCapError < StandardError; end
  class RequestError < StandardError; end

  MODEL = ENV.fetch('CF_IMAGE_MODEL', 'gpt-image-2')
  QUALITY_DRAFT = 'medium'
  QUALITY_FINAL = 'high'
  ATTEMPT_CAP = 3
  # Approximate USD per 1024x1024 image.
  PRICE = { 'medium' => 0.05, 'high' => 0.21 }.freeze
  GENERATIONS_URL = 'https://api.openai.com/v1/images/generations'
  EDITS_URL = 'https://api.openai.com/v1/images/edits'

  module_function

  # The content-hash key for one image request.
  def asset_key(prompt:, size:, quality:, refs: [], model: MODEL)
    ref_digests = refs.map { |ref| Digest::SHA256.file(ref).hexdigest }
    WalkthroughCache.key({ prompt: prompt, model: model, size: size, quality: quality, refs: ref_digests })
  end

  # Returns { count:, by_quality:, usd: } and the printable line for it.
  def estimate(requests)
    by_quality = requests.group_by { |req| req[:quality] }.transform_values(&:size)
    usd = requests.sum { |req| PRICE.fetch(req[:quality]) }.round(2)
    { count: requests.size, by_quality: by_quality, usd: usd,
      line: "#{requests.size} image(s) (#{by_quality.map { |q, n| "#{n} #{q}" }.join(', ')}), about $#{format('%.2f', usd)}" }
  end

  # The pure request description: url, headers (key redacted), and body.
  def build_request(prompt:, size:, quality:, refs: [], model: MODEL)
    if refs.empty?
      { url: GENERATIONS_URL, content_type: 'application/json',
        body: { model: model, prompt: prompt, size: size, quality: quality, n: 1 } }
    else
      { url: EDITS_URL, content_type: 'multipart/form-data',
        body: { model: model, prompt: prompt, size: size, quality: quality, n: 1 }, files: refs }
    end
  end

  # Tracks attempts per screen; raises once a screen passes the cap.
  class Attempts
    def initialize(cap = ATTEMPT_CAP)
      @cap = cap
      @counts = Hash.new(0)
    end

    def record!(screen)
      raise AttemptCapError, "image attempt cap (#{@cap}) reached for screen #{screen}; edit the prompt" if @counts[screen] >= @cap

      @counts[screen] += 1
    end

    def count(screen) = @counts[screen]
  end

  # Generates (or returns the cached) image path. The attempt is counted only
  # when a paid call actually runs.
  def generate(prompt:, size:, quality:, cache_root:, refs: [], screen: 'default', attempts: Attempts.new, http: nil)
    key = asset_key(prompt: prompt, size: size, quality: quality, refs: refs)
    WalkthroughCache.fetch(cache_root, :images, key, 'png') do |tmp|
      attempts.record!(screen)
      request = build_request(prompt: prompt, size: size, quality: quality, refs: refs)
      File.binwrite(tmp, decode(post(request, http)))
    end
  end

  def decode(body)
    b64 = body.dig('data', 0, 'b64_json') || raise(RequestError, 'image response carried no b64_json')
    Base64.decode64(b64)
  end

  def post(request, http)
    uri = URI(request[:url])
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{WalkthroughEnv.openai_key!}"
    if request[:files]
      boundary = "cf-#{SecureRandom.hex(8)}"
      req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      req.body = multipart(request[:body], request[:files], boundary)
    else
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(request[:body])
    end
    response = (http || default_http(uri)).request(req)
    raise RequestError, "image request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def multipart(fields, files, boundary)
    parts = fields.map do |name, value|
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
    end
    files.each do |path|
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"#{File.basename(path)}\"\r\n" \
               "Content-Type: image/png\r\n\r\n#{File.binread(path)}\r\n"
    end
    "#{parts.join}--#{boundary}--\r\n"
  end

  def default_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 180
    http
  end
end

if __FILE__ == $PROGRAM_NAME
  prompt, cache = ARGV
  abort('usage: prototype_imagegen.rb <prompt> <cache-root> [--final]') unless prompt && cache
  quality = ARGV.include?('--final') ? PrototypeImagegen::QUALITY_FINAL : PrototypeImagegen::QUALITY_DRAFT
  puts PrototypeImagegen.estimate([ { quality: quality } ])[:line]
  WalkthroughEnv.load_secrets
  puts PrototypeImagegen.generate(prompt: prompt, size: '1024x1024', quality: quality, cache_root: cache)
end
