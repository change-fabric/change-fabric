# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "git_fixture"
require_relative "../scripts/simplicity_signals"

# verdict and savings subcommands, on synthetic rounds and temp git repos.
class SimplicityVerdictTest < Minitest::Test
  V = SimplicitySignals::Verdict

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) }
  end

  def issue(priority, where, problem, saving: nil)
    { "priority" => priority, "where" => where, "problem" => problem, "fix" => "x", "saving" => saving }
  end

  def saving(lines, files = 0, deps = 0) = { "lines" => lines, "files" => files, "deps" => deps }

  def roast_dir(round, response = nil)
    dir = Dir.mktmpdir("simp-verdict")
    @dirs << dir
    File.write(File.join(dir, "round-1.json"), JSON.generate(round))
    File.write(File.join(dir, "round-1.response.json"), JSON.generate(response)) if response
    dir
  end

  def summary(findings) = V.summarize(findings)

  def test_mixed_round_ignores_unrelated_p0
    round = { "issues" => [
      issue("P0", "section 2", "Unrelated outage risk"),
      issue("P1", "Phase 3", "cf:simplicity: one-implementation factory", saving: saving(40, 1))
    ] }
    result = summary(V.from_roast(round, nil))

    assert_equal "trim", result["verdict"]
    assert_equal 1, result["accepted"]
    assert_equal({ "lines" => 40, "files" => 1, "deps" => 0 }, result["estimated"])
  end

  def test_saving_alone_does_not_mark_a_simplicity_finding
    round = { "issues" => [ issue("P0", "a", "cf:refactoring: smell", saving: saving(5)) ] }
    result = summary(V.from_roast(round, nil))

    assert_equal [ "ship", 0 ], result.values_at("verdict", "accepted")
  end

  def test_another_issues_rebuttal_at_the_same_location_is_not_applied
    round = { "issues" => [
      issue("P1", "Phase 1", "Unrelated risk"), issue("P0", "Phase 1", "cf:simplicity: wrong shape")
    ] }
    response = { "responses" => [
      { "screen" => "Phase 1", "problem" => "Unrelated risk", "verdict" => "rebut", "reason" => "Settled.", "grounds" => "D2" },
      { "screen" => "Phase 1", "problem" => "cf:simplicity: wrong shape", "verdict" => "accept" }
    ] }

    assert_equal "rethink", summary(V.from_roast(round, response))["verdict"]
    swapped = { "responses" => response["responses"].reverse }

    assert_equal "rethink", summary(V.from_roast(round, swapped))["verdict"]
  end

  def test_accepted_p0_is_rethink_and_p2_is_ship
    p0 = { "issues" => [ issue("P0", "a", "cf:simplicity: wrong shape"), issue("P1", "b", "cf:simplicity: extra") ] }
    p2 = { "issues" => [ issue("P2", "a", "cf:simplicity: taste") ] }

    assert_equal "rethink", summary(V.from_roast(p0, nil))["verdict"]
    assert_equal "ship", summary(V.from_roast(p2, nil))["verdict"]
    assert_equal "ship", summary(V.from_roast({ "issues" => [] }, nil))["verdict"]
  end

  def test_grounded_rebuttal_drops_the_finding_and_sets_precision
    round = { "issues" => [
      issue("P0", "Phase 1", "cf:simplicity: rubric only"), issue("P1", "Phase 2", "cf:simplicity: field", saving: saving(5)),
      issue("P1", "Phase 3", "cf:simplicity: layer", saving: saving(10, 1))
    ] }
    response = { "responses" => [
      { "screen" => "Phase 1", "verdict" => "rebut", "reason" => "Plan fixes the shape.", "grounds" => "D1" },
      { "where" => "Phase 2", "verdict" => "accept", "change" => "drop it" }
    ] }
    result = summary(V.from_roast(round, response))

    assert_equal "trim", result["verdict"]
    assert_equal [ 2, 1, 0.67 ], result.values_at("accepted", "rebutted", "precision")
    assert_equal 15, result["estimated"]["lines"]
  end

  def test_ungrounded_rebuttal_counts_as_accept
    round = { "issues" => [ issue("P0", "Phase 1", "cf:simplicity: wrong shape") ] }
    response = { "responses" => [ { "screen" => "Phase 1", "verdict" => "rebut", "reason" => "I disagree." } ] }
    result = summary(V.from_roast(round, response))

    assert_equal "rethink", result["verdict"]
    assert_equal 0, result["rebutted"]
  end

  def test_grounds_not_keywords_decide_a_rebuttal
    round = { "issues" => [ issue("P0", "a", "cf:simplicity: x"), issue("P0", "b", "cf:simplicity: y") ] }
    response = { "responses" => [
      { "screen" => "a", "verdict" => "rebut", "reason" => "The brief explicitly requires both exporters.", "grounds" => "brief: two exporters" },
      { "screen" => "b", "verdict" => "rebut", "reason" => "I disagree with this decision and the requirement." }
    ] }
    result = summary(V.from_roast(round, response))

    assert_equal [ 1, 1 ], result.values_at("accepted", "rebutted")
  end

  def test_precision_is_nil_with_no_findings
    assert_nil summary([])["precision"]
  end

  def test_findings_file_keeps_only_simplicity_and_reads_requirement
    list = [
      { "lens" => "simplicity", "priority" => "P1", "accepted" => true, "saving" => saving(8) },
      { "lens" => "refactoring", "priority" => "P0", "accepted" => true },
      { "lens" => "simplicity", "priority" => "P0", "accepted" => false, "requirement" => "audit export",
        "rebuttal" => "serves the audit export" },
      { "lens" => "simplicity", "priority" => "P0", "accepted" => false, "requirement" => "none", "rebuttal" => "needed" }
    ]
    result = summary(V.from_findings(list))

    assert_equal "rethink", result["verdict"]
    assert_equal [ 2, 1 ], result.values_at("accepted", "rebutted")
  end

  def test_cli_verdict_from_roast_dir_and_findings_file
    dir = roast_dir({ "issues" => [ issue("P1", "x", "cf:simplicity: y") ] })
    out = StringIO.new
    code = SimplicitySignals::CLI.run([ "verdict", "--roast-dir", dir, "--round", "1" ], out: out, err: StringIO.new)

    assert_equal 0, code
    assert_equal "trim", JSON.parse(out.string)["verdict"]

    file = File.join(dir, "simplicity-findings.json")
    File.write(file, JSON.generate([ { "lens" => "simplicity", "priority" => "P1", "accepted" => true, "saving" => saving(3) } ]))
    out = StringIO.new
    SimplicitySignals::CLI.run([ "verdict", "--findings", file ], out: out, err: StringIO.new)

    assert_equal 3, JSON.parse(out.string)["estimated"]["lines"]
  end

  def test_cli_usage_errors_exit_2
    err = StringIO.new

    assert_equal 2, SimplicitySignals::CLI.run([ "verdict" ], out: StringIO.new, err: err)
    assert_equal 2, SimplicitySignals::CLI.run([ "verdict", "--roast-dir", "/nonexistent-dir" ], out: StringIO.new, err: err)
    assert_equal 2, SimplicitySignals::CLI.run([ "savings", "--before", "HEAD" ], out: StringIO.new, err: err)
  end

  def make_repo
    dir = Dir.mktmpdir("simp-savings")
    @dirs << dir
    GitFixture.git_init(dir, "-b", "main")
    GitFixture.git(dir, "config", "user.email", "fixture@example.com")
    GitFixture.git(dir, "config", "user.name", "Fixture")
    dir
  end

  def commit(dir, files)
    files.each do |name, body|
      path = File.join(dir, name)
      body.nil? ? FileUtils.rm_f(path) : File.write(path, body)
    end
    GitFixture.git(dir, "add", "-A")
    GitFixture.git(dir, "commit", "-q", "-m", "c")
    GitFixture.git(dir, "rev-parse", "HEAD").strip
  end

  def test_savings_net_is_negative_for_a_rewrite
    dir = make_repo
    before = commit(dir, "a.rb" => "x\n" * 40)
    after = commit(dir, "a.rb" => "y\n" * 100)
    result = SimplicitySignals.savings(repo: dir, before: before, after: after)

    assert_equal [ 100, 40, -60 ], result.values_at("lines_added", "lines_deleted", "lines_net")
  end

  def test_savings_counts_removed_files_and_deps
    dir = make_repo
    before = commit(dir, "lib.rb" => "a\nb\n", "gone.rb" => "c\n", "Gemfile" => "gem 'httparty'\ngem 'rake'\n",
                         "Gemfile.lock" => "GEM\n  specs:\n    httparty (1.0)\n    rake (13.0)\n")
    after = commit(dir, "gone.rb" => nil, "Gemfile" => "gem 'rake'\n", "Gemfile.lock" => "GEM\n  specs:\n    rake (13.0)\n")
    out = StringIO.new
    code = SimplicitySignals::CLI.run([ "savings", "--repo", dir, "--before", before, "--after", after ], out: out, err: StringIO.new)
    result = JSON.parse(out.string)

    assert_equal 0, code
    assert_equal [ 1, 1, 1 ], result.values_at("files_removed", "deps_removed", "lockfile_removed")
    refute result.key?("estimated")
  end
end
