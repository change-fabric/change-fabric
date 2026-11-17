# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast"
require_relative "../scripts/walkthrough_roast"
require_relative "imagegen_helpers"
require_relative "enroll_helpers"

# The film review scope, stable issue ids and severity, and the respond scaffold.
class RoastScopeTest < Minitest::Test
  include ImagegenHelpers
  include EnrollHelpers

  CRITIC = {
    "score" => 6, "summary" => "Tight crops.",
    "issues" => [
      { "priority" => "P0", "where" => "intro", "problem" => "The crop hides the button. It reads as broken.", "fix" => "Widen" },
      { "priority" => "P1", "where" => "map", "problem" => "Narration names a tab not on screen.", "fix" => "Retime" },
      { "priority" => "P1", "where" => "list", "problem" => "Cue split mid word.", "fix" => "Rejoin" }
    ],
    "product_notes" => [ { "where" => "map", "note" => "Low contrast pins" } ],
    "thirty_second_test" => { "verdict" => "pass", "reason" => "Clear" },
    "purpose_test" => []
  }.freeze

  class Http < ImagegenHelpers::FakeHttp
    def request(req)
      @requests << req
      body = { "output" => [ { "type" => "message", "content" => [ { "type" => "output_text", "text" => JSON.generate(CRITIC) } ] } ] }
      ImagegenHelpers::FakeResponse.new(@code, JSON.generate(body))
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @roast = File.join(@dir, "roast")
    @brief = File.join(@dir, "brief.txt")
    File.write(@brief, "A film of a shipped app")
    @shot = write_fixture(@dir, "home.png")
    @out = StringIO.new
    enroll_home!("openai")
  end

  def teardown
    restore_home!
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args, http: Http.new("200"))
    code = Roast::Cli.run([ "--brief", @brief, "--shot", @shot, "--cache", File.join(@dir, ".cache"), "--out-dir", @roast,
                            "--audience", "Buyers", "--purpose", "See the app", *args ], out: @out, http: http)
    [ code, http ]
  end

  def test_film_scope_and_alias_steer_the_prompt
    review = Roast.resolve_review(flags: { audience: "A", purpose: [ "B" ], scope: "as_shipped" })
    assert_equal "film", review[:scope]
    assert_includes Roast.review_text(review), "Scope: film"
    plain = Roast.resolve_review(flags: { audience: "A", purpose: [ "B" ] })
    refute plain.key?(:scope)
    refute_includes Roast.review_text(plain), "Scope: film"
    assert_raises(Roast::ReviewError) { Roast.resolve_review(flags: { audience: "A", purpose: [ "B" ], scope: "nope" }) }
    assert_includes Roast::SCHEMA[:required], "product_notes"
  end

  def test_cli_scope_flag_reaches_the_request
    code, http = run_cli("--scope", "film")
    assert_equal 0, code
    assert_includes http.requests.first.body, "Scope: film"
  end

  def test_round_file_carries_ids_severity_and_product_notes_that_never_block
    Roast.write_round(@roast, 1, CRITIC.merge("issues" => CRITIC["issues"].take(0)))
    md = File.read(File.join(@roast, "round-1.md"))
    assert_includes md, "Product notes (not scored)"
    assert Roast.decide(Roast.load_history(@roast))[:stop], "product notes must not count as blockers"

    Roast.write_round(@roast, 2, CRITIC)
    issues = JSON.parse(File.read(File.join(@roast, "round-2.json")))["issues"]
    assert_equal %w[R2-P0-1 R2-P1-1 R2-P1-2], issues.map { |i| i["id"] }
    assert_equal %w[P0 P1 P1], issues.map { |i| i["severity"] }
  end

  def test_old_round_files_normalize_without_ids
    old = [ { "priority" => "P1", "screen" => "home", "problem" => "x", "fix" => "y" } ]
    issue = Roast.normalize_issues(old, 3).first
    assert_equal "R3-P1-1", issue["id"]
    assert_equal "P1", issue["severity"]
    assert_equal "R9-P0-1", Roast.normalize_issues([ { "priority" => "P0", "id" => "R9-P0-1" } ], 1).first["id"]
  end

  def test_respond_scaffolds_and_refuses_to_overwrite
    FileUtils.mkdir_p(@roast)
    File.write(File.join(@roast, "round-1.json"), JSON.generate(CRITIC))
    assert_equal 0, Roast::Cli.run([ "respond", "--out-dir", @roast ], out: @out)
    path = File.join(@roast, "round-1.response.json")
    scaffold = JSON.parse(File.read(path))
    assert_equal 1, scaffold["round"]
    first = scaffold["responses"].first
    assert_equal({ "id" => "R1-P0-1", "severity" => "P0", "where" => "intro", "summary" => "The crop hides the button.",
                   "verdict" => "", "reason" => "" }, first)
    assert_equal 3, scaffold["responses"].size
    assert_equal 2, Roast::Cli.run([ "respond", "--out-dir", @roast ], out: @out)
    assert_equal 0, Roast::Cli.run([ "respond", "--out-dir", @roast, "--force" ], out: @out)
  end

  def test_rebuttal_by_id_clears_a_blocker
    FileUtils.mkdir_p(@roast)
    File.write(File.join(@roast, "round-1.json"), JSON.generate(CRITIC))
    responses = Roast.response_scaffold(CRITIC, 1)
    responses["responses"].each { |r| r.merge!("verdict" => "rebut", "reason" => "product design, out of scope") if r["id"] == "R1-P0-1" }
    File.write(File.join(@roast, "round-1.response.json"), JSON.generate(responses))
    open = WalkthroughRoast.open_blockers(Roast.load_history(@roast)).map { |i| i["id"] }
    assert_equal %w[R1-P1-1 R1-P1-2], open
  end

  def test_live_board_defaults_to_film_scope
    review = { "audience" => "A", "purpose" => [ "B" ] }
    live = { "review" => review, "scenes" => [ { "id" => "a", "screen" => { "url" => "https://app.localhost/" } } ] }
    mock = { "review" => review, "scenes" => [ { "id" => "a", "screen" => { "html" => "a.html" } } ] }
    assert_equal "film", WalkthroughRoast.review(live)[:scope]
    refute WalkthroughRoast.review(mock).key?(:scope)
    assert_equal "product", WalkthroughRoast.review(live.merge("review" => review.merge("scope" => "product")))[:scope]
  end

  # Intended: the film default changes the prompt, so a live board's existing
  # round re-keys (and re-runs once); a board with no scope keeps its key.
  def test_film_default_rekeys_live_rounds_and_leaves_unscoped_keys_alone
    base = { brief: "b", shots: [], history: [], round: 1 }
    review = { "audience" => "A", "purpose" => [ "B" ] }
    live = { "review" => review, "scenes" => [ { "id" => "a", "screen" => { "url" => "https://app.localhost/" } } ] }
    old = Roast.request_key(**base, review: Roast.resolve_review(storyboard: review))
    refute_equal old, Roast.request_key(**base, review: WalkthroughRoast.review(live))
    mock = { "review" => review, "scenes" => [ { "id" => "a", "screen" => { "html" => "a.html" } } ] }
    assert_equal old, Roast.request_key(**base, review: WalkthroughRoast.review(mock))
  end
end
