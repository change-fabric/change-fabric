# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../scripts/change_acceptance_grader"

# The acceptance grader: what it hands the model, what it does with the answer,
# and the one branch that differs between a terminal a human is watching and CI.
# No test here reaches a real model; the runner is the injected seam.
class ChangeAcceptanceGraderTest < Minitest::Test
  OBSERVATION = {
    id: "checkout/happy-path",
    acceptance: "A guest reaches the confirmation page.",
    ok: true,
    steps: [ { "label" => "goto /checkout", "ok" => true, "error" => "" } ],
    url: "https://app.example.org/confirmation",
    title: "Order confirmed",
    text: "Thanks for your order"
  }.freeze

  def grader(runner:, env: {}) = ChangeAcceptanceGrader.new(env: env, runner: runner)

  def answering(rows)
    ->(_prompt) { JSON.generate(rows) }
  end

  # --- verdicts ---------------------------------------------------------------

  def test_a_verdict_comes_back_keyed_to_its_case
    verdicts = grader(runner: answering([ { "id" => OBSERVATION[:id], "verdict" => "pass",
                                            "rationale" => "the confirmation page rendered" } ]))
               .grade([ OBSERVATION ])

    assert_equal 1, verdicts.size
    assert verdicts.first.pass?
    assert_equal "the confirmation page rendered", verdicts.first.rationale
  end

  def test_a_fail_verdict_stays_a_fail
    verdicts = grader(runner: answering([ { "id" => OBSERVATION[:id], "verdict" => "FAIL",
                                            "rationale" => "it landed on the cart" } ])).grade([ OBSERVATION ])

    assert verdicts.first.fail?
  end

  # A model may wrap its JSON in a fence or a sentence, which is not worth
  # failing over; a verdict token outside the vocabulary is, because "probably
  # pass" is exactly the reading that turns a gate into a coin flip.
  def test_json_wrapped_in_prose_is_still_read
    runner = lambda do |_prompt|
      "Sure, here you go:\n```json\n#{JSON.generate([ { 'id' => OBSERVATION[:id], 'verdict' => 'pass' } ])}\n```\n"
    end

    assert grader(runner: runner).grade([ OBSERVATION ]).first.pass?
  end

  def test_a_verdict_token_outside_the_vocabulary_reads_as_unclear
    verdicts = grader(runner: answering([ { "id" => OBSERVATION[:id], "verdict" => "probably fine" } ]))
               .grade([ OBSERVATION ])

    assert_equal "unclear", verdicts.first.verdict
  end

  def test_output_that_is_not_json_yields_unclear_rather_than_raising
    verdicts = grader(runner: ->(_prompt) { "I could not tell." }).grade([ OBSERVATION ])

    assert_equal "unclear", verdicts.first.verdict
    assert_includes verdicts.first.rationale, "grader error"
  end

  # A criterion that silently vanished from the report is the failure mode this
  # whole lane exists to avoid, so a case the grader skipped still gets a row.
  def test_a_case_the_grader_ignored_still_gets_a_verdict
    verdicts = grader(runner: answering([ { "id" => "some/other-case", "verdict" => "pass" } ]))
               .grade([ OBSERVATION ])

    assert_equal "unclear", verdicts.first.verdict
    assert_includes verdicts.first.rationale, "no verdict"
  end

  def test_a_grader_that_raises_does_not_take_the_run_down
    verdicts = grader(runner: ->(_prompt) { raise "connection refused" }).grade([ OBSERVATION ])

    assert_equal "unclear", verdicts.first.verdict
  end

  def test_nothing_to_grade_calls_nothing
    called = false
    grader(runner: ->(_prompt) { called = true }).grade([])

    refute called
  end

  # --- the prompt ---------------------------------------------------------------

  def test_the_criterion_and_the_observation_both_reach_the_prompt
    prompt = grader(runner: answering([])).prompt_for([ OBSERVATION ])

    assert_includes prompt, "A guest reaches the confirmation page."
    assert_includes prompt, "https://app.example.org/confirmation"
    assert_includes prompt, "Thanks for your order"
  end

  # An unbounded page would make the prompt a function of the app's verbosity.
  def test_page_text_is_bounded
    prompt = grader(runner: answering([])).prompt_for([ OBSERVATION.merge(text: "x" * 9_000) ])

    refute_includes prompt, "x" * (ChangeAcceptanceGrader::TEXT_LIMIT + 1)
  end

  # --- availability ---------------------------------------------------------------

  def test_a_configured_command_is_used_as_configured
    assert_equal %w[my-grader --json],
                 ChangeAcceptanceGrader.new(env: { "CF_ACCEPTANCE_GRADER" => "my-grader --json" }).command
  end

  def with_snapshot(roles)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snap.json")
      ModelRoles.write_snapshot(host: "claude", roles: roles, sources: {}, path: path) if roles
      yield path
    end
  end

  def default_grader(path, env: {})
    bin = File.join(File.dirname(path), "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "claude"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(bin, "claude"))
    ChangeAcceptanceGrader.new(env: { "PATH" => bin }.merge(env), snapshot_path: path)
  end

  def test_the_default_command_carries_the_snapshot_critic_model
    with_snapshot({ "critic" => "opus-x" }) do |path|
      assert_equal %w[claude -p --model opus-x], default_grader(path).command
      assert_equal "opus-x", default_grader(path).reported_model
    end
  end

  def test_a_missing_snapshot_falls_back_to_the_repo_map_critic
    with_snapshot(nil) do |path|
      repo = ModelRoles.table(host: "claude", env: {}, user_file: nil)["critic"]
      assert_equal [ "claude", "-p", "--model", repo ], default_grader(path).command
    end
  end

  def test_a_snapshot_without_a_critic_entry_omits_the_flag_when_the_repo_has_none
    with_snapshot({ "worker" => "sonnet" }) do |path|
      assert_equal %w[claude -p], default_grader(path).command
    end
  end

  def test_a_configured_command_never_gets_model_and_reports_none
    with_snapshot({ "critic" => "opus-x" }) do |path|
      configured = ChangeAcceptanceGrader.new(env: { "CF_ACCEPTANCE_GRADER" => "my-grader --json" }, snapshot_path: path)
      assert_equal %w[my-grader --json], configured.command
      assert_nil configured.reported_model
    end
  end

  def test_the_argv_reaches_the_process
    with_snapshot({ "critic" => "opus-x" }) do |path|
      log = File.join(File.dirname(path), "argv.txt")
      bin = File.join(File.dirname(path), "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "claude"), "#!/bin/sh\necho \"$@\" > #{log}\necho '[]'\n")
      File.chmod(0o755, File.join(bin, "claude"))
      original = ENV["PATH"]
      ENV["PATH"] = bin # Open3 resolves `claude` from the process PATH
      begin
        ChangeAcceptanceGrader.new(env: { "PATH" => bin }, snapshot_path: path).grade([ OBSERVATION ])
      ensure
        ENV["PATH"] = original
      end
      assert_equal "-p --model opus-x", File.read(log).strip
    end
  end

  def test_no_reachable_grader_reports_itself_rather_than_raising
    absent = ChangeAcceptanceGrader.new(env: { "PATH" => "/nonexistent" })

    refute absent.available?
    assert_includes absent.unavailable_reason, "no grader is reachable"
  end

  def test_the_skip_switch_names_itself_in_the_report
    skipped = ChangeAcceptanceGrader.new(env: { "CF_SKIP_ACCEPTANCE_GRADING" => "1" })

    refute skipped.available?
    assert_includes skipped.unavailable_reason, "CF_SKIP_ACCEPTANCE_GRADING=1"
  end

  # The switch governs the default grader; an injected one is somebody stating
  # what the grader is, which is never what the switch is there to turn off.
  def test_an_injected_runner_is_not_switched_off_by_the_skip_env
    injected = grader(runner: answering([]), env: { "CF_SKIP_ACCEPTANCE_GRADING" => "1" })

    assert injected.available?
    assert_nil injected.unavailable_reason
  end

  # --- the interactive versus CI branch -------------------------------------------

  class FakeTty
    def initialize(tty) = @tty = tty
    def tty? = @tty
  end

  def test_a_watched_terminal_is_interactive
    assert ChangeAcceptanceGrader.interactive?(stdin: FakeTty.new(true), env: {})
  end

  def test_ci_is_never_interactive_even_on_a_tty
    refute ChangeAcceptanceGrader.interactive?(stdin: FakeTty.new(true), env: { "CI" => "true" })
  end

  def test_a_piped_stdin_is_not_interactive
    refute ChangeAcceptanceGrader.interactive?(stdin: FakeTty.new(false), env: {})
  end

  # Both branches point at the SAME sha-scoped override; only its reachability
  # differs. Neither invents a second mechanism, and neither records one.
  def test_both_branches_name_the_existing_sha_scoped_override
    watched = ChangeAcceptanceGrader.override_guidance(interactive: true)
    ci = ChangeAcceptanceGrader.override_guidance(interactive: false)

    assert_includes watched, "change_override.rb"
    assert_includes ci, "change_override.rb"
    assert_includes watched, "recorded now"
    assert_includes ci, "fails closed"
    assert_includes ci, "refuses without a real terminal"
  end
end
