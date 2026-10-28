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
  # Approximate USD per 1024x1024 image. `low` is a rough figure: the docs
  # list the tier but no price, so the estimate stays conservative.
  PRICE = { 'low' => 0.02, 'medium' => 0.05, 'high' => 0.21 }.freeze
  GENERATIONS_URL = 'https://api.openai.com/v1/images/generations'
  EDITS_URL = 'https://api.openai.com/v1/images/edits'

  module_function

  # The content-hash key for one image request.
  def asset_key(prompt:, size:, quality:, refs: [], edit: nil, mask: nil, model: MODEL)
    ref_digests = refs.map { |ref| Digest::SHA256.file(ref).hexdigest }
    inputs = { prompt: prompt, model: model, size: size, quality: quality, refs: ref_digests }
    # Added only when present so every key minted before edits existed stays valid.
    inputs[:edit] = Digest::SHA256.file(edit).hexdigest if edit
    inputs[:mask] = Digest::SHA256.file(mask).hexdigest if mask
    WalkthroughCache.key(inputs)
  end

  # Returns { count:, by_quality:, usd:, line: }: the totals and the printable line.
  def estimate(requests)
    by_quality = requests.group_by { |req| req[:quality] }.transform_values(&:size)
    usd = requests.sum { |req| PRICE.fetch(req[:quality]) }.round(2)
    { count: requests.size, by_quality: by_quality, usd: usd,
      line: "#{requests.size} image(s) (#{by_quality.map { |q, n| "#{n} #{q}" }.join(', ')}), about $#{format('%.2f', usd)}" }
  end

  # The pure request description: url, content_type, body, and for edits the
  # files (edit image first) and optional mask. The key is added at send time.
  # The edit image goes first: the API applies a mask to the first image only.
  def build_request(prompt:, size:, quality:, refs: [], edit: nil, mask: nil, model: MODEL)
    files = [ edit, *refs ].compact
    if files.empty?
      { url: GENERATIONS_URL, content_type: 'application/json',
        body: { model: model, prompt: prompt, size: size, quality: quality, n: 1 } }
    else
      { url: EDITS_URL, content_type: 'multipart/form-data',
        body: { model: model, prompt: prompt, size: size, quality: quality, n: 1 }, files: files, mask: mask }.compact
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

  def cached?(cache_root, **inputs)
    File.file?(WalkthroughCache.path(cache_root, :images, asset_key(**inputs), 'png'))
  end

  # Generates (or returns the cached) image path. The attempt is counted only
  # when a paid call actually runs.
  def generate(prompt:, size:, quality:, cache_root:, refs: [], edit: nil, mask: nil, screen: 'default', attempts: Attempts.new, http: nil, model: MODEL)
    key = asset_key(prompt: prompt, size: size, quality: quality, refs: refs, edit: edit, mask: mask, model: model)
    WalkthroughCache.fetch(cache_root, :images, key, 'png') do |tmp|
      attempts.record!(screen)
      request = build_request(prompt: prompt, size: size, quality: quality, refs: refs, edit: edit, mask: mask, model: model)
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
      req.body = multipart(request[:body], request[:files], boundary, request[:mask])
    else
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(request[:body])
    end
    response = (http || default_http(uri)).request(req)
    raise RequestError, "image request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def multipart(fields, files, boundary, mask = nil)
    parts = fields.map { |name, value| "#{part_header(boundary, name)}\r\n\r\n#{value}\r\n" }
    files.each { |path| parts << file_part('image[]', path, boundary) }
    parts << file_part('mask', mask, boundary) if mask
    # Binary join: a UTF-8 prompt next to raw PNG bytes would otherwise raise.
    "#{parts.map(&:b).join}--#{boundary}--\r\n".b
  end

  def file_part(name, path, boundary)
    "#{part_header(boundary, name, File.basename(path))}\r\nContent-Type: image/png\r\n\r\n#{File.binread(path)}\r\n"
  end

  def part_header(boundary, name, filename = nil)
    disposition = "form-data; name=\"#{name}\"#{"; filename=\"#{filename}\"" if filename}"
    "--#{boundary}\r\nContent-Disposition: #{disposition}"
  end

  def default_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 180
    http
  end
end
