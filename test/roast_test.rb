# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast"
require_relative "imagegen_helpers"
require_relative "enroll_helpers"

class RoastTest < Minitest::Test
  include ImagegenHelpers
  include EnrollHelpers

  CRITIC = {
    "score" => 6, "summary" => "Muddled hero.",
    "issues" => [
      { "priority" => "P1", "screen" => "home", "problem" => "No clear action", "fix" => "One primary button" },
      { "priority" => "P2", "screen" => "home", "problem" => "Tight leading", "fix" => "Raise line height" }
    ],
    "thirty_second_test" => { "verdict" => "partial", "reason" => "Purpose unclear" },
    "purpose_test" => [ { "outcome" => "Say what the groomer app does", "verdict" => "partial", "reason" => "Hero is vague" } ]
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
    enroll_home!("openai")
  end

  def teardown
    restore_home!
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args, cache: @cache, http: RoastHttp.new)
    review = args.include?("--no-default-review") ? [] : [ "--audience", "Dog groomers", "--purpose", "Book a slot" ]
    args -= [ "--no-default-review" ]
    code = Roast::Cli.run([ "--brief", @brief, "--shot", @shot, "--cache", cache, "--out-dir", @roast, *review, *args ], out: @out, http: http)
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

  def test_review_contract_reaches_the_request_and_flags_win_over_storyboard_and_change_md
    write_change({ "kind" => "promo", "audience" => "From CHANGE.md" })
    board = File.join(@dir, "storyboard.json")
    File.write(board, JSON.generate("review" => { "kind" => "demo", "audience" => "From storyboard", "purpose" => [ "Story outcome" ] }))
    _code, _text, http = run_cli("--repo", @dir, "--storyboard", board, "--kind", "explainer", "--no-default-review",
                                 "--purpose", "Flag outcome one", "--purpose", "Flag outcome two")
    body = http.requests.first.body
    assert_includes body, "Kind: explainer"
    assert_includes body, "Audience: From storyboard"
    assert_includes body, "1. Flag outcome one"
    assert_includes body, "2. Flag outcome two"
    refute_includes body, "Story outcome"
    refute_includes body, "From CHANGE.md"
  end

  def test_storyboard_and_change_md_fill_in_when_no_flags
    write_change({ "kind" => "explainer", "audience" => "From CHANGE.md" })
    board = File.join(@dir, "storyboard.json")
    File.write(board, JSON.generate("review" => { "purpose" => [ "Story outcome" ] }))
    _code, _text, http = run_cli("--repo", @dir, "--storyboard", board, "--no-default-review")
    assert_includes http.requests.first.body, "Kind: explainer"
    assert_includes http.requests.first.body, "Audience: From CHANGE.md"
    assert_includes http.requests.first.body, "1. Story outcome"
  end

  def test_refuses_without_audience_or_purpose_before_any_call
    code, out, http = run_cli("--no-default-review", "--purpose", "Something")
    assert_equal 1, code
    assert_includes out, "no audience"
    assert_empty http.requests
    @out = StringIO.new
    code, out, http = run_cli("--no-default-review", "--audience", "Somebody")
    assert_equal 1, code
    assert_includes out, "no purpose"
    assert_empty http.requests
  end

  def test_unknown_kind_is_refused
    code, out, = run_cli("--kind", "trailer")
    assert_equal 1, code
    assert_includes out, "kind must be one of"
  end

  def test_prompt_carries_anchors_purpose_test_and_production_facts
    prompt = Roast::SYSTEM_PROMPT
    assert_match(/3 means it fails its audience/, prompt)
    assert_match(/5 means it has a\s+blocking flaw/, prompt)
    assert_match(/9 means ship\s+it to this audience/, prompt)
    assert_match(/sidecar srt or vtt/, prompt)
    assert_match(/explainer:.*no call to action/m, prompt)
    refute_match(/first-time\s+visitor/, prompt)
  end

  def test_schema_is_strict_and_requires_purpose_test
    assert_equal false, Roast::SCHEMA[:additionalProperties]
    assert_includes Roast::SCHEMA[:required], "purpose_test"
    item = Roast::SCHEMA.dig(:properties, :purpose_test, :items)
    assert_equal false, item[:additionalProperties]
    assert_equal %w[outcome verdict reason], item[:required]
  end

  def test_issue_saving_is_a_required_nullable_object_of_nullable_counts
    item = Roast::SCHEMA.dig(:properties, :issues, :items)
    assert_empty item[:required].map(&:to_sym) - item[:properties].keys, "strict mode needs every property required"
    assert_includes item[:required], "saving"
    saving = item[:properties][:saving]
    assert_equal %w[object null], saving[:type]
    assert_equal false, saving[:additionalProperties]
    assert_equal %w[lines files deps], saving[:required]
    saving[:properties].each_value { |v| assert_equal %w[integer null], v[:type] }
    assert_match(/saving: estimated lines, files, deps removed/, Roast::SYSTEM_PROMPT)
  end

  def test_saving_renders_as_an_estimate_only_when_present
    issues = [ CRITIC["issues"][0].merge("saving" => { "lines" => 40, "files" => 2, "deps" => nil }),
               CRITIC["issues"][1].merge("saving" => nil) ]
    code, = run_cli(http: RoastHttp.new(CRITIC.merge("issues" => issues)))
    assert_equal 0, code
    md = File.read(File.join(@roast, "round-1.md"))
    assert_includes md, "Saving: ~40 lines, ~2 files (estimate)"
    assert_equal 1, md.scan("Saving:").size
  end

  def test_legacy_round_without_saving_still_validates_and_renders
    Roast.validate_critic!(CRITIC)
    refute_includes Roast.render_markdown(CRITIC, 1), "Saving:"
  end

  def test_malformed_saving_is_rejected
    [ { "lines" => -1, "files" => 0, "deps" => 0 }, { "lines" => 1 }, { "lines" => "5", "files" => nil, "deps" => nil }, 3 ].each do |bad|
      critic = CRITIC.merge("issues" => [ CRITIC["issues"][0].merge("saving" => bad) ])
      err = assert_raises(Roast::RequestError) { Roast.validate_critic!(critic) }
      assert_includes err.message, "saving is invalid"
    end
  end

  def test_critic_without_a_valid_purpose_test_is_rejected
    bad = CRITIC.merge("purpose_test" => [ { "outcome" => "x", "verdict" => "maybe", "reason" => "r" } ])
    code, = run_cli(http: RoastHttp.new(bad))
    assert_equal 1, code
  end

  def test_markdown_lists_each_purpose_outcome
    run_cli
    md = File.read(File.join(@roast, "round-1.md"))
    assert_includes md, "- partial: Say what the groomer app does (Hero is vague)"
  end

  def test_round_one_logs_json_and_markdown_after_the_estimate
    code, text, http = run_cli
    assert_equal 0, code
    assert_operator text.index("estimate"), :<, text.index("roast:")
    assert_equal Roast.normalize_critic(CRITIC, 1), JSON.parse(File.read(File.join(@roast, "round-1.json")))
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

  def test_aliases_resolve_and_full_ids_pass_through
    assert_equal "gpt-6.1-terra", Roast.resolve_model("terra")
    assert_equal "gpt-6.1-sol", Roast.resolve_model("sol")
    assert_equal "gpt-9-custom", Roast.resolve_model("gpt-9-custom")
  end

  def test_default_model_is_terra_for_text_kinds_and_sol_for_visual
    %w[email doc pr post diff code arch infra].each { |k| assert_equal "gpt-6.1-terra", Roast.default_model(k), k }
    [ nil, "explainer", "promo", "demo" ].each { |k| assert_equal "gpt-6.1-sol", Roast.default_model(k), k.inspect }
  end

  def test_model_chain_is_flag_then_env_then_config_then_default
    env = { "CF_ROAST_MODEL" => "terra" }
    assert_equal "gpt-6.1-sol", Roast.model_for(kind: "doc", flag: "sol", config: "terra", env: env)
    assert_equal "gpt-6.1-terra", Roast.model_for(kind: "doc", config: "sol", env: env)
    assert_equal "gpt-6.1-terra", Roast.model_for(kind: "doc", config: "terra", env: {})
    assert_equal "gpt-6.1-terra", Roast.model_for(kind: "doc", env: { "CF_ROAST_MODEL" => " " })
    assert_equal "gpt-6.1-sol", Roast.model_for(env: { "CF_ROAST_MODEL" => " " })
  end

  def test_any_shot_defaults_to_sol_unless_flag_env_or_config_says_otherwise
    assert_equal "gpt-6.1-sol", Roast.model_for(kind: "doc", env: {}, shots: true)
    assert_equal "gpt-6.1-terra", Roast.model_for(kind: "doc", env: {}, shots: false)
    assert_equal "gpt-6.1-terra", Roast.model_for(kind: "doc", flag: "terra", env: {}, shots: true)
    assert_equal "gpt-6.1-terra", Roast.model_for(kind: "doc", env: { "CF_ROAST_MODEL" => "terra" }, shots: true)
    assert_equal "gpt-6.1-terra", Roast.model_for(kind: "doc", config: "terra", env: {}, shots: true)
  end

  def test_doc_kind_with_a_shot_estimates_at_sol_rates
    code, text, http = run_cli("--kind", "doc", "--estimate-only")
    assert_equal 0, code
    assert_includes text, "1 image(s)"
    assert_includes text, "to gpt-6.1-sol"
    assert_empty http.requests
  end

  def test_effort_defaults_to_medium_in_the_body
    assert_equal({ "effort" => "medium" }, JSON.parse(JSON.generate(Roast.build_request(brief: "b", shots: [ @shot ], history: [], round: 1)[:body]))["reasoning"])
    _, _, http = run_cli("--model", "terra", "--effort", "high")
    body = JSON.parse(http.requests.last.body)
    assert_equal "gpt-6.1-terra", body["model"]
    assert_equal "high", body["reasoning"]["effort"]
  end

  def test_effort_none_on_sol_and_unknown_effort_are_refused
    code, out, http = run_cli("--model", "sol", "--effort", "none")
    assert_equal 2, code
    assert_includes out, "effort none is not supported on gpt-6.1-sol"
    assert_empty http.requests
    code, out, = run_cli("--effort", "turbo")
    assert_equal 2, code
    assert_includes out, "unknown effort"
    assert_equal "none", Roast.check_effort!("none", "gpt-6.1-terra")
  end

  def test_medium_effort_keeps_the_pre_effort_cache_key
    base = { brief: "b", shots: [ @shot ], history: [], round: 1, model: "gpt-6.1-sol" }
    legacy = WalkthroughCache.key({ model: "gpt-6.1-sol", brief: "b", round: 1, history: [], shots: [ Digest::SHA256.file(@shot).hexdigest ] })
    assert_equal legacy, Roast.request_key(**base)
    assert_equal legacy, Roast.request_key(**base, effort: "medium")
    refute_equal legacy, Roast.request_key(**base, effort: "high")
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
    unenroll!("openai")
    @out.truncate(0)
    @out.rewind
    code, text, http = with_enrolled { run_cli("--round", "1", "--history", File.join(@dir, "none")) }
    assert_equal 0, code
    assert_empty http.requests
    assert_includes text, "$0.00"
    assert_empty enroll_lines(text)
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

  def test_unenrolled_uncached_roast_exits_4_with_one_enroll_line
    unenroll!("openai")
    code, text, http = with_enrolled { run_cli }
    assert_equal 4, code
    assert_one_enroll_line(text, "openai")
    assert_empty http.requests
  end

  class RaisingHttp
    def initialize(error) = @error = error
    def request(_req) = raise(@error)
  end

  def test_transport_failures_become_request_errors
    [ Net::ReadTimeout.new, Net::OpenTimeout.new, Errno::ECONNRESET.new, EOFError.new, SocketError.new("dns"),
      OpenSSL::SSL::SSLError.new("tls") ].each do |error|
      raised = assert_raises(Roast::RequestError) { Roast.post({ url: Roast::RESPONSES_URL, body: {} }, RaisingHttp.new(error)) }
      assert_includes raised.message, error.class.name
    end
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

  def test_config_alias_resolves_in_settings_and_request
    write_change({ "model" => "terra" })
    out = StringIO.new
    assert_equal 0, Roast::Cli.run([ "settings", "--repo", @dir ], out: out)
    assert_includes out.string, "model gpt-6.1-terra"
    _, text, http = run_cli("--repo", @dir)
    assert_equal "gpt-6.1-terra", JSON.parse(http.requests.last.body)["model"]
    assert_includes text, "to gpt-6.1-terra at medium effort"
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
  # -- provider failures ------------------------------------------------------

  HeadResp = Struct.new(:code, :body, :headers) do
    def [](name) = (headers || {})[name]
  end

  # Answers each request with the next scripted response, then the critic.
  class ScriptedHttp
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def request(req)
      @requests << req
      @responses.shift || HeadResp.new("200", JSON.generate("output" => [ { "type" => "message", "content" => [ { "type" => "output_text", "text" => JSON.generate(CRITIC) } ] } ]))
    end
  end

  def key_error_line(text)
    text.lines.map { |l| JSON.parse(l) rescue nil }.compact.find { |h| h.is_a?(Hash) && h.key?("cf_key_error") }
  end

  def with_sleeps
    sleeps = []
    CfProviderError.sleeper = ->(s) { sleeps << s }
    yield sleeps
  ensure
    CfProviderError.sleeper = ->(s) { sleep(s) }
  end

  def test_revoked_key_exits_4_with_reason_revoked
    code, text, http = run_cli(http: ScriptedHttp.new(HeadResp.new("401", %({"error":{"message":"Incorrect API key sk-test-secret"}}))))
    assert_equal 4, code
    assert_equal "revoked", enroll_lines(text).first.dig("cf_enroll", "reason")
    assert_equal 1, http.requests.size
    refute_includes text, "sk-test-secret"
  end

  def test_insufficient_quota_exits_1_and_is_never_retried
    with_sleeps do |sleeps|
      body = %({"error":{"code":"insufficient_quota","message":"You exceeded your current quota"}})
      code, text, http = run_cli(http: ScriptedHttp.new(HeadResp.new("429", body)))
      assert_equal 1, code
      assert_equal "quota_exhausted", key_error_line(text).dig("cf_key_error", "class")
      assert_equal 1, http.requests.size
      assert_empty sleeps
    end
  end

  def test_rate_limit_honours_retry_after_then_succeeds
    with_sleeps do |sleeps|
      http = ScriptedHttp.new(HeadResp.new("429", "{}", { "retry-after" => "7" }), HeadResp.new("429", "{}", { "retry-after" => "900" }))
      code, text, = run_cli(http: http)
      assert_equal 0, code, text
      assert_equal [ 7.0, 60 ], sleeps
      assert_equal 3, http.requests.size
    end
  end

  def test_rate_limit_after_three_attempts_exits_1
    with_sleeps do
      http = ScriptedHttp.new(*Array.new(3) { HeadResp.new("429", "{}") })
      code, text, = run_cli(http: http)
      assert_equal 1, code
      assert_equal "rate_limited", key_error_line(text).dig("cf_key_error", "class")
      assert_equal 3, http.requests.size
    end
  end

  def test_bad_request_carries_the_provider_message
    code, text, = run_cli(http: ScriptedHttp.new(HeadResp.new("400", %({"error":{"message":"Invalid image_url"}}))))
    assert_equal 1, code
    assert_includes text, "Invalid image_url"
    assert_equal "bad_request", key_error_line(text).dig("cf_key_error", "class")
  end

  def test_server_error_exits_1_with_next_step
    code, text, = run_cli(http: ScriptedHttp.new(HeadResp.new("503", "upstream down")))
    assert_equal 1, code
    line = key_error_line(text)
    assert_equal "server", line.dig("cf_key_error", "class")
    assert_includes line.dig("cf_key_error", "next_step"), "rerun later"
  end

  # -- image fit and truncated or refused answers -----------------------------

  def answer(text: nil, status: "completed", reason: nil, refusal: nil)
    content = refusal ? [ { "type" => "refusal", "refusal" => refusal } ] : [ { "type" => "output_text", "text" => text || JSON.generate(CRITIC) } ]
    body = { "status" => status, "output" => [ { "type" => "message", "content" => content } ] }
    body["incomplete_details"] = { "reason" => reason } if reason
    HeadResp.new("200", JSON.generate(body))
  end

  def truncated = answer(text: '{"score": 6, "summ', status: "incomplete", reason: "max_output_tokens")

  # A PNG whose header claims width x height; only the header is ever read.
  def big_png(name, width, height)
    File.join(@dir, name).tap do |path|
      File.binwrite(path, "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + [ width, height ].pack("NN") + "\x08\x02\x00\x00\x00".b + name)
    end
  end

  # Stands in for docker: records argv and writes the file the container would.
  class FakeDocker
    Status = Struct.new(:ok) do
      def success? = ok
    end

    attr_reader :calls

    def initialize(ok: true)
      @ok = ok
      @calls = []
    end

    def call(argv)
      @calls << argv
      work = argv.join(" ")[%r{source=([^"]+)",target=/work}, 1]
      File.binwrite(File.join(work, File.basename(argv.last)), "small") if @ok
      [ @ok ? "" : "docker: daemon down", Status.new(@ok) ]
    end
  end

  def run_fit(shot, *extra, docker:, http: RoastHttp.new)
    out = StringIO.new
    code = Roast::Cli.run([ "--brief", @brief, "--shot", shot, "--cache", @cache, "--out-dir", @roast, "--audience", "Dog groomers", "--purpose", "Book a slot", *extra ],
                          out: out, http: http, docker: docker)
    [ code, out.string, http ]
  end

  def test_dimensions_read_png_jpeg_and_webp_headers
    assert_equal [ 3000, 1200 ], RoastImageFit.dimensions(big_png("a.png", 3000, 1200))
    jpg = File.join(@dir, "a.jpg")
    File.binwrite(jpg, "\xFF\xD8\xFF\xE0\x00\x04ab\xFF\xC0\x00\x11\x08\x05\xDC\x0F\xA0".b)
    assert_equal [ 4000, 1500 ], RoastImageFit.dimensions(jpg)
    webp = File.join(@dir, "a.webp")
    File.binwrite(webp, "RIFF\x00\x00\x00\x00WEBPVP8X\x0A\x00\x00\x00\x00\x00\x00\x00".b + [ 2999 ].pack("V")[0, 3] + [ 999 ].pack("V")[0, 3])
    assert_equal [ 3000, 1000 ], RoastImageFit.dimensions(webp)
    assert_nil RoastImageFit.dimensions(@shot)
    assert_equal [ 2048, 820 ], RoastImageFit.target(3000, 1200)
  end

  def test_oversized_shot_is_fitted_with_the_pinned_ffmpeg_and_keeps_its_cache_key
    shot = big_png("wide.png", 4096, 1024)
    docker = FakeDocker.new
    code, text, http = run_fit(shot, docker: docker)
    assert_equal 0, code, text
    assert_includes text, "wide.png is 4096x1024, sending a 2048x512 copy"
    argv = docker.calls.first
    assert_includes argv, ChangeDocker::FFMPEG_IMAGE
    assert_includes argv, "scale=2048:512:flags=lanczos"
    sent = JSON.parse(http.requests.first.body).dig("input", 1, "content", 1, "image_url")
    assert_equal "data:image/png;base64,#{Base64.strict_encode64('small')}", sent
    _code, again, = run_fit(shot, "--out-dir", File.join(@dir, "again"), docker: docker)
    assert_includes again, "1 call (cached)"
    assert_equal 1, docker.calls.size, "a cache hit keyed on the original never refits"
  end

  def test_small_shot_never_calls_docker
    docker = FakeDocker.new
    code, _text, = run_fit(big_png("ok.png", 2048, 1500), docker: docker)
    assert_equal 0, code
    assert_empty docker.calls
  end

  def test_failed_fit_is_named_and_nothing_is_sent
    code, text, http = run_fit(big_png("huge.png", 5000, 5000), docker: FakeDocker.new(ok: false))
    assert_equal 1, code
    assert_includes text, "roast image fit failed for huge.png (5000x5000)"
    assert_empty http.requests
  end

  def test_truncated_answer_retries_once_at_16000_then_succeeds
    code, text, http = run_cli(http: ScriptedHttp.new(truncated))
    assert_equal 0, code, text
    assert_equal [ 4000, 16_000 ], http.requests.map { |r| JSON.parse(r.body)["max_output_tokens"] }
    assert_match(/truncated at max_output_tokens \(4000\), retrying once at 16000: about \$\d+\.\d\d more/, text)
    assert_operator text.index("retrying once"), :>, text.index("roast estimate:")
    assert File.file?(File.join(@roast, "raw-1.json"))
  end

  def test_second_truncation_fails_with_the_named_message
    code, text, http = run_cli(http: ScriptedHttp.new(truncated, truncated))
    assert_equal 1, code
    assert_equal 2, http.requests.size
    assert_includes text, "roast response truncated at max_output_tokens"
    assert_includes text, "raw response at #{File.join(@roast, 'raw-1.json')}"
    refute File.file?(File.join(@roast, "round-1.json"))
  end

  def test_retry_is_held_to_the_ceiling
    code, text, http = run_cli("--max-usd", "0.10", http: ScriptedHttp.new(truncated))
    assert_equal 1, code, text
    assert_equal 1, http.requests.size
    assert_includes text, "ceiling"
  end

  def test_refusal_is_named_and_its_raw_answer_saved_scrubbed
    leaked = "sk-proj-#{'A' * 30}"
    code, text, = run_cli(http: ScriptedHttp.new(answer(refusal: "I cannot help with that #{leaked}")))
    assert_equal 1, code
    assert_includes text, "roast critic refused: I cannot help with that"
    raw = File.read(File.join(@roast, "raw-1.json"))
    assert_includes raw, "refusal"
    refute_includes raw, leaked
    refute_includes text, leaked
  end

  def test_invalid_json_saves_the_raw_answer
    code, text, = run_cli(http: ScriptedHttp.new(answer(text: "{not json")))
    assert_equal 1, code
    assert_includes text, "roast response was not valid JSON; raw response at"
    assert_includes File.read(File.join(@roast, "raw-1.json")), "{not json"
  end
end
