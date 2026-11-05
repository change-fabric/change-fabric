# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/image"
require_relative "imagegen_helpers"
require_relative "enroll_helpers"

class ImageTest < Minitest::Test
  include ImagegenHelpers
  include EnrollHelpers

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
    code = Image::Cli.run([ *args, "--cache", @cache ], out: @out, err: StringIO.new, http: http)
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
    code, text = with_store(enrolled: true) { run_cli("fresh") }
    assert_equal 1, code
    assert_includes text, "OPENAI_API_KEY"
    assert_empty enroll_lines(text)
  end

  def test_unenrolled_uncached_call_exits_4_with_one_enroll_line
    ENV.delete("OPENAI_API_KEY")
    code, text, http = with_store { run_cli("fresh") }
    assert_equal 4, code
    assert_one_enroll_line(text, "openai")
    assert_empty http.requests
  end

  def test_unenrolled_cached_run_exits_0_without_asking
    assert_equal 0, run_cli("cached once").first
    ENV.delete("OPENAI_API_KEY")
    @out = StringIO.new
    code, text, http = with_store { run_cli("cached once") }
    assert_equal 0, code, text
    assert_empty enroll_lines(text)
    assert_empty http.requests
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

  def test_short_prompt_carries_the_exact_text
    _, _, http = run_cli('poster saying "Sale"')
    prompt = JSON.parse(http.requests.first.body)["prompt"]
    assert_includes prompt, 'Render exactly the text "Sale" once'
  end

  def test_none_prompt_and_key_are_unchanged
    args = { size: Image::DEFAULT_SIZE, quality: Image::DEFAULT_QUALITY, refs: [], edit: nil, mask: nil, prompt: "a calm ocean" }
    run_cli("a calm ocean")
    assert PrototypeImagegen.cached?(@cache, **args)
    _, _, http = run_cli("a calm ocean", "--mode", "none")
    assert_empty http.requests
  end

  def test_bad_mode_exits_2
    code, text = run_cli("a", "--mode", "loud")
    assert_equal 2, code
    assert_includes text, "unknown text mode"
  end

  def test_heavy_hands_off_to_image_plate
    seen = nil
    original = ImagePlate::Cli.method(:run)
    ImagePlate::Cli.define_singleton_method(:run) { |opts, out:| seen = opts; out.puts("plate"); 0 }
    code, text, http = run_cli("a banner", "--spec", "copy.json")
    assert_equal 0, code
    assert_includes text, "plate"
    assert_empty http.requests
    assert_equal "copy.json", seen[:spec]
    assert_equal "a banner", seen[:prompt]
  ensure
    ImagePlate::Cli.define_singleton_method(:run, original)
  end

  def test_heavy_prompt_without_spec_exits_2
    code, text = run_cli('"Big summer sale now on" banner')
    assert_equal 2, code
    assert_includes text, "--spec"
  end

  def test_heavy_rejects_image_inputs_before_any_call
    called = false
    original = ImagePlate::Cli.method(:run)
    ImagePlate::Cli.define_singleton_method(:run) { |_opts, out:| called = true; 0 }
    [ %w[--ref r.png], %w[--edit e.png], %w[--edit e.png --mask m.png] ].each do |extra|
      code, text, http = run_cli("a banner", "--spec", "copy.json", *extra)
      assert_equal 2, code, extra.inspect
      assert_includes text, extra.first
      assert_empty http.requests
    end
    refute called
  ensure
    ImagePlate::Cli.define_singleton_method(:run, original)
  end
end
