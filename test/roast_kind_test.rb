# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast"
require_relative "imagegen_helpers"

# The CLI-only fidelity kind (spec 0.18.0 design targets): prototype and
# reference stills fed in pairs. Every paid call is stubbed with a fake HTTP
# transport; nothing here reaches the network.
class RoastKindTest < Minitest::Test
  include ImagegenHelpers

  CRITIC = { "score" => 9, "summary" => "Reads as the app.", "issues" => [],
             "thirty_second_test" => { "verdict" => "pass", "reason" => "r" },
             "purpose_test" => [ { "outcome" => "o", "verdict" => "pass", "reason" => "r" } ] }.freeze

  class CriticHttp < ImagegenHelpers::FakeHttp
    def request(req)
      @requests << req
      body = { "output" => [ { "type" => "message", "content" => [ { "type" => "output_text", "text" => JSON.generate(CRITIC) } ] } ] }
      ImagegenHelpers::FakeResponse.new("200", JSON.generate(body))
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @brief = File.join(@dir, "brief.txt")
    File.write(@brief, "Admin analytics screen for the portal target")
    @proto = write_fixture(@dir, "proto-analytics.png")
    @ref = write_fixture(@dir, "ref-analytics.png")
    @out = StringIO.new
    ENV["OPENAI_API_KEY"] = "sk-test-secret"
    ENV.delete("CF_SECRETS_ENV")
  end

  def teardown
    ENV.delete("OPENAI_API_KEY")
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args, http: CriticHttp.new("200"))
    code = Roast::Cli.run([ "--brief", @brief, "--cache", File.join(@dir, ".cache"), "--out-dir", File.join(@dir, "roast"), *args ],
                          out: @out, http: http)
    [ code, @out.string, http ]
  end

  def test_fidelity_is_a_cli_kind_never_inferred
    assert_includes RoastKind::CLI_KINDS, "fidelity"
    assert_includes Roast::KINDS, "fidelity"
    refute_includes ChangeSchema::REVIEW_KINDS, "fidelity", "CHANGE.md does not accept it in this bump"
    assert_raises(RoastKind::Ambiguous) { RoastKind.infer(texts: [ [ "x.md", "plain words" ] ]) }
  end

  def test_pair_parsing
    assert_equal [ "a.png", "b.png" ], Roast.parse_pair("a.png=b.png")
    assert_raises(Roast::UsageError) { Roast.parse_pair("a.png") }
    assert_raises(Roast::UsageError) { Roast.parse_pair("=b.png") }
    assert_match(/1\. prototype a\.png against reference b\.png/, Roast.pair_note([ %w[dir/a.png dir/b.png] ]))
  end

  def test_pairs_feed_both_stills_in_order_with_the_pairing_in_the_brief
    code, text, http = run_cli("--pair", "#{@proto}=#{@ref}", "--estimate-only")
    assert_equal 0, code
    assert_includes text, "2 image(s)", "the estimate is printed before any call"
    assert_empty http.requests
    code, _text, http = run_cli("--pair", "#{@proto}=#{@ref}")
    assert_equal 0, code
    body = http.requests.first.body
    assert_includes body, "Kind: fidelity"
    assert_includes body, "prototype proto-analytics.png against reference ref-analytics.png"
    assert_includes body, Roast::FIDELITY_PURPOSE
    assert_operator body.index("proto-analytics.png"), :<, body.index("ref-analytics.png")
  end

  def test_fidelity_kind_without_a_pair_and_a_pair_with_another_kind_are_usage_errors
    code, = run_cli("--kind", "fidelity", "--shot", @proto)
    assert_equal 2, code
    @out = StringIO.new
    code, = run_cli("--kind", "doc", "--pair", "#{@proto}=#{@ref}", "--audience", "a", "--purpose", "p")
    assert_equal 2, code
  end

  def test_sensitive_terms_scan_still_runs_before_the_call
    File.write(@brief, "Analytics for Examplecorp")
    terms = File.join(@dir, "terms.txt")
    File.write(terms, "Examplecorp\n")
    ENV["CF_SENSITIVE_TERMS_FILE"] = terms
    code, _text, http = run_cli("--pair", "#{@proto}=#{@ref}")
    refute_equal 0, code
    assert_empty http.requests
  ensure
    ENV.delete("CF_SENSITIVE_TERMS_FILE")
  end
end
