# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../scripts/plan_lenses"

class PlanLensesTest < Minitest::Test
  SKILLS_DIR = File.expand_path("../skills", __dir__)

  def setup
    @dir = Dir.mktmpdir("plan-lenses")
    @prior = ENV.fetch("CF_SKILLS_DIR", nil)
    ENV["CF_SKILLS_DIR"] = SKILLS_DIR
    @terms = File.join(@dir, "terms.txt")
    File.write(@terms, "")
    ENV["CF_SENSITIVE_TERMS_FILE"] = @terms
  end

  def teardown
    ENV["CF_SKILLS_DIR"] = @prior
    ENV.delete("CF_SENSITIVE_TERMS_FILE")
    FileUtils.rm_rf(@dir)
  end

  def plan(text, goal: "Goal.\n")
    File.write(File.join(@dir, "plan.md"), text)
    File.write(File.join(@dir, "goal.md"), goal)
    @dir
  end

  def run_cli(*argv)
    out = StringIO.new
    [ PlanLenses::Cli.run(argv, out: out), out.string ]
  end

  # --- selection policy

  def test_simplicity_is_always_on_and_never_a_candidate
    plan("Keep it simple with Lambda.\n")
    code, text = run_cli("--plan-dir", @dir)
    assert_equal 0, code
    assert_includes text, "plan lenses always: cf:simplicity"
    refute_match(/candidates:.*cf:simplicity/, text)
    refute_includes PlanLenses.candidates(plan_dir: @dir).map(&:first), "cf:simplicity"
  end

  def test_the_input_file_names_alone_make_no_candidate
    plan("Nothing routable here.\n")
    assert_empty PlanLenses.candidates(plan_dir: @dir)
  end

  def test_ranking_is_reasons_then_kind_then_name
    found = { "cf:ruby" => [ "keyword ruby" ], "cf:terraform" => [ "keyword terraform", "keyword hcl" ],
              "cf:aws" => [ "keyword lambda" ], "cf:rails" => [ "keyword rails" ] }
    assert_equal %w[cf:terraform cf:aws cf:rails cf:ruby], PlanLenses.rank(found).map(&:first)
    assert_equal PlanLenses.rank(found), PlanLenses.rank(found.to_a.reverse.to_h)
  end

  def test_candidates_line_names_reasons
    plan("Rewrite the Ruby service on Lambda; edit infra/main.tf.\n")
    _, text = run_cli("--plan-dir", @dir)
    assert_match(/candidates: .*cf:aws \(keyword lambda\)/, text)
    assert_match(/cf:terraform \(path infra\/main.tf\)/, text)
  end

  def test_keep_ignores_unknown_and_keeps_rank_order
    plan("Ruby and Rails on Lambda with Terraform.\n")
    _, text = run_cli("--plan-dir", @dir, "--keep", "nope,cf:ruby,aws")
    assert_includes text, "plan lenses final: --lens cf:simplicity --lens cf:aws --lens cf:ruby"
  end

  def test_no_line_carries_more_than_four_lens_flags
    names = %w[cf:aws cf:ruby cf:rails cf:terraform cf:usability cf:refactoring cf:react cf:typescript cf:javascript cf:docker]
    (0..10).each do |n|
      ranked = names.first(n).map { |name| [ name, [ "keyword x" ] ] }
      flags = PlanLenses.lens_flags(PlanLenses.final(ranked, names))
      assert_operator flags.count("--lens"), :<=, 4, n.to_s
      assert_equal "cf:simplicity", flags[1]
    end
    assert_equal 4, PlanLenses.lens_flags(names).count("--lens")
  end

  def test_missing_plan_exits_two
    code, text = run_cli("--plan-dir", File.join(@dir, "absent"))
    assert_equal 2, code
    assert_match(/plan.md not found/, text)
  end

  # --- budget procedure (roast rounds only; the cull is not debited) (pure fit, fake bounds)

  def weights(lens: 0.10, image: 0.05, base: 0.10)
    ->(lenses, inputs) { base + (lens * lenses.size) + (image * inputs.grep(PlanLenses::IMAGE).size) }
  end

  TEXTS = %w[/p/goal.md /p/plan.md].freeze
  SHOTS = %w[/p/diagrams/b-light.png /p/diagrams/a-dark.png /p/diagrams/a-light.png /p/diagrams/b-dark.png].freeze

  def test_fits_as_is
    result = PlanLenses.fit(lenses: %w[cf:simplicity cf:aws], inputs: TEXTS + SHOTS, remaining: 5.0, bound: weights)
    assert_equal %w[cf:simplicity cf:aws], result[:lenses]
    assert_equal TEXTS + SHOTS, result[:inputs]
  end

  def test_over_budget_drops_routed_lowest_rank_first_one_at_a_time
    seen = []
    bound = ->(lenses, inputs) { seen << lenses.dup && weights.call(lenses, inputs) }
    result = PlanLenses.fit(lenses: %w[cf:simplicity cf:aws cf:security cf:ruby], inputs: TEXTS, remaining: 0.35, bound: bound)
    assert_equal %w[cf:simplicity cf:aws], result[:lenses]
    assert_equal [ %w[cf:simplicity cf:aws cf:security cf:ruby], %w[cf:simplicity cf:aws cf:security], %w[cf:simplicity cf:aws] ], seen
  end

  def test_simplicity_only_then_removes_dark_before_light_in_name_order
    kept = []
    bound = ->(lenses, inputs) { kept << inputs.dup && weights.call(lenses, inputs) }
    result = PlanLenses.fit(lenses: %w[cf:simplicity cf:aws], inputs: TEXTS + SHOTS, remaining: 0.20, bound: bound)
    steps = kept.drop(2)
    assert_equal TEXTS + %w[/p/diagrams/b-light.png /p/diagrams/a-light.png /p/diagrams/b-dark.png], steps[0]
    assert_equal TEXTS + %w[/p/diagrams/b-light.png /p/diagrams/a-light.png], steps[1]
    assert_equal TEXTS + %w[/p/diagrams/b-light.png], steps[2]
    assert_equal TEXTS, steps[3]
    assert_equal TEXTS, result[:inputs]
    assert_equal %w[cf:simplicity], result[:lenses]
  end

  def test_texts_and_simplicity_survive_every_budget
    [ 10.0, 0.5, 0.3, 0.21, 0.2 ].each do |remaining|
      result = PlanLenses.fit(lenses: %w[cf:simplicity cf:aws cf:ruby], inputs: TEXTS + SHOTS, remaining: remaining, bound: weights)
      assert_equal TEXTS, result[:inputs] & TEXTS, remaining.to_s
      assert_includes result[:lenses], "cf:simplicity"
    end
  end

  def test_minimum_payload_over_remaining_skips
    assert_equal :skip, PlanLenses.fit(lenses: %w[cf:simplicity cf:aws], inputs: TEXTS + SHOTS, remaining: 0.19, bound: weights)
  end

  def test_round_two_refused_after_round_one_debit
    first = PlanLenses.fit(lenses: %w[cf:simplicity], inputs: TEXTS, remaining: PlanLenses.remaining([]), bound: weights)
    left = PlanLenses.remaining([ PlanLenses.debit(bound: first[:bound]) ])
    bigger = weights(base: 0.25)
    assert_equal :skip, PlanLenses.fit(lenses: %w[cf:simplicity], inputs: TEXTS, remaining: left, bound: bigger)
  end

  def test_debit_uses_reported_usage_else_bound
    assert_in_delta 0.12, PlanLenses.debit(bound: 0.12)
    assert_in_delta 0.03, PlanLenses.debit(bound: 0.12, reported: 0.03)
  end

  # --- real bounds

  def roast_inputs(lenses: [ "cf:simplicity" ])
    plan("Plan text. " * 200)
    { brief: "Goal.", shots: [], history: [], texts: [ File.join(@dir, "plan.md"), File.join(@dir, "goal.md") ],
      review: { kind: "doc", audience: "engineer", purpose: [ "x" ] }, lenses: RoastLens.resolve(lenses), model: Roast.model_for(kind: "doc") }
  end

  def test_underestimate_a_point_estimate_that_fits_is_not_sent
    inputs = roast_inputs
    point = Roast.estimate(**inputs)[:usd]
    bound = PlanLenses.roast_bound(inputs)
    assert_operator bound, :>, point
    remaining = (point + bound) / 2
    assert_equal :skip, PlanLenses.fit(lenses: %w[cf:simplicity], inputs: [], remaining: remaining, bound: ->(*) { bound })
  end

  # A fake `claude` on PATH that records its argv and stdin, then answers.
  def stub_claude(answer: '["cf:ruby"]', status: 0)
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    path = File.join(bin, "claude")
    File.write(path, "#!/bin/sh
printf '%s\n' \"$@\" > #{@dir}/argv
cat > #{@dir}/stdin
echo '#{answer}'
exit #{status}
")
    File.chmod(0o755, path)
    bin
  end

  def with_path(path)
    prior = ENV.fetch("PATH")
    ENV["PATH"] = path
    yield
  ensure
    ENV["PATH"] = prior
  end

  def cull_plan = plan("Ruby and Rails on Lambda with Terraform.
")

  def test_cull_runs_haiku_one_turn_with_tools_off_and_keeps_its_answer
    cull_plan
    _, text = with_path("#{stub_claude}:/usr/bin:/bin") { run_cli("--plan-dir", @dir, "--cull") }
    assert_includes text, "plan lenses final: --lens cf:simplicity --lens cf:ruby
"
    argv = File.read(File.join(@dir, "argv")).split("
", -1)
    assert_equal [ "-p", "--model", "haiku", "--max-turns", "1", "--tools", "" ], argv[0, 7]
    stdin = File.read(File.join(@dir, "stdin"))
    assert_includes stdin, "Ruby and Rails on Lambda"
    assert_includes stdin, "== candidate cf:aws"
    refute_includes text, "skipped"
  end

  def test_cull_with_no_claude_on_path_falls_back_to_rules
    cull_plan
    _, text = with_path(File.join(@dir, "nowhere")) { run_cli("--plan-dir", @dir, "--cull") }
    assert_includes text, "plan lenses cull skipped (claude not on PATH); using rule-based candidates"
    assert_equal 4, text[/^plan lenses final: .*$/].scan("--lens").size
  end

  def test_cull_non_zero_exit_falls_back_to_rules
    cull_plan
    _, text = with_path("#{stub_claude(status: 2)}:/usr/bin:/bin") { run_cli("--plan-dir", @dir, "--cull") }
    assert_includes text, "plan lenses cull skipped (claude exited 2)"
    assert_equal 4, text[/^plan lenses final: .*$/].scan("--lens").size
  end

  def test_cull_drops_names_outside_the_candidates
    ranked = [ [ "cf:aws", [ "keyword lambda" ] ] ]
    plan("Lambda.
")
    result = PlanLenses.cull(ranked, plan_dir: @dir, runner: ->(*) { [ '["cf:aws","cf:nope"]', true, nil ] })
    assert_equal({ kept: %w[cf:aws], note: nil }, result)
  end

  def test_skill_file_reads_installed_cf_prefixed_dirs
    installed = File.join(@dir, "installed")
    FileUtils.mkdir_p(File.join(installed, "cf:aws"))
    File.write(File.join(installed, "cf:aws", "SKILL.md"), "x")
    assert_equal File.join(installed, "cf:aws", "SKILL.md"), PlanLenses.skill_file("cf:aws", installed)
    assert_equal File.join(SKILLS_DIR, "aws", "SKILL.md"), PlanLenses.skill_file("aws", SKILLS_DIR)
  end

  def test_fit_flags_round_trip_multiword_values
    inputs = roast_inputs
    audience = "the engineer executing this plan in a fresh session"
    args = [ "--brief", File.join(@dir, "goal.md"), "--text", inputs[:texts][0], "--kind", "doc",
             "--audience", audience, "--purpose", "x", "--out-dir", File.join(@dir, "roast") ]
    _, text = run_cli("fit", "--remaining", "0.50", "--", *args)
    flags = Shellwords.split(text[/^plan lenses fit: (.*)$/, 1])
    assert_equal audience, flags[flags.index("--audience") + 1]
  end

  def test_fit_cli_prints_flags_and_skips
    inputs = roast_inputs
    args = [ "--brief", File.join(@dir, "goal.md"), "--text", inputs[:texts][0], "--text", inputs[:texts][1], "--kind", "doc",
             "--audience", "engineer", "--purpose", "x", "--out-dir", File.join(@dir, "roast") ]
    code, text = run_cli("fit", "--remaining", "0.50", "--keep", "cf:aws", "--", *args)
    assert_equal 0, code, text
    assert_match(/plan lenses fit: --lens cf:simplicity --lens cf:aws --brief/, text)
    assert_match(/plan lenses bound: \$0\.\d+ of \$0\.5000 remaining/, text)
    code, text = run_cli("fit", "--remaining", "0.0001", "--keep", "cf:aws", "--", *args)
    assert_equal 3, code
    assert_equal "roast skipped\n", text
  end
end

class PlanLensesStepWiringTest < Minitest::Test
  STEP = File.read(File.expand_path("../skills/plan/SKILL.md", __dir__))[/^7b\. \*\*Roast\.\*\*.*?(?=^\d+\. \*\*)/m]

  def test_step_7b_runs_the_lens_policy_and_fit
    assert_includes STEP, "plan_lenses.rb --plan-dir"
    assert_includes STEP, "plan_lenses.rb fit"
    assert_includes STEP, "--cull"
    refute_includes STEP, "cull bound"
    assert_includes STEP, "roast skipped"
    refute_match(/trim\s+plan\.md quotes/, STEP)
  end
end
