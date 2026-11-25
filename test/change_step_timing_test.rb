# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "csv"
require_relative "../scripts/change_config"
require_relative "../scripts/change_run"
require_relative "../scripts/change_flow_compiler"
require_relative "../scripts/change_suite"
require_relative "../scripts/change_lane_testcases"
require_relative "../scripts/change_acceptance_grader"
require_relative "../scripts/change_findings"
require_relative "../scripts/change_report"

# Timed testcase steps (suite_version 8): `timing: { warn_ms, fail_ms }` on a
# wait. Schema rules are checked on the compiler and the suite loader, the
# three-band grade in node against a stub page (the runtime is browser JS), and
# the findings, CSV and Markdown through the lane and the report.
class ChangeStepTimingTest < Minitest::Test
  def compile(steps) = ChangeFlowCompiler.new(steps, base_url: "https://app.example.org", env: {}).compile

  def timed(timing = { "warn_ms" => 5000, "fail_ms" => 15_000 }, **extra)
    [ { "click" => "#next", "label" => "next" },
      { "wait_for_text" => { "text" => "Ready", "timing" => timing, "timing_from" => "next" }.merge(extra.transform_keys(&:to_s)) } ]
  end

  # --- schema: the compiler -------------------------------------------------------

  def test_a_valid_timing_compiles_and_defaults_the_wait_timeout
    step = compile(timed).last
    assert_equal({ warnMs: 5000, failMs: 15_000 }, step[:timing])
    assert_equal "next", step[:timingFrom]
    assert_equal 75_000, step[:timeoutMs]
  end

  def test_timing_beside_the_verb_compiles_too
    step = compile([ { "wait_for_text" => "Ready", "timing" => { "warn_ms" => 1, "fail_ms" => 2 } } ]).first
    assert_equal({ warnMs: 1, failMs: 2 }, step[:timing])
    assert_equal 60_002, step[:timeoutMs]
  end

  def test_an_untimed_step_is_unchanged
    step = compile([ { "wait_for_text" => "Ready" } ]).first
    refute step.key?(:timing)
    refute step.key?(:timingFrom)
    assert_equal ChangeFlowCompiler::DEFAULT_TIMEOUT_MS, step[:timeoutMs]
  end

  def test_warn_at_or_above_fail_is_refused
    [ { "warn_ms" => 15_000, "fail_ms" => 15_000 }, { "warn_ms" => 20_000, "fail_ms" => 15_000 } ].each do |timing|
      error = assert_raises(ChangeFlowCompiler::Error) { compile(timed(timing)) }
      assert_match(/warn_ms .* must be below fail_ms/, error.message)
    end
  end

  def test_a_missing_or_malformed_budget_is_refused
    error = assert_raises(ChangeFlowCompiler::Error) { compile(timed({ "warn_ms" => 5000 })) }
    assert_match(/needs fail_ms/, error.message)
    assert_raises(ChangeFlowCompiler::Error) { compile(timed({ "fail_ms" => 5000 })) }
    assert_raises(ChangeFlowCompiler::Error) { compile(timed({ "warn_ms" => 0, "fail_ms" => 5000 })) }
    assert_raises(ChangeFlowCompiler::Error) { compile(timed({ "warn_ms" => "1", "fail_ms" => 5000 })) }
    assert_raises(ChangeFlowCompiler::Error) { compile(timed({ "warn_ms" => 1, "fail_ms" => 5000, "extra" => 1 })) }
    assert_raises(ChangeFlowCompiler::Error) { compile(timed("fast")) }
  end

  def test_the_wait_timeout_must_sit_within_the_margin_above_fail_ms
    [ 24_999, 105_001, 15_000 ].each do |timeout|
      error = assert_raises(ChangeFlowCompiler::Error) { compile(timed(timeout_ms: timeout)) }
      assert_match(/fail_ms \+ 10000 to fail_ms \+ 90000/, error.message)
    end
    [ 25_000, 105_000 ].each { |timeout| assert_equal timeout, compile(timed(timeout_ms: timeout)).last[:timeoutMs] }
  end

  def test_timing_belongs_on_a_wait
    error = assert_raises(ChangeFlowCompiler::Error) do
      compile([ { "click" => "#go", "timing" => { "warn_ms" => 1, "fail_ms" => 2 } } ])
    end
    assert_match(/belongs on a wait/, error.message)
  end

  def test_timing_from_needs_a_timing_and_an_earlier_label
    assert_raises(ChangeFlowCompiler::Error) { compile([ { "click" => "#go", "label" => "go" }, { "wait_for_text" => "x", "timing_from" => "go" } ]) }
    unknown = timed.tap { |steps| steps.last["wait_for_text"]["timing_from"] = "nope" }
    assert_match(/not the label of an earlier step/, assert_raises(ChangeFlowCompiler::Error) { compile(unknown) }.message)
  end

  # --- schema: the suite loader ---------------------------------------------------

  def suite_yaml(version: 8, case_extra: "", timing_line: "timing: { warn_ms: 5000, fail_ms: 15000 }")
    <<~YAML
      suite: speed
      suite_version: #{version}
      cases:
        - id: switch-view
          acceptance: The view switches quickly.
          #{case_extra.gsub("\n", "\n    ")}
          steps:
            - click: "#next"
              label: next
            - wait_for_text: { text: "Ready", #{timing_line}, timing_from: next }
    YAML
  end

  def load_suite(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "speed.cf-testcases.yml")
      File.write(path, body)
      yield ChangeSuite.load_file(path)
    end
  end

  def test_a_timed_suite_loads_at_version_8
    load_suite(suite_yaml) { |suite| assert_equal 1, suite.cases.size }
  end

  def test_a_timed_step_in_an_older_suite_names_the_version_that_adds_it
    load_suite(suite_yaml(version: 7)) { flunk "expected a refusal" }
  rescue ChangeSuite::Error => e
    assert_match(/uses `timing`, added in suite_version 8/, e.message)
  end

  def test_retries_on_a_case_with_a_timed_step_are_refused
    load_suite(suite_yaml(case_extra: "retries: 1\nsafe_rerun: true")) { flunk "expected a refusal" }
  rescue ChangeSuite::Error => e
    assert_match(/retries: 1.*timing/, e.message)
  end

  def test_retries_stay_legal_on_a_case_with_no_timed_step
    body = suite_yaml(case_extra: "retries: 1\nsafe_rerun: true").sub(/, timing: \{[^}]*\}, timing_from: next/, "")
    load_suite(body) { |suite| assert_equal 1, suite.cases.first.retries }
  end

  def test_the_suite_version_is_8
    assert_equal 8, ChangeSuiteSchema::SUITE_VERSION
  end

  # --- grading: the runtime in node -----------------------------------------------

  # Runs a click then a timed `wait_for` selector against a stub page whose wait
  # takes `delay` ms and then resolves, or rejects when `timeout` is set.
  def grade(delay, warn_ms: 100, fail_ms: 300, timeout: false)
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    steps = [ { "click" => "#go", "label" => "go" },
              { "wait_for" => { "selector" => "#done", "timing" => { "warn_ms" => warn_ms, "fail_ms" => fail_ms } }, "timing_from" => "go" } ]
    script = <<~JS
      const { EventEmitter } = require("events");
      #{ChangeFlowCompiler.flow_runtime_js}
      const page = new EventEmitter();
      page.waitForSelector = async (selector) => {
        if (selector === "#go") return { click: async () => {} };
        await new Promise((resolve) => setTimeout(resolve, #{delay}));
        if (#{timeout}) { const e = new Error("Waiting for selector `#done` failed: timeout exceeded"); e.name = "TimeoutError"; throw e; }
        return {};
      };
      cfRunFlow(page, #{JSON.generate(ChangeFlowCompiler.new(steps, base_url: "https://app.example.org", env: {}).compile)})
        .then((records) => console.log(JSON.stringify(records.map((r) => ({ ok: r.ok, error: r.error, timing: r.timing })))));
    JS
    JSON.parse(IO.popen([ "node", "-e", script ], &:read)).last
  end

  def test_under_warn_ms_passes
    record = grade(0)
    assert record["ok"]
    assert_equal "pass", record["timing"]["grade"]
    assert_operator record["timing"]["stepMs"], :<, 100
  end

  def test_between_warn_and_fail_warns_and_still_passes
    record = grade(150)
    assert record["ok"], record.inspect
    assert_equal "warn", record["timing"]["grade"]
    assert_operator record["timing"]["stepMs"], :>=, 100
  end

  def test_at_or_over_fail_ms_fails
    record = grade(350)
    refute record["ok"]
    assert_equal "fail", record["timing"]["grade"]
    assert_match(/timing budget: go\.\.step 2 took \d+ms, fail_ms 300/, record["error"])
  end

  # The boundary: a span of exactly `fail_ms` fails. Driven through the grading
  # function directly so the clock is exact.
  def test_exactly_fail_ms_fails_and_one_below_warns
    skip "node not installed" unless system("command -v node >/dev/null 2>&1")
    script = <<~JS
      #{ChangeFlowCompiler.flow_runtime_js}
      const step = { index: 1, timing: { warnMs: 100, failMs: 300 } };
      const run = (span) => { const record = { ok: true }; cfGradeTiming(step, record, 1000, 1000 + span, new Map()); return record.timing.grade + ":" + record.ok; };
      console.log([run(99), run(100), run(299), run(300)].join(","));
    JS
    assert_equal "pass:true,warn:true,warn:true,fail:false", IO.popen([ "node", "-e", script ], &:read).strip
  end

  def test_a_wait_timeout_on_a_timed_step_is_a_timing_budget_failure_with_elapsed_ms
    record = grade(50, timeout: true)
    refute record["ok"]
    assert_equal "fail", record["timing"]["grade"]
    assert_equal "timeout", record["timing"]["reason"]
    assert_operator record["timing"]["stepMs"], :>=, 40
    assert_match(/\Atiming budget: go\.\.step 2 timed out after \d+ms, fail_ms 300/, record["error"])
  end

  # --- findings, CSV and Markdown --------------------------------------------------

  Ctx = Struct.new(:network, :target_url, :browserless, :suite_select, :signoff) do
    def log(_message) = nil
    def signoff? = signoff == true
  end

  class Session
    attr_reader :timeouts

    def initialize(steps)
      @steps = steps
      @timeouts = []
    end

    def run_function(_code, launch_args: [], timeout_ms: nil)
      @timeouts << timeout_ms
      { "index" => 0, "attempts" => 1, "ok" => @steps.all? { |step| step["ok"] != false }, "steps" => @steps,
        "observation" => { "url" => "https://app.example.org/", "title" => "t", "text" => "x" } }
    end
  end

  class Grader
    def unavailable_reason = nil
    def reported_model = nil

    def grade(observations)
      observations.map { |o| ChangeAcceptanceGrader::Verdict.new(id: o[:id], verdict: "pass", rationale: "ok") }
    end
  end

  def timing_findings(timing, ok: true)
    step = { "index" => 1, "verb" => "waitForText", "label" => "wait_for_text", "ok" => ok, "durationMs" => timing["stepMs"],
             "startedAtMs" => 0, "timing" => timing }
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "speed.cf-testcases.yml"), suite_yaml)
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
      findings = ChangeLaneTestcases.new(config, Ctx.new("net", "https://app.example.org", Session.new([ step ]), [], false),
                                         grader: Grader.new, sleeper: ->(_seconds) { }).run
      findings.select { |finding| finding.check.end_with?("timing") }
    end
  end

  def test_a_pass_a_warn_and_a_fail_become_info_low_and_high_findings_with_step_ms
    passed = timing_findings({ "stepMs" => 40, "warnMs" => 100, "failMs" => 300, "grade" => "pass" }).first
    warned = timing_findings({ "stepMs" => 150, "warnMs" => 100, "failMs" => 300, "grade" => "warn" }).first
    failed = timing_findings({ "stepMs" => 400, "warnMs" => 100, "failMs" => 300, "grade" => "fail" }, ok: false).first

    assert_equal [ "pass", "warn", "fail" ], [ passed.status, warned.status, failed.status ]
    assert_equal [ "info", "low", "high" ], [ passed.severity, warned.severity, failed.severity ]
    assert_equal [ 40, 150, 400 ], [ passed.step_ms, warned.step_ms, failed.step_ms ]
    refute warned.fail?
    assert failed.fail?
    assert_match(/400ms against warn_ms 100, fail_ms 300/, failed.detail)
  end

  # A timed wait with no timeout of its own waits fail_ms + 60000, and the
  # case's call must outlive that or the timing finding is lost with the call.
  def test_the_case_call_budget_covers_a_timed_waits_derived_timeout
    session = Session.new([])
    Dir.mktmpdir do |dir|
      body = suite_yaml(timing_line: "timing: { warn_ms: 60000, fail_ms: 120000 }")
      File.write(File.join(dir, "speed.cf-testcases.yml"), body)
      config = ChangeConfig::LaneConfig.new("testcases", { "suites" => [ "*.cf-testcases.yml" ] }, dir)
      ChangeLaneTestcases.new(config, Ctx.new("net", "https://app.example.org", session, [], false),
                              grader: Grader.new, sleeper: ->(_seconds) { }).run
    end
    assert_equal [ 180_000 + ChangeFlowCompiler::DEFAULT_TIMEOUT_MS ], session.timeouts
  end

  def test_a_timeout_finding_names_its_reason
    finding = timing_findings({ "stepMs" => 61_000, "warnMs" => 100, "failMs" => 300, "grade" => "fail", "reason" => "timeout" }, ok: false).first
    assert finding.fail?
    assert_match(/fail \(timeout\): 61000ms/, finding.detail)
  end

  def test_step_ms_is_in_the_csv_and_the_markdown
    findings = Findings.new
    findings.add(Finding.new(lane: "testcases", check: "speed/switch-view step 2 timing", status: "warn", severity: "low", step_ms: 150))
    findings.add(Finding.new(lane: "testcases", check: "speed/other", status: "pass"))
    Dir.mktmpdir do |dir|
      paths = ChangeReport.new(project: "app", scope: "all", findings: findings, out_dir: dir).write
      rows = CSV.read(paths[:csv], headers: true)
      assert_equal "step_ms", rows.headers.last
      assert_equal [ "150", "" ], rows.map { |row| row["step_ms"] }
      markdown = File.read(paths[:markdown])
      assert_includes markdown, "| Attempts | Step ms |"
      assert_match(/\| 1 \| 150 \|/, markdown)
    end
  end

  def test_a_retry_annotation_keeps_step_ms
    finding = Finding.new(lane: "testcases", check: "c", status: "warn", step_ms: 12)
    assert_equal 12, finding.with_attempt(attempts: 2, flaky: true).step_ms
  end
end
