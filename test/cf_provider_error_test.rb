# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../scripts/cf_provider_error"
require_relative "../scripts/walkthrough_env"
require_relative "enroll_helpers"

class CfProviderErrorTest < Minitest::Test
  include EnrollHelpers

  KEY = "sk-literal-fixture-key"
  OPENAI_SHAPED = "sk-proj-#{'A' * 30}".freeze
  ELEVEN_SHAPED = "sk_#{'a' * 48}".freeze

  def classify(provider, status, body = "{}", headers: {})
    CfProviderError.classify(provider: provider, status: status, body: body, headers: headers, key: KEY)
  end

  def test_success_is_nil
    assert_nil classify("openai", 200)
    assert_nil classify("openai", "204")
  end

  def test_status_and_body_map_to_a_class
    {
      [ "openai", 401, "{}" ] => "auth_revoked",
      [ "gemini", 403, "{}" ] => "auth_revoked",
      [ "elevenlabs", 401, "{}" ] => "auth_revoked",
      [ "openai", 429, '{"error":{"code":"insufficient_quota"}}' ] => "quota_exhausted",
      [ "elevenlabs", 402, "{}" ] => "quota_exhausted",
      [ "elevenlabs", 401, '{"detail":{"status":"quota_exceeded"}}' ] => "quota_exhausted",
      [ "openai", 429, '{"error":{"code":"rate_limit_exceeded"}}' ] => "rate_limited",
      [ "gemini", 429, "{}" ] => "rate_limited",
      [ "openai", 400, "{}" ] => "bad_request",
      [ "elevenlabs", 422, "{}" ] => "bad_request",
      [ "openai", 503, "{}" ] => "server",
      [ "gemini", 500, "{}" ] => "server"
    }.each do |(provider, status, body), name|
      assert_equal name, classify(provider, status, body).klass, "#{provider} #{status} #{body}"
    end
  end

  def test_surface_only_for_key_class_failures
    assert classify("openai", 401).surface?
    assert classify("elevenlabs", 402).surface?
    refute classify("openai", 429).surface?
    refute classify("openai", 400).surface?
    refute classify("openai", 503).surface?
  end

  def test_bad_request_carries_the_provider_message
    err = classify("openai", 400, '{"error":{"message":"Invalid size 999x999"}}')
    assert_includes err.message, "Invalid size 999x999"
    assert_includes err.message, "OpenAI HTTP 400 bad_request"
    err = classify("elevenlabs", 400, '{"detail":{"message":"voice not found"}}')
    assert_includes err.message, "voice not found"
  end

  def test_scrubs_literal_and_key_shaped_values
    body = JSON.generate("error" => { "message" => "keys #{KEY} #{OPENAI_SHAPED} #{ELEVEN_SHAPED}" })
    err = classify("openai", 400, body)
    [ KEY, OPENAI_SHAPED, ELEVEN_SHAPED ].each { |k| refute_includes err.message, k }
    assert_includes err.message, "[REDACTED]"
    raw = classify("gemini", 500, "plain text #{KEY}")
    refute_includes raw.message, KEY
  end

  def test_every_class_has_a_next_step
    [ 401, 402, 429, 400, 503 ].each do |status|
      step = classify("elevenlabs", status).next_step
      refute_empty step.to_s, status.to_s
    end
    assert_includes classify("openai", 401).next_step, "cf_keys.rb enroll openai"
  end

  def test_retry_after_is_read_only_for_rate_limits
    assert_equal 12.0, classify("openai", 429, headers: { "retry-after" => "12" }).retry_after
    assert_nil classify("openai", 503, headers: { "retry-after" => "12" }).retry_after
  end

  def test_with_retry_bounds_attempts_and_caps_the_wait
    sleeps = []
    calls = 0
    assert_raises(CfProviderError::RateLimited) do
      CfProviderError.with_retry(sleeper: ->(s) { sleeps << s }) do
        calls += 1
        raise classify("openai", 429, headers: { "retry-after" => "600" })
      end
    end
    assert_equal 3, calls
    assert_equal [ 60, 60 ], sleeps
  end

  def test_with_retry_never_retries_quota
    calls = 0
    assert_raises(CfProviderError::QuotaExhausted) do
      CfProviderError.with_retry(sleeper: ->(_) { flunk "slept" }) do
        calls += 1
        raise classify("openai", 429, '{"error":{"code":"insufficient_quota"}}')
      end
    end
    assert_equal 1, calls
  end

  def test_header_tolerates_stub_responses
    stub = Struct.new(:code, :body).new("429", "{}")
    assert_nil CfProviderError.header(stub, "retry-after")
    assert_equal "429", CfProviderError.from_response(provider: "openai", response: stub).status.to_s
  end

  def test_key_error_exit_contract
    enroll_home!("openai")
    out = StringIO.new
    assert_equal 4, WalkthroughEnv.key_error(classify("openai", 401), out: out)
    line = enroll_lines(out.string).first["cf_enroll"]
    assert_equal "revoked", line["reason"]
    assert_includes line["snippet"], "cf_keys.rb enroll openai"
    out = StringIO.new
    assert_equal 1, WalkthroughEnv.key_error(classify("openai", 503), out: out)
    json = JSON.parse(out.string.lines.first)["cf_key_error"]
    assert_equal({ "provider" => "openai", "class" => "server", "status" => 503 }, json.except("next_step"))
    refute_includes out.string, KEY
  ensure
    restore_home!
  end
end
