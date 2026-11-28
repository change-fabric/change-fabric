# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../scripts/roast"

# The canonical round-N.response.json shape and the `roast.rb respond` helper
# that writes one from round-N.json.
class RoastResponseTest < Minitest::Test
  CRITIC = {
    "score" => 6,
    "issues" => [
      { "priority" => "P1", "where" => "Phase 2", "problem" => "No rollback", "fix" => "Add a rollback step" },
      { "priority" => "P2", "screen" => "goal", "problem" => "Vague outcome", "fix" => "Name the metric" }
    ]
  }.freeze

  def setup
    @dir = Dir.mktmpdir
    @out = StringIO.new
    File.write(File.join(@dir, "round-1.json"), JSON.generate(CRITIC))
  end

  def teardown = FileUtils.rm_rf(@dir)

  def respond(*args) = Roast::Cli.run([ "respond", "--out-dir", @dir, "--round", "1", *args ], out: @out)

  def written = JSON.parse(File.read(File.join(@dir, "round-1.response.json")))

  def verdicts(rows)
    path = File.join(@dir, "v.json")
    File.write(path, JSON.generate(rows))
    path
  end

  def test_accept_all_writes_a_valid_response_per_issue
    assert_equal 0, respond("--accept-all"), @out.string
    rows = written["responses"]
    assert_equal [ "Phase 2", "goal" ], rows.map { |r| r["where"] }
    assert_equal %w[accept accept], rows.map { |r| r["verdict"] }
    assert_equal "Add a rollback step", rows.first["change"]
    assert_empty RoastResponse.problems(written, CRITIC)
  end

  def test_respond_keeps_the_followups_ledger_already_in_the_file
    path = File.join(@dir, "round-1.response.json")
    File.write(path, JSON.generate("responses" => [], "followups" => [ { "id" => "f1", "outcome" => "mitigated" } ]))
    assert_equal 0, respond("--accept-all"), @out.string
    assert_equal [ { "id" => "f1", "outcome" => "mitigated" } ], written["followups"]
    assert_equal 2, written["responses"].size
  end

  def test_verdicts_file_maps_one_verdict_per_issue_in_order
    file = verdicts([ { "verdict" => "accept", "change" => "Added rollback" },
                      { "verdict" => "rebut", "reason" => "goal.md names it" } ])
    assert_equal 0, respond("--verdicts", file), @out.string
    assert_equal "Added rollback", written["responses"].first["change"]
    assert_equal "rebut", written["responses"].last["verdict"]
    assert_equal "goal.md names it", written["responses"].last["reason"]
  end

  def test_verdicts_file_with_a_wrong_count_is_refused
    assert_equal 1, respond("--verdicts", verdicts([ { "verdict" => "accept" } ]))
    refute File.exist?(File.join(@dir, "round-1.response.json"))
  end

  def test_rebut_without_reason_is_refused
    assert_equal 1, respond("--verdicts", verdicts([ { "verdict" => "accept" }, { "verdict" => "rebut" } ]))
    assert_match "reason", @out.string
  end

  def test_needs_exactly_one_mode_and_a_round_file
    assert_equal 2, respond
    assert_equal 2, respond("--accept-all", "--verdicts", "x.json")
    assert_equal 1, Roast::Cli.run([ "respond", "--out-dir", @dir, "--round", "9", "--accept-all" ], out: @out)
  end

  def test_a_round_with_no_issues_gets_an_empty_list
    File.write(File.join(@dir, "round-1.json"), JSON.generate("score" => 9, "issues" => []))
    assert_equal 0, respond("--accept-all")
    assert_equal({ "responses" => [] }, written)
  end

  def test_problems_name_each_shape_fault
    assert_match "responses", RoastResponse.problems({}, CRITIC).first
    bad = { "responses" => [ { "problem" => "x", "verdict" => "maybe" } ] }
    found = RoastResponse.problems(bad, CRITIC).join("\n")
    assert_match "verdict", found
    assert_match "2 issue", found
  end

  def test_legacy_screen_key_is_accepted
    ok = { "responses" => CRITIC["issues"].map { |i| { "screen" => "x", "problem" => i["problem"], "verdict" => "accept", "change" => "c" } } }
    assert_empty RoastResponse.problems(ok, CRITIC)
  end
end
