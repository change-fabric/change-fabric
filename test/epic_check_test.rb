# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/epic_check"

class EpicCheckTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/epic", __dir__)
  CLEAN = File.join(FIXTURES, "clean/epic.md")
  PLANS = File.join(FIXTURES, "clean/plans")

  SEEDED = {
    "cycle" => "cycle",
    "missing_node" => "missing_node",
    "orphan_criterion" => "orphan_criterion",
    "unknown_plan" => "unknown_plan",
    "out_of_scope_repo" => "out_of_scope_repo"
  }.freeze

  def check(path) = EpicCheck.run(EpicStore.load(path, plans_root: PLANS))

  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    code = EpicCheck::CLI.run(argv, out:, err:)
    [ code, out.string, err.string ]
  end

  def with_epic(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "epic.md")
      File.write(path, text)
      yield path
    end
  end

  def test_clean_fixture_has_zero_problems
    assert_empty check(CLEAN).problems
  end

  def test_each_defect_fixture_names_exactly_its_seeded_defect
    SEEDED.each do |name, kind|
      problems = check(File.join(FIXTURES, "defects/#{name}.md")).problems

      assert_equal [ kind ], problems.map { |line| line.split(":").first }, "#{name}: #{problems.inspect}"
    end
  end

  def test_every_defect_fixture_is_covered
    names = Dir.glob(File.join(FIXTURES, "defects/*.md")).map { |path| File.basename(path, ".md") }

    assert_equal SEEDED.keys.sort, names.sort
  end

  def test_problems_are_collected_not_fail_fast
    text = <<~MD
      ---
      repos: [sample-org/api]
      criteria:
        - {id: SC1, text: x}
        - {id: SC1, text: y, owner: demo/api-audit-log}
      plans:
        - {id: P1, repo: sample-org/api, dir: demo/api-audit-log}
        - {id: P1, repo: sample-org/web, dir: demo/gone}
      edges:
        - {from: "P1#Phase 1", to: "nonsense"}
      ---
    MD
    with_epic(text) do |path|
      kinds = check(path).problems.map { |line| line.split(":").first }

      assert_equal %w[bad_edge duplicate_criterion duplicate_plan missing_plan orphan_criterion out_of_scope_repo],
                   kinds.uniq.sort
    end
  end

  def test_malformed_frontmatter_is_reported_as_a_problem
    with_epic("---\n- a list\n---\n") do |path|
      assert_equal [ "frontmatter: not a mapping" ], check(path).problems
    end
  end

  def test_cli_clean_exits_zero
    code, out, = cli("--plans-root", PLANS, CLEAN)

    assert_equal 0, code
    assert_equal "epic_check: clean\n", out
  end

  def test_cli_defect_exits_one
    code, out, = cli("--plans-root", PLANS, File.join(FIXTURES, "defects/unknown_plan.md"))

    assert_equal 1, code
    assert_match(/\Aunknown_plan: /, out)
  end

  def test_cli_order_prints_numbered_layers
    code, out, = cli("--order", "--plans-root", PLANS, CLEAN)

    assert_equal 0, code
    assert_equal <<~OUT, out
      Layer 1: P1#Phase 1, P4#Phase 1
      Layer 2: P1#Phase 2, P2#Phase 1
      Layer 3: P2#Phase 2
      Layer 4: P3#Phase 1
      Layer 5: P3#Phase 2
    OUT
  end

  def test_cli_order_on_a_cycle_exits_one_with_the_cycle
    code, out, = cli("--order", "--plans-root", PLANS, File.join(FIXTURES, "defects/cycle.md"))

    assert_equal 1, code
    assert_match(/\Acycle: P2#Phase 1, P2#Phase 2, P3#Phase 1/, out)
  end

  def test_cli_order_on_structural_problems_reports_them
    code, out, = cli("--order", "--plans-root", PLANS, File.join(FIXTURES, "defects/missing_node.md"))

    assert_equal 1, code
    assert_includes out, "P3#Phase 9"
    refute_match(/Layer 1/, out)
  end

  def test_cli_resolves_a_slug_under_plans_root
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "epics", "demo"))
      FileUtils.cp(CLEAN, File.join(root, "epics", "demo", "epic.md"))
      FileUtils.cp_r(File.join(PLANS, "demo"), root)

      assert_equal 0, cli("--plans-root", root, "demo").first
    end
  end

  def test_a_plan_with_no_phases_is_a_problem
    Dir.mktmpdir do |root|
      FileUtils.cp_r(File.join(PLANS, "demo"), root)
      File.write(File.join(root, "demo", "web-sso", "plan.md"), "# Web SSO\n\nNo phases yet.\n")
      code, out, = cli("--plans-root", root, CLEAN)

      assert_equal 1, code
      assert_includes out, "empty_plan: P3"
    end
  end

  def test_cli_usage_errors_exit_two
    assert_equal 2, cli.first
    assert_equal 2, cli("--bogus", CLEAN).first
    assert_equal 2, cli("--plans-root").first
    assert_equal 2, cli(File.join(FIXTURES, "nope.md")).first
  end

  def test_cli_resolves_a_slug_under_the_epics_area
    Dir.mktmpdir do |root|
      previous = ENV.fetch("CF_PLANS_ROOT", nil)
      ENV["CF_PLANS_ROOT"] = root
      FileUtils.mkdir_p(File.join(root, "epics/sso"))
      FileUtils.cp(CLEAN, File.join(root, "epics/sso/epic.md"))

      assert_equal 0, cli("--plans-root", PLANS, "sso").first
    ensure
      previous ? ENV["CF_PLANS_ROOT"] = previous : ENV.delete("CF_PLANS_ROOT")
    end
  end
end
