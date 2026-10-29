# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/image"
require_relative "imagegen_helpers"

class ImageTest < Minitest::Test
  include ImagegenHelpers

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, ".cache")
    @out = StringIO.new
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    ENV.delete("CF_SECRETS_ENV")
  end

  def teardown
    ENV.delete("OPENAI_API_KEY")
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args, http: ImagegenHelpers::FakeHttp.new)
    code = Image::Cli.run([ *args, "--cache", @cache ], out: @out, http: http)
    [ code, @out.string, http ]
  end

  def png(name) = write_fixture(@dir, name)

  def test_generates_prints_estimate_first_and_writes_out
    out_path = File.join(@dir, "shot.png")
    code, text, http = run_cli("a candid kitchen", "--out", out_path)
    assert_equal 0, code
    assert_operator text.index("estimate"), :<, text.index("image:")
    assert_equal "PNG", File.binread(out_path)
    assert_equal 1, http.requests.size
    assert_equal "gpt-image-2", JSON.parse(http.requests.first.body)["model"] unless ENV["CF_IMAGE_MODEL"]
  end

  def test_rerun_is_free_and_needs_no_key
    run_cli("same prompt")
    ENV.delete("OPENAI_API_KEY")
    @out.truncate(0)
    @out.rewind
    code, text, http = run_cli("same prompt")
    assert_equal 0, code
    assert_empty http.requests
    assert_includes text, "$0.00"
  end

  def test_prompt_file
    file = File.join(@dir, "p.txt")
    File.write(file, "  from a file\n")
    _, _, http = run_cli("--prompt-file", file)
    assert_equal "from a file", JSON.parse(http.requests.first.body)["prompt"]
  end

  def test_refuses_above_ceiling_before_any_call
    code, text, http = run_cli("x", "--quality", "high", "--max-usd", "0.01")
    assert_equal 1, code
    assert_includes text, "ceiling"
    assert_empty http.requests
  end

  def test_cached_run_passes_a_zero_ceiling
    run_cli("x")
    code, = run_cli("x", "--max-usd", "0")
    assert_equal 0, code
  end

  def test_edit_with_mask_and_refs_go_multipart
    code, _, http = run_cli("fix it", "--edit", png("e.png"), "--mask", png("m.png"), "--ref", png("r1.png"), "--ref", png("r2.png"))
    assert_equal 0, code
    req = http.requests.first
    assert_equal PrototypeImagegen::EDITS_URL, req.uri.to_s
    assert_match(%r{multipart/form-data}, req["Content-Type"])
    assert_equal 3, req.body.scan('name="image[]"').size
    assert_includes req.body, 'name="mask"'
  end

  def test_cache_key_changes_with_ref_digest
    r = png("r.png")
    run_cli("x", "--ref", r)
    File.binwrite(r, "different")
    _, _, http = run_cli("x", "--ref", r)
    assert_equal 1, http.requests.size
  end

  def test_usage_errors_exit_2
    assert_equal 2, run_cli("--size", "1024x1024")[0]
    assert_equal 2, run_cli("a", "--prompt-file", png("p.txt"))[0]
    assert_equal 2, run_cli("a", "--mask", png("m.png"))[0]
    assert_equal 2, run_cli("a", "--bogus")[0]
    assert_equal 2, run_cli("a", "--quality", "ultra")[0]
  end

  def test_missing_ref_file_exits_1
    code, text = run_cli("a", "--ref", File.join(@dir, "nope.png"))
    assert_equal 1, code
    assert_includes text, "nope.png"
  end

  def test_missing_key_exits_1_when_a_call_is_needed
    ENV.delete("OPENAI_API_KEY")
    code, text = run_cli("fresh")
    assert_equal 1, code
    assert_includes text, "OPENAI_API_KEY"
  end

  def test_http_failure_exits_1_and_never_prints_the_key
    code, text = run_cli("x", http: ImagegenHelpers::FakeHttp.new("401"))
    assert_equal 1, code
    assert_includes text, "401"
    refute_includes text, "sk-test-secret"
  end

  def test_estimate_only_makes_no_call
    code, text, http = run_cli("x", "--estimate-only")
    assert_equal 0, code
    assert_includes text, "estimate"
    assert_empty http.requests
  end
end
