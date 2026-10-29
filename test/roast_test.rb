# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast"
require_relative "imagegen_helpers"

class RoastTest < Minitest::Test
  include ImagegenHelpers

  CRITIC = {
    "score" => 6, "summary" => "Muddled hero.",
    "issues" => [
      { "priority" => "P1", "screen" => "home", "problem" => "No clear action", "fix" => "One primary button" },
      { "priority" => "P2", "screen" => "home", "problem" => "Tight leading", "fix" => "Raise line height" }
    ],
    "thirty_second_test" => { "verdict" => "partial", "reason" => "Purpose unclear" }
  }.freeze

  # A Responses-API reply wrapping the critic JSON.
  class RoastHttp < ImagegenHelpers::FakeHttp
    def initialize(critic = CRITIC, code = "200")
      super(code)
      @critic = critic
    end

    def request(req)
      @requests << req
      body = { "output" => [ { "type" => "message", "content" => [ { "type" => "output_text", "text" => JSON.generate(@critic) } ] } ] }
      ImagegenHelpers::FakeResponse.new(@code, JSON.generate(body))
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @cache = File.join(@dir, ".cache")
    @roast = File.join(@dir, "roast")
    @out = StringIO.new
    @brief = File.join(@dir, "brief.txt")
    File.write(@brief, "A booking site for dog groomers")
    @shot = write_fixture(@dir, "home.png")
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    ENV.delete("CF_SECRETS_ENV")
  end

  def teardown
    ENV.delete("OPENAI_API_KEY")
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args, cache: @cache, http: RoastHttp.new)
    code = Roast::Cli.run([ "--brief", @brief, "--shot", @shot, "--cache", cache, "--out-dir", @roast, *args ], out: @out, http: http)
    [ code, @out.string, http ]
  end

  def test_transcript_reaches_the_critic_only_when_given
    transcript = File.join(@dir, "transcript.txt")
    File.write(transcript, "a [0.0s to 2.0s, 120 wpm]: One two")
    code, _text, http = run_cli("--transcript", transcript)
    assert_equal 0, code
    assert_includes http.requests.first.body, "Narration transcript and captions"
    assert_includes http.requests.first.body, "One two"
    _code, _text, plain = run_cli("--round", "2")
    refute_includes plain.requests.first.body, "Narration transcript"
  end

  def test_round_one_logs_json_and_markdown_after_the_estimate
    code, text, http = run_cli
    assert_equal 0, code
    assert_operator text.index("estimate"), :<, text.index("roast:")
    assert_equal CRITIC, JSON.parse(File.read(File.join(@roast, "round-1.json")))
    assert_includes File.read(File.join(@roast, "round-1.md")), "P1 (home): No clear action"
    assert_equal 1, http.requests.size
  end

  def test_request_carries_image_brief_schema_and_never_the_key_in_output
    _, text, http = run_cli
    req = http.requests.first
    body = JSON.parse(req.body)
    user = body["input"].last["content"]
    assert_equal "input_image", user[1]["type"]
    assert user[1]["image_url"].start_with?("data:image/png;base64,")
    assert_includes user[0]["text"], "dog groomers"
    assert_equal "json_schema", body["text"]["format"]["type"]
    assert_equal "Bearer sk-test-secret", req["Authorization"]
    refute_includes text, "sk-test-secret"
  end

  def test_model_defaults_and_is_overridable
    assert_equal "gpt-x", Roast.build_request(brief: "b", shots: [ @shot ], history: [], round: 1, model: "gpt-x")[:body][:model]
    assert_equal Roast::MODEL, Roast.build_request(brief: "b", shots: [ @shot ], history: [], round: 1)[:body][:model]
  end

  def test_second_round_sends_history_and_numbers_itself
    run_cli
    File.write(File.join(@roast, "round-1.response.json"), JSON.generate("accepted" => [ "home: One primary button" ]))
    _, _, http = run_cli(cache: File.join(@dir, ".cache2"))
    sent = JSON.parse(http.requests.first.body)["input"].last["content"][0]["text"]
    assert_includes sent, "Round 2."
    assert_includes sent, "No clear action"
    assert_includes sent, "One primary button"
    assert File.file?(File.join(@roast, "round-2.json"))
  end

  def test_rerun_of_same_inputs_is_cached_free_and_keyless
    run_cli("--round", "1", "--history", File.join(@dir, "none"))
    ENV.delete("OPENAI_API_KEY")
    @out.truncate(0)
    @out.rewind
    code, text, http = run_cli("--round", "1", "--history", File.join(@dir, "none"))
    assert_equal 0, code
    assert_empty http.requests
    assert_includes text, "$0.00"
  end

  def test_ceiling_refuses_before_any_call
    code, text, http = run_cli("--max-usd", "0.0001")
    assert_equal 1, code
    assert_includes text, "ceiling"
    assert_empty http.requests
  end

  def test_estimate_only_makes_no_call
    code, text, http = run_cli("--estimate-only")
    assert_equal 0, code
    assert_includes text, "roast estimate:"
    assert_empty http.requests
  end

  def test_missing_key_is_a_named_failure
    ENV.delete("OPENAI_API_KEY")
    code, text, = run_cli
    assert_equal 1, code
    assert_includes text, "OPENAI_API_KEY not set"
  end

  def test_http_error_reports_status_only
    code, text, = run_cli(http: RoastHttp.new(CRITIC, "500"))
    assert_equal 1, code
    assert_includes text, "HTTP 500"
    refute_includes text, "sk-test-secret"
  end

  def test_malformed_critic_is_rejected_and_not_logged
    code, text, = run_cli(http: RoastHttp.new(CRITIC.merge("score" => 11)))
    assert_equal 1, code
    assert_includes text, "score must be 0 to 10"
    refute File.exist?(File.join(@roast, "round-1.json"))
  end

  def test_usage_errors_exit_two
    assert_equal 2, Roast::Cli.run([ "--shot", @shot ], out: @out)
    assert_equal 2, Roast::Cli.run([ "--brief", @brief ], out: @out)
    bad = write_fixture(@dir, "x.gif")
    assert_equal 2, Roast::Cli.run([ "--brief", @brief, "--shot", bad ], out: @out)
  end

  def hist(round, score, priorities)
    issues = priorities.map { |p| { "priority" => p, "screen" => "s", "problem" => "p", "fix" => "f" } }
    { round: round, critic: { "score" => score, "issues" => issues }, response: nil }
  end

  def test_decide_stops_at_target_then_no_blockers_then_cap
    assert Roast.decide([ hist(1, 9, [ "P0" ]) ])[:stop]
    assert_match(/no P0 or P1/, Roast.decide([ hist(1, 6, [ "P2" ]) ])[:reason])
    assert_match(/cap #{Roast::DEFAULT_CAP}/, Roast.decide([ hist(4, 6, [ "P1" ]) ])[:reason])
    refute Roast.decide([ hist(2, 6, [ "P1" ]) ])[:stop]
    refute Roast.decide([])[:stop]
  end

  def test_decide_subcommand_reads_the_log
    run_cli
    out = StringIO.new
    assert_equal 0, Roast::Cli.run([ "decide", "--out-dir", @roast, "--target", "5" ], out: out)
    assert_includes out.string, "roast decision: stop: score 6 reached target 5"
  end

  def write_change(roast)
    File.write(File.join(@dir, "CHANGE.md"), "---\n#{JSON.generate({ "change_config" => { "design" => { "roast" => roast } } })}\n---\n")
  end

  def test_change_md_sets_model_and_ceiling_and_flags_win
    write_change({ "model" => "m-cfg", "max_usd" => 0.0001 })
    code, out, = run_cli("--repo", @dir)
    assert_equal 1, code
    assert_includes out, "ceiling"
    code, _, http = run_cli("--repo", @dir, "--max-usd", "5", "--model", "m-flag")
    assert_equal 0, code
    assert_equal "m-flag", JSON.parse(http.requests.last.body)["model"]
  end

  def test_change_md_model_reaches_the_request
    write_change({ "model" => "m-cfg" })
    code, _, http = run_cli("--repo", @dir)
    assert_equal 0, code
    assert_equal "m-cfg", JSON.parse(http.requests.last.body)["model"]
  end

  def test_unset_keys_keep_script_defaults
    write_change({ "model" => "m-cfg" })
    out = StringIO.new
    assert_equal 0, Roast::Cli.run([ "settings", "--repo", @dir ], out: out)
    assert_includes out.string, "auto true, target #{Roast::DEFAULT_TARGET}, rounds #{Roast::DEFAULT_CAP}, max_usd 0.50, model m-cfg"
  end

  def test_decide_reads_target_and_rounds_from_change_md
    run_cli
    write_change({ "target" => 5, "auto" => false })
    out = StringIO.new
    assert_equal 0, Roast::Cli.run([ "decide", "--repo", @dir, "--out-dir", @roast ], out: out)
    assert_includes out.string, "reached target 5"
    out = StringIO.new
    Roast::Cli.run([ "decide", "--repo", @dir, "--out-dir", @roast, "--target", "9.5" ], out: out)
    assert_includes out.string, "continue"
    out = StringIO.new
    Roast::Cli.run([ "settings", "--repo", @dir ], out: out)
    assert_includes out.string, "auto false"
  end
end
