# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../scripts/key_paste_guard"

class KeyPasteGuardTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/key_paste_guard.rb", __dir__)
  SAMPLES = {
    "OpenAI" => "sk-proj-#{'a1B2' * 10}",
    "ElevenLabs" => "sk_#{'0f' * 24}",
    "Gemini" => "AIza#{'Q' * 35}"
  }.freeze

  def setup = @dir = File.realpath(Dir.mktmpdir)
  def teardown = FileUtils.remove_entry(@dir)

  def emit(prompt)
    io = StringIO.new
    KeyPasteGuard.new({ "prompt" => prompt, "cwd" => @dir }).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string)
  end

  def test_each_registry_shape_blocks_and_points_to_the_cli
    SAMPLES.each do |label, key|
      out = emit("here is my key #{key} thanks")
      assert_equal "block", out["decision"], label
      assert_includes out["reason"], "looks like a #{label} API key"
      assert_includes out["reason"], "cf_keys.rb enroll"
      assert_includes out["reason"], "--dir #{@dir}"
      assert_includes out["reason"], "Rotate"
      refute_includes out["reason"], key
    end
  end

  def test_ordinary_prose_and_short_sk_mentions_pass
    assert_nil emit("Use the sk- prefix, e.g. sk-abc123, and AIza is Google's")
    assert_nil emit("Refactor the roast skill, keep the OPENAI_API_KEY docs short")
    assert_nil emit("")
  end

  def test_malformed_stdin_exits_0_silently
    [ "not json", "[]", "", "{\"prompt\": 42}" ].each do |stdin|
      out, err, status = Open3.capture3(RbConfig.ruby, SCRIPT, stdin_data: stdin)
      assert status.success?, stdin
      assert_empty out, stdin
      assert_empty err, stdin
    end
  end

  def test_cli_blocks_a_pasted_key
    payload = JSON.generate("prompt" => SAMPLES["Gemini"], "cwd" => @dir)
    out, _err, status = Open3.capture3(RbConfig.ruby, SCRIPT, stdin_data: payload)
    assert status.success?
    assert_equal "block", JSON.parse(out)["decision"]
  end
end
