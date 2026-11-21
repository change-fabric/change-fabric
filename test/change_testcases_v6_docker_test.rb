# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/change_config"
require_relative "../scripts/change_docker"
require_relative "../scripts/change_lane_testcases"

# The suite v6 case module in a real container, through the real lane: a
# precondition that fails blocks the case before its steps run, a relation that
# only agrees after a re-read is a warning, and one that never agrees fails with
# both value sets. The page is built by `eval`, so no server is needed and the
# re-read stays on one url (about:blank).
class ChangeTestcasesV6DockerTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff, :fail_on_warn, :fail_on_blocked,
                   :reference_hosts) do
    def log(_message) = nil
    def signoff? = false
  end

  class PassGrader
    def unavailable_reason = nil

    def grade(observations)
      observations.map { |item| ChangeAcceptanceGrader::Verdict.new(id: item[:id], verdict: "pass", rationale: "ok") }
    end
  end

  PAGE = <<~JS.gsub(/\s+/, " ").strip
    document.body.innerHTML = '<span class="badge">70</span> <span class="updated">t0</span><table><tbody>' +
      '<tr><td>x</td></tr>'.repeat(69) + '</tbody></table>';
    %<later>s
    return 1;
  JS

  GROWS = "setTimeout(() => { document.querySelector('tbody').insertAdjacentHTML('beforeend', '<tr><td>x</td></tr>'); document.querySelector('.updated').textContent = 't1'; }, 600);"

  def suite(later)
    <<~YAML
      suite: v6
      suite_version: 6
      cases:
        - id: relation
          acceptance: The badge and the rows agree.
          steps:
            - eval: #{JSON.generate(format(PAGE, later: later))}
            - capture: { var: badge, selector: ".badge", kind: number }
            - capture: { var: rows, selector: "tbody tr", kind: count }
            - expect_relation:
                relation: equal
                reads: { a: badge, b: rows }
                settle: { reread: 1, freshness_selector: ".updated" }
        - id: blocked
          acceptance: The members page lists the members.
          preconditions:
            - expect_visible: { selector: ".user-menu", timeout_ms: 500 }
          steps:
            - eval: "document.body.textContent = 'must not run'; return 1;"
    YAML
  end

  def setup
    skip "docker not available" unless ChangeDocker.available?
  end

  def run_lane(body, **flags)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "v6.cf-testcases.yml"), body)
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ], "timeout_ms" => 4000 }, dir)
      ChangeDocker.with_browserless(network: nil) do |session|
        lane = ChangeLaneTestcases.new(config, Ctx.new(nil, "https://app.example.org", session, [], false, flags[:fail_on_warn],
                                                       flags[:fail_on_blocked], []), grader: PassGrader.new)
        findings = lane.run
        yield findings.reject { |finding| finding.check.end_with?("acceptance") }.to_h { |finding| [ finding.check, finding ] },
              lane.case_records.to_h { |record| [ record.key, record ] }
      end
    end
  end

  def test_a_relation_that_agrees_after_the_reread_is_a_warning_with_drift_and_provenance
    run_lane(suite(GROWS)) do |findings, records|
      assert_equal "warn", findings["v6/relation"].status, findings["v6/relation"].detail
      record = records["v6/relation"]
      assert_equal "warn", record.status
      relation = record.relations.first
      assert relation["drift"]
      assert_equal [ 70, 69 ], relation["first_reads"].map { |read| read["value"] }
      assert_equal [ 70, 70 ], relation["reads"].map { |read| read["value"] }
      assert_equal %w[badge rows], record.vars.map { |figure| figure["var"] }
      assert_equal "about:blank", record.vars.first["url"]
      assert_equal "t0", record.vars.first["freshness"]
    end
  end

  def test_fail_on_warn_turns_that_warning_into_a_failed_gate
    run_lane(suite(GROWS), fail_on_warn: true) { |findings, _records| assert_equal "fail", findings["v6/relation"].status }
  end

  def test_a_relation_that_never_agrees_fails_with_both_value_sets
    run_lane(suite("")) do |findings, records|
      assert_equal "fail", findings["v6/relation"].status
      assert_match(/rows = 69.*after re-read: .*rows = 69/m, findings["v6/relation"].detail)
      assert_equal "fail", records["v6/relation"].status
      assert_equal [ 70, 69 ], records["v6/relation"].relations.first["reads"].map { |read| read["value"] }
    end
  end

  def test_a_failing_precondition_blocks_before_any_step_runs
    run_lane(suite(GROWS)) do |findings, records|
      blocked = findings["v6/blocked"]
      assert_equal "warn", blocked.status
      assert_includes blocked.detail, "blocked_precondition: precondition: expect_visible .user-menu"
      assert_equal "precondition 1: expect_visible .user-menu", blocked.location
      record = records["v6/blocked"]
      assert_equal "blocked_precondition", record.status
      assert_match(/\Aprecondition: expect_visible \.user-menu/, record.blocked_reason)
      assert_empty record.vars
    end
  end

  def test_fail_on_blocked_fails_the_gate_on_a_block
    run_lane(suite(GROWS), fail_on_blocked: true) { |findings, _records| assert_equal "fail", findings["v6/blocked"].status }
  end
end
