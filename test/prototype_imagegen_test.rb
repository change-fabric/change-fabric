# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "tmpdir"
require_relative "../scripts/prototype_imagegen"
require_relative "imagegen_helpers"

class PrototypeImagegenTest < Minitest::Test
  include ImagegenHelpers

  def test_defaults
    assert_equal "gpt-image-2", PrototypeImagegen::MODEL unless ENV["CF_IMAGE_MODEL"]
    assert_equal "medium", PrototypeImagegen::QUALITY_DRAFT
    assert_equal "high", PrototypeImagegen::QUALITY_FINAL
    assert_equal 3, PrototypeImagegen::ATTEMPT_CAP
  end

  def test_generation_request_shape
    req = PrototypeImagegen.build_request(prompt: "a hero", size: "1024x1024", quality: "medium", model: "m")
    assert_equal PrototypeImagegen::GENERATIONS_URL, req[:url]
    assert_equal({ model: "m", prompt: "a hero", size: "1024x1024", quality: "medium", n: 1 }, req[:body])
    refute req.key?(:files)
  end

  def test_edit_request_when_refs_given
    req = PrototypeImagegen.build_request(prompt: "p", size: "1024x1024", quality: "high", refs: [ "a.png" ])
    assert_equal PrototypeImagegen::EDITS_URL, req[:url]
    assert_equal [ "a.png" ], req[:files]
  end

  def test_estimate_math
    est = PrototypeImagegen.estimate([ { quality: "medium" }, { quality: "medium" }, { quality: "high" } ])
    assert_equal 3, est[:count]
    assert_in_delta 0.31, est[:usd]
    assert_equal({ "medium" => 2, "high" => 1 }, est[:by_quality])
    assert_includes est[:line], "$0.31"
  end

  def test_attempt_cap
    attempts = PrototypeImagegen::Attempts.new(2)
    2.times { attempts.record!("home") }
    err = assert_raises(PrototypeImagegen::AttemptCapError) { attempts.record!("home") }
    assert_includes err.message, "home"
    attempts.record!("other")
  end

  def test_generate_caches_and_counts_only_paid_calls
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    Dir.mktmpdir do |dir|
      http = FakeHttp.new
      attempts = PrototypeImagegen::Attempts.new
      args = { prompt: "avatar", size: "1024x1024", quality: "medium", cache_root: dir, screen: "s", attempts: attempts, http: http }
      path = PrototypeImagegen.generate(**args)
      assert_equal "PNG", File.binread(path)
      assert_equal path, PrototypeImagegen.generate(**args)
      assert_equal 1, http.requests.size
      assert_equal 1, attempts.count("s")
      assert_equal "Bearer sk-test-secret", http.requests.first["Authorization"]
      assert_equal "avatar", JSON.parse(http.requests.first.body)["prompt"]
    end
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  def test_edit_and_mask_ride_the_edits_endpoint_with_edit_first
    Dir.mktmpdir do |dir|
      edit, ref, mask = %w[e r m].map { |n| write_fixture(dir, "#{n}.png") }
      req = PrototypeImagegen.build_request(prompt: "p", size: "1024x1024", quality: "low", refs: [ ref ], edit: edit, mask: mask)
      assert_equal PrototypeImagegen::EDITS_URL, req[:url]
      assert_equal [ edit, ref ], req[:files]
      assert_equal mask, req[:mask]
    end
  end

  def test_asset_key_covers_edit_and_mask_and_keeps_legacy_keys
    Dir.mktmpdir do |dir|
      a, b = %w[a b].map { |n| write_fixture(dir, "#{n}.png") }
      base = { prompt: "p", size: "1024x1024", quality: "low" }
      legacy = PrototypeImagegen.asset_key(**base)
      assert_equal legacy, PrototypeImagegen.asset_key(**base, edit: nil, mask: nil)
      refute_equal legacy, PrototypeImagegen.asset_key(**base, edit: a)
      refute_equal PrototypeImagegen.asset_key(**base, edit: a), PrototypeImagegen.asset_key(**base, edit: a, mask: b)
      refute_equal PrototypeImagegen.asset_key(**base, refs: [ a ]), PrototypeImagegen.asset_key(**base, edit: a)
    end
  end

  def test_multipart_carries_image_parts_and_mask
    Dir.mktmpdir do |dir|
      edit, mask = %w[e m].map { |n| write_fixture(dir, "#{n}.png") }
      body = PrototypeImagegen.multipart({ model: "m" }, [ edit ], "B", mask)
      assert_includes body, 'name="image[]"; filename="e.png"'
      assert_includes body, 'name="mask"; filename="m.png"'
    end
  end

  def test_cached_reflects_the_cache_without_a_key
    Dir.mktmpdir do |dir|
      args = { prompt: "p", size: "1024x1024", quality: "low" }
      refute PrototypeImagegen.cached?(dir, **args)
      ENV["OPENAI_API_KEY"] = "k"
      PrototypeImagegen.generate(**args, cache_root: dir, http: FakeHttp.new)
      assert PrototypeImagegen.cached?(dir, **args)
    end
  ensure
    ENV.delete("OPENAI_API_KEY")
  end

  def test_low_quality_is_priced
    assert_operator PrototypeImagegen.estimate([ { quality: "low" } ])[:usd], :>, 0
  end

  def test_failure_message_never_carries_key
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    Dir.mktmpdir do |dir|
      err = assert_raises(PrototypeImagegen::RequestError) do
        PrototypeImagegen.generate(prompt: "x", size: "1024x1024", quality: "medium", cache_root: dir, http: FakeHttp.new("401"))
      end
      refute_includes err.message, "sk-test-secret"
    end
  ensure
    ENV.delete("OPENAI_API_KEY")
  end
end
