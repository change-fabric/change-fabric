# frozen_string_literal: true

require 'json'
require_relative 'cf_provider_registry'

# One vocabulary for a paid provider's HTTP failures, shared by every paid
# client (roast, image, b-roll, narrate, music). classify maps a provider, an
# HTTP status and a body to a named Failure subclass with a scrubbed message
# and a next step:
#
#   auth_revoked     401 or 403: the provider rejected the key
#   quota_exhausted  OpenAI 429 insufficient_quota, ElevenLabs 402 (or its
#                    401 quota_exceeded): no credit left, never retried
#   rate_limited     any other 429: retried a bounded number of times
#   bad_request      400 and any other 4xx, carrying the provider's message
#   server           5xx and anything else unexpected
#
# Every message is scrubbed of the literal key and of anything shaped like a
# registered provider key (config/providers.yml key_shape).
module CfProviderError
  REDACTED = '[REDACTED]'
  MAX_ATTEMPTS = 3
  MAX_RETRY_AFTER = 60
  DETAIL_CHARS = 300

  # A named provider failure. Never carries a key value.
  class Failure < StandardError
    attr_reader :provider, :status, :next_step, :retry_after

    def initialize(message, provider:, status: nil, next_step: nil, retry_after: nil)
      @provider = provider
      @status = status
      @next_step = next_step
      @retry_after = retry_after
      super(message)
    end

    def klass = self.class::NAME

    # Key-class failures surface even on optional paths (b-roll fallback,
    # walkthrough roast skip); transient ones may fall back.
    def surface? = false

    def to_h = { provider: provider, class: klass, status: status, next_step: next_step }.compact
  end

  class AuthRevoked < Failure
    NAME = 'auth_revoked'
    def surface? = true
  end

  class QuotaExhausted < Failure
    NAME = 'quota_exhausted'
    def surface? = true
  end

  class RateLimited < Failure
    NAME = 'rate_limited'
  end

  class BadRequest < Failure
    NAME = 'bad_request'
  end

  class Server < Failure
    NAME = 'server'
  end

  @sleeper = ->(seconds) { sleep(seconds) }

  class << self
    # The default wait between rate-limit retries; tests swap it.
    attr_accessor :sleeper
  end

  module_function

  def success?(status) = status.to_i.between?(200, 299)

  # The Failure for a non-2xx response (nil for a 2xx), scrubbed.
  def classify(provider:, status:, body:, headers: {}, key: nil)
    code = status.to_i
    return nil if success?(code)

    detail = scrub(detail(body), key: key)
    klass = class_for(provider.to_s, code, body.to_s)
    retry_after = klass == RateLimited ? retry_after_from(headers) : nil
    klass.new("#{label(provider)} HTTP #{code} #{klass::NAME}#{": #{detail}" unless detail.empty?}",
              provider: provider.to_s, status: code, next_step: next_step(klass, provider), retry_after: retry_after)
  end

  # The Failure for a Net::HTTP-like response, reading retry-after when the
  # response exposes headers.
  def from_response(provider:, response:, key: nil)
    classify(provider: provider, status: response.code, body: response.body,
             headers: { 'retry-after' => header(response, 'retry-after') }, key: key)
  end

  def class_for(provider, code, body)
    return QuotaExhausted if quota?(provider, code, body)
    return AuthRevoked if [ 401, 403 ].include?(code)
    return RateLimited if code == 429
    return BadRequest if code.between?(400, 499)

    Server
  end

  def quota?(provider, code, body)
    case provider
    when 'openai' then code == 429 && body.include?('insufficient_quota')
    when 'elevenlabs' then code == 402 || (code == 401 && body.include?('quota_exceeded'))
    else false
    end
  end

  def next_step(klass, provider)
    name = label(provider)
    {
      AuthRevoked => "the #{name} key was rejected (revoked or invalid); create a new key in the #{name} dashboard " \
                     "and re-enroll it: ruby ~/.claude/cf/bin/cf_keys.rb enroll #{provider}",
      QuotaExhausted => "the #{name} account is out of credit or over its usage limit; add credit or raise the " \
                        'limit in its billing settings, then rerun (not retried)',
      RateLimited => "#{name} is rate limiting this key; wait a minute and rerun, or lower concurrency",
      BadRequest => "#{name} rejected the request; fix what its message names and rerun",
      Server => "#{name} failed on its side; rerun later"
    }.fetch(klass)
  end

  # Runs the block, retrying a RateLimited failure up to MAX_ATTEMPTS in all,
  # waiting retry-after (capped) or 2**attempt seconds. Any other failure,
  # quota_exhausted above all, propagates at once.
  def with_retry(attempts: MAX_ATTEMPTS, sleeper: nil)
    sleeper ||= CfProviderError.sleeper
    attempt = 0
    begin
      attempt += 1
      yield
    rescue RateLimited => e
      raise if attempt >= attempts

      sleeper.call(wait_for(e.retry_after, attempt))
      retry
    end
  end

  def wait_for(retry_after, attempt)
    value = retry_after&.positive? ? retry_after : 2**attempt
    [ value, MAX_RETRY_AFTER ].min
  end

  def retry_after_from(headers)
    value = Float((headers || {})['retry-after'] || (headers || {})['Retry-After'], exception: false)
    value&.positive? ? value : nil
  end

  # A header off a real Net::HTTPResponse; nil for a stub that has none.
  def header(response, name)
    response.respond_to?(:[]) ? response[name] : nil
  rescue StandardError
    nil
  end

  # The provider's own message: OpenAI and Gemini {"error":{"message"}},
  # ElevenLabs {"detail":{"message"}} or {"detail":"..."}; else the raw body.
  def detail(body)
    parsed = JSON.parse(body.to_s)
    found = parsed.is_a?(Hash) ? (parsed['error'] || parsed['detail'] || parsed) : parsed
    text = found.is_a?(Hash) ? (found['message'] || JSON.generate(found)) : found.to_s
    text.to_s[0, DETAIL_CHARS]
  rescue JSON::ParserError
    body.to_s.strip[0, DETAIL_CHARS]
  end

  # Removes the literal key and anything shaped like a registered key.
  def scrub(text, key: nil)
    out = text.to_s.dup
    out = out.gsub(key, REDACTED) if key.is_a?(String) && !key.empty?
    shapes.reduce(out) { |acc, regex| acc.gsub(regex, REDACTED) }
  end

  def shapes
    @shapes ||= CfProviderRegistry.all.map(&:key_regex)
  rescue StandardError
    @shapes = []
  end

  def label(provider)
    CfProviderRegistry.fetch(provider).label
  rescue StandardError
    provider.to_s
  end
end
