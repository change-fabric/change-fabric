# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast"
require_relative "../scripts/walkthrough_storyboard"
require_relative "imagegen_helpers"

class RoastTextTest < Minitest::Test
  include ImagegenHelpers

  EMAIL = "Subject: Budget sign-off\nTo: team@example.test\n\nHi all, please approve the budget by Friday."
  WHERE_CRITIC = {
    "score" => 6, "summary" => "Buried ask.",
    "issues" => [ { "priority" => "P1", "where" => "paragraph 2", "problem" => "No deadline", "fix" => "State the date" } ],
    "thirty_second_test" => { "verdict" => "partial", "reason" => "Ask unclear" },
    "purpose_test" => [ { "outcome" => "Approve by Friday", "verdict" => "partial", "reason" => "Date buried" } ]
  }.freeze

  LEGACY_CRITIC = WHERE_CRITIC.merge(
    "issues" => [ { "priority" => "P1", "screen" => "home", "problem" => "x", "fix" => "y" } ]
  ).freeze

  # A Responses-API reply wrapping the critic JSON.
  class RoastHttp < ImagegenHelpers::FakeHttp
    def initialize(critic)
      super("200")
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
    File.write(@brief, "A budget request")
    @draft = File.join(@dir, "draft.md")
    File.write(@draft, EMAIL)
    @shot = write_fixture(@dir, "home.png")
    @terms = File.join(@dir, "terms.txt")
    ENV["CF_SENSITIVE_TERMS_FILE"] = @terms
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    ENV.delete("CF_SECRETS_ENV")
  end

  def teardown
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("CF_SENSITIVE_TERMS_FILE")
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args, http: RoastHttp.new(WHERE_CRITIC))
    code = Roast::Cli.run([ "--brief", @brief, "--cache", @cache, "--out-dir", @roast,
                            "--audience", "Finance leads", "--purpose", "Approve by Friday", *args ], out: @out, http: http)
    [ code, @out.string, http ]
  end

  def test_text_only_request_has_the_text_and_no_images
    code, text, http = run_cli("--text", @draft, "--kind", "email")
    assert_equal 0, code
    body = JSON.parse(http.requests.first.body)
    parts = body.dig("input", 1, "content")
    assert_equal [ "input_text" ], parts.map { |p| p["type"] }.uniq
    assert_includes parts.first["text"], "Text under review (1 of 1, draft.md)"
    assert_includes parts.first["text"], "approve the budget by Friday"
    assert_includes parts.first["text"], "Kind: email"
    refute_includes parts.first["text"], "Screens, in order"
    assert_includes text, "1 text(s)"
    assert_includes File.read(File.join(@roast, "round-1.md")), "(paragraph 2)"
  end

  def test_mixed_text_and_shot_sends_both
    code, _text, http = run_cli("--text", @draft, "--shot", @shot, "--kind", "email")
    assert_equal 0, code
    parts = JSON.parse(http.requests.first.body).dig("input", 1, "content")
    assert_equal %w[input_text input_image], parts.map { |p| p["type"] }
  end

  def test_needs_a_shot_or_text
    code, text, = run_cli("--kind", "email")
    assert_equal 2, code
    assert_includes text, "--shot or --text"
  end

  def test_where_and_screen_both_work_in_critic_output_and_helpers
    legacy = { "screen" => "home" }
    assert_equal "home", Roast.location(legacy)
    assert_equal "p1", Roast.location({ "where" => "p1", "screen" => "home" })
    assert_includes Roast::SCHEMA.dig(:properties, :issues, :items, :required), "where"
    refute Roast::SCHEMA.dig(:properties, :issues, :items, :properties).key?(:screen)
    assert_equal false, Roast::SCHEMA.dig(:properties, :issues, :items, :additionalProperties)
    code, = run_cli("--text", @draft, "--kind", "email", http: RoastHttp.new(LEGACY_CRITIC))
    assert_equal 0, code
    bad = WHERE_CRITIC.merge("issues" => [ { "priority" => "P1", "problem" => "x", "fix" => "y" } ])
    FileUtils.rm_rf(@cache)
    code, = run_cli("--text", @draft, "--kind", "email", http: RoastHttp.new(bad))
    assert_equal 1, code
  end

  def test_text_kinds_are_accepted_and_prompted
    assert_equal %w[email doc pr post], Roast::KINDS - %w[explainer promo demo]
    %w[email doc pr post].each { |k| assert_match(/#{k}: /, Roast::SYSTEM_PROMPT) }
    assert_match(/email: is the ask clear, is the deadline stated/, Roast::SYSTEM_PROMPT)
  end

  def test_kind_is_inferred_and_reported
    code, text, http = run_cli("--text", @draft)
    assert_equal 0, code
    assert_includes text, "roast kind: email (inferred, confidence high)"
    assert_includes http.requests.first.body, "Kind: email"
  end

  def test_declared_kind_skips_inference
    _code, text, = run_cli("--text", @draft, "--kind", "doc")
    refute_includes text, "inferred"
  end

  def test_ambiguous_kind_exits_three_without_a_call
    File.write(@draft, "Plain paragraph with nothing else.")
    code, text, http = run_cli("--text", @draft)
    assert_equal 3, code
    assert_includes text, "roast: kind is ambiguous: candidates email, doc, pr, post; pass --kind"
    assert_empty http.requests
  end

  def test_image_only_without_cues_keeps_no_kind
    code, text, = run_cli("--shot", @shot)
    assert_equal 0, code
    refute_includes text, "inferred"
  end

  def test_inference_cases
    cases = {
      "reply.eml" => [ "plain body", "email" ],
      "n.txt" => [ "Hello Sam,\n\nCould you review this?\n\nThanks", "email" ],
      "pr.md" => [ "## Summary\nAdds x.\n\n## Test plan\n- run it\n\nCloses #12", "pr" ],
      "post.txt" => [ "Shipped a thing today. #buildinpublic", "post" ],
      "doc.md" => [ "# Guide\n\nIntro.\n\n## Setup\nSteps.\n\n## Usage\nMore.", "doc" ]
    }
    cases.each do |name, (body, kind)|
      found = RoastKind.infer(texts: [ [ name, body ] ])
      assert_equal kind, found.kind, name
      assert_includes %w[high medium], found.confidence
    end
  end

  def test_conflicting_texts_and_storyboards_are_ambiguous
    err = assert_raises(RoastKind::Ambiguous) do
      RoastKind.infer(texts: [ [ "a.eml", "x" ], [ "b.md", "## Test plan\nrun" ] ])
    end
    assert_equal %w[email pr], err.candidates
    promo = { "scenes" => [ { "narration" => { "text" => "Sign up today." } } ] }
    assert_equal "promo", RoastKind.infer(storyboard: promo).kind
    both = { "scenes" => [ { "narration" => { "text" => "Click here, then install it." } } ] }
    assert_raises(RoastKind::Ambiguous) { RoastKind.infer(storyboard: both) }
    assert_raises(RoastKind::Ambiguous) { RoastKind.infer(storyboard: { "scenes" => [] }) }
  end

  def test_infer_subcommand
    out = StringIO.new
    assert_equal 0, Roast::Cli.run([ "infer", "--text", @draft ], out: out)
    assert_includes out.string, "roast kind: email"
    File.write(@draft, "Nothing.")
    out = StringIO.new
    assert_equal 3, Roast::Cli.run([ "infer", "--text", @draft ], out: out)
  end

  def test_sensitive_term_refuses_then_overrides
    File.write(@terms, "# list\nBudget Sign-Off\nunrelated\n")
    code, text, http = run_cli("--text", @draft, "--kind", "email")
    assert_equal 1, code
    assert_includes text, "1 sensitive term(s)"
    refute_match(/budget sign-off/i, text)
    assert_empty http.requests
    code, _text, http = run_cli("--text", @draft, "--kind", "email", "--allow-sensitive")
    assert_equal 0, code
    assert_equal 1, http.requests.size
  end

  def test_sensitive_term_in_brief_refuses
    File.write(@terms, "budget request")
    code, text, http = run_cli("--text", @draft, "--kind", "email")
    assert_equal 1, code
    refute_match(/budget request/i, text)
    assert_empty http.requests
    code, = run_cli("--text", @draft, "--kind", "email", "--allow-sensitive")
    assert_equal 0, code
  end

  def test_sensitive_term_in_review_contract_refuses
    File.write(@terms, "finance leads")
    code, text, http = run_cli("--text", @draft, "--kind", "email")
    assert_equal 1, code
    assert_includes text, "1 sensitive term(s)"
    refute_match(/finance leads/i, text)
    assert_empty http.requests
    code, = run_cli("--text", @draft, "--kind", "email", "--allow-sensitive")
    assert_equal 0, code
  end

  def test_critique_called_directly_is_scanned_and_override_reaches_it
    File.write(@terms, "finance leads")
    args = { brief: "A brief", shots: [ @shot ], history: [], round: 1, cache_root: @cache,
             review: { audience: "Finance leads", purpose: [ "Approve" ], kind: "explainer" } }
    http = RoastHttp.new(WHERE_CRITIC)
    err = assert_raises(Roast::SensitiveError) { Roast.critique(**args, http: http) }
    refute_match(/finance leads/i, err.message)
    assert_empty http.requests
    Roast.critique(**args, http: http, allow_sensitive: true)
    assert_equal 1, http.requests.size
  end

  def test_unreadable_terms_file_raises_but_missing_is_empty
    assert_equal [], SensitiveTerms.load(File.join(@dir, "absent.txt"))
    File.write(@terms, "")
    FileUtils.rm_f(@terms)
    Dir.mkdir(@terms)
    assert_raises(SystemCallError) { SensitiveTerms.load(@terms) }
    code, text, http = run_cli("--text", @draft, "--kind", "email")
    assert_equal 1, code
    assert_includes text, "error:"
    assert_empty http.requests
  end

  def test_board_verdict_accepts_string_or_hash_narration
    board = { "scenes" => [ { "narration" => "Sign up today." }, { "narration" => { "text" => "Sign up today." } }, { "id" => "x" } ] }
    assert_equal "promo", RoastKind.infer(storyboard: board, texts: []).kind
  end

  def test_storyboard_review_kind_is_video_only
    assert_equal %w[explainer promo demo], ChangeSchema::VIDEO_REVIEW_KINDS
    assert_empty WalkthroughStoryboard.review_errors({ "kind" => "promo" })
    assert_match(/review.kind must be one of explainer, promo, demo/, WalkthroughStoryboard.review_errors({ "kind" => "email" }).first)
  end

  def test_sensitive_term_in_transcript_refuses_and_absent_list_skips
    transcript = File.join(@dir, "t.txt")
    File.write(transcript, "Narrator mentions Acme Widgets")
    File.write(@terms, "acme widgets")
    code, = run_cli("--text", @draft, "--kind", "email", "--transcript", transcript)
    assert_equal 1, code
    File.delete(@terms)
    code, = run_cli("--text", @draft, "--kind", "email", "--transcript", transcript)
    assert_equal 0, code
  end

  def test_cache_key_and_spend_include_text_digests
    base = { brief: "b", shots: [], history: [], round: 1 }
    other = File.join(@dir, "other.md")
    File.write(other, "different")
    k1 = Roast.request_key(**base, texts: [ @draft ])
    refute_equal k1, Roast.request_key(**base, texts: [ other ])
    refute_equal k1, Roast.request_key(**base)
    assert_equal Roast.request_key(**base), Roast.request_key(**base, texts: [])
    assert_operator Roast.estimate(**base.slice(:brief, :shots, :history), texts: [ @draft ])[:tokens], :>, Roast.estimate(**base.slice(:brief, :shots, :history))[:tokens]
    run_cli("--text", @draft, "--kind", "email", "--round", "1", "--history", File.join(@dir, "none"))
    ENV.delete("OPENAI_API_KEY")
    code, text, http = run_cli("--text", @draft, "--kind", "email", "--round", "1", "--history", File.join(@dir, "none"))
    assert_equal 0, code
    assert_empty http.requests
    assert_includes text, "$0.00"
  end
end
