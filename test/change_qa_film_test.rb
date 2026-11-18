# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "yaml"
require_relative "../scripts/change_qa_film"

class ChangeQaFilmTest < Minitest::Test
  FakeStore = Struct.new(:values) do
    def read(name) = values[name]
  end

  def test_flag_probe_becomes_a_goto_and_a_body_check
    steps = ChangeQaFilm.flag_steps(flag: "new-reports", probe: "/api/flags/{flag}", expect: "true")
    assert_equal [ { "goto" => "/api/flags/new-reports" },
                   { "expect_text" => { "selector" => "body", "contains" => "true" } } ], steps
  end

  def test_flag_without_probe_uses_the_visible_selector
    assert_equal [ { "expect_visible" => "[data-testid=reports-nav]" } ],
                 ChangeQaFilm.flag_steps(flag: "new-reports", selector: "[data-testid=reports-nav]")
  end

  def test_flag_needs_a_probe_or_a_selector
    assert_raises(ChangeQaFilm::Error) { ChangeQaFilm.flag_steps(flag: "new-reports") }
    assert_raises(ChangeQaFilm::Error) { ChangeQaFilm.flag_steps(flag: "", selector: "#x") }
  end

  def test_draft_strips_check_labels_and_keeps_them_in_order
    Dir.mktmpdir do |dir|
      path = File.join(dir, "draft.yml")
      File.write(path, <<~YAML)
        acceptance: The count on the card matches the filtered table.
        steps:
          - goto: /reports
            check: Reports opens
          - click: "text=Open orders"
      YAML
      draft = ChangeQaFilm.load_draft(path)
      assert_equal [ { "goto" => "/reports" }, { "click" => "text=Open orders" } ], draft[:steps]
      assert_equal [ "Reports opens", nil ], draft[:checks]
      assert_match(/filtered table/, draft[:acceptance])
    end
  end

  def test_login_steps_follow_a_multi_page_oidc_login
    auth = ChangeLaneBrowserless::AuthConfig.new(
      "steps" => [
        { "url" => "/login", "fields" => [ { "selector" => "#user", "env" => "QA_USER" } ], "submit_selector" => "#next" },
        { "fields" => [ { "selector" => "#pass", "env" => "QA_PASS" } ], "submit_selector" => "#go",
          "wait_for_selector" => "nav" }
      ]
    )
    assert_equal %w[QA_USER QA_PASS], ChangeQaFilm.secret_names(auth)
    compiler = ChangeFlowCompiler.new([ { "goto" => "/reports" } ], base_url: "https://s.test")
    code = ChangeQaFilm.probe_module(compiler, auth: ChangeFlowCompiler.compile_auth(auth.steps, base_url: "https://s.test"),
                                               basic_auth: { "username" => "u", "password" => "p" },
                                               viewport: { "width" => 1280, "height" => 800 })
    assert_includes code, "runAuthStep(session, step)", "probe logs in through the lanes' auth runtime"
    assert_includes code, "page.authenticate"
    assert_includes code, "https://s.test/login"
  end

  def test_an_ungraded_run_whose_steps_all_passed_is_a_pass
    ok = [ { "ok" => true }, { "ok" => true } ]
    assert_equal "pass", ChangeQaFilm.film_status({ "status" => "fail" }, ok, 2)
    assert_equal "fail", ChangeQaFilm.film_status({ "status" => "fail", "acceptance_verdict" => "unclear" }, ok, 2)
    assert_equal "fail", ChangeQaFilm.film_status({ "status" => "fail" }, ok.first(1), 2)
    assert_equal "auth_interrupted", ChangeQaFilm.film_status({ "status" => "auth_interrupted" }, ok, 2)
    assert_equal "fail", ChangeQaFilm.film_status({}, ok, 2)
  end

  def test_opening_goto_keeps_only_the_staging_path
    assert_equal "/app/reports?tab=2", ChangeQaFilm.relative_opening("https://staging.example.test/app/reports?tab=2")
    assert_equal "/", ChangeQaFilm.relative_opening("https://staging.example.test")
  end

  def test_steps_resolve_against_the_staging_origin
    url = "https://staging.example.test:8443/app/reports?tab=2"
    assert_equal "https://staging.example.test:8443", ChangeQaFilm.origin(url)
    compiler = ChangeFlowCompiler.new([ { "goto" => ChangeQaFilm.relative_opening(url) } ], base_url: ChangeQaFilm.origin(url))
    assert_equal url, compiler.compile.first[:url]
  end

  def test_rewrite_status_keeps_the_ungraded_verdict
    Dir.mktmpdir do |dir|
      path = File.join(dir, ChangeTestcasesEvidence::RESULTS_FILE)
      File.write(path, "#{JSON.generate('status' => 'fail', 'acceptance_verdict' => nil)}\n")
      ChangeQaFilm.rewrite_status(dir, "pass")
      row = JSON.parse(File.read(path))
      assert_equal "pass", row["status"]
      assert_nil row["acceptance_verdict"]
    end
  end

  def test_a_cut_off_attempt_reads_its_termination_steps
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "termination.json"), JSON.generate("steps" => [ { "index" => 0, "ok" => true } ]))
      assert_equal [ { "index" => 0, "ok" => true } ], ChangeQaFilm.attempt_steps(dir)
    end
    assert_equal [], ChangeQaFilm.attempt_steps(nil)
  end

  def test_probe_viewport_matches_the_lane_default
    lane = ChangeConfig::LaneConfig.new("testcases", {}, Dir.pwd)
    assert_equal({ "width" => 1440, "height" => 900 }, ChangeQaFilm.lane_viewport(lane))
    narrow = ChangeConfig::LaneConfig.new("testcases", { "viewport" => { "width" => 390 } }, Dir.pwd)
    assert_equal({ "width" => 390, "height" => 900 }, ChangeQaFilm.lane_viewport(narrow))
  end

  def test_probe_budget_covers_the_login_and_every_draft_step
    auth = ChangeLaneBrowserless::AuthConfig.new(
      "steps" => [ { "url" => "/a", "timeout_ms" => 60_000 }, { "url" => "/b", "timeout_ms" => 60_000 } ]
    )
    compiler = ChangeFlowCompiler.new([ { "goto" => "/r" }, { "click" => "#x" } ], base_url: "https://s.test", timeout_ms: 30_000)
    assert_equal 130_000 + 65_000, ChangeQaFilm.probe_budget_ms(auth, compiler)
    short = ChangeFlowCompiler.new([ { "goto" => "/" } ], base_url: "https://s.test", timeout_ms: 1_000)
    assert_equal ChangeDocker::Browserless::FUNCTION_TIMEOUT_MS, ChangeQaFilm.probe_budget_ms(nil, short)
  end

  def test_probe_step_timeout_matches_the_filming_lane
    assert_equal ChangeLaneTestcases::DEFAULT_TIMEOUT_MS,
                 ChangeQaFilm.step_timeout_ms(ChangeConfig::LaneConfig.new("testcases", {}, Dir.pwd))
    slow = ChangeConfig::LaneConfig.new("testcases", { "timeout_ms" => 45_000 }, Dir.pwd)
    assert_equal 45_000, ChangeQaFilm.step_timeout_ms(slow)
  end

  def test_an_omitted_persona_is_anonymous
    assert_equal "anonymous", ChangeQaFilm.parse(%w[--url https://x.test])[:persona]
  end

  def test_secrets_come_from_env_then_the_store_and_report_what_is_missing
    env = { "QA_USER" => "set" }
    store = FakeStore.new({ "QA_PASS" => "from-store\n" })
    missing = ChangeQaFilm.resolve_secrets(%w[QA_USER QA_PASS QA_OTP], env: env, store: store)
    assert_equal %w[QA_OTP], missing
    assert_equal "from-store", env["QA_PASS"]
    assert_equal "set", env["QA_USER"]
  end

  def draft(steps, checks)
    { steps: steps, checks: checks, acceptance: "Counts match." }
  end

  def test_selector_flag_runs_on_the_opening_page
    flag = ChangeQaFilm.flag_steps(flag: "f", selector: "#nav")
    entries = ChangeQaFilm.plan(draft([ { "click" => "#a" } ], [ nil ]), flag, "https://staging.example.test", probe: false)
    assert_equal [ { "goto" => "/" }, { "expect_visible" => "#nav" }, { "click" => "#a" } ],
                 entries.map { |entry| entry[:step] }
    assert_equal [ false, true, false ], entries.map { |entry| entry[:flag] }
    assert_equal "Open the page", entries.first[:check]
  end

  def test_probe_flag_runs_before_the_draft_opens_its_page
    flag = ChangeQaFilm.flag_steps(flag: "f", probe: "/flags/{flag}")
    entries = ChangeQaFilm.plan(draft([ { "goto" => "/reports" } ], [ "Open Reports" ]), flag, "https://s.test", probe: true)
    assert_equal [ { "goto" => "/flags/f" }, { "expect_text" => { "selector" => "body", "contains" => "true" } },
                   { "goto" => "/reports" } ], entries.map { |entry| entry[:step] }
  end

  def test_checklist_marks_the_flag_each_step_and_the_acceptance
    flag = ChangeQaFilm.flag_steps(flag: "new-reports", selector: "#nav")
    entries = ChangeQaFilm.plan(draft([ { "goto" => "/reports" }, { "expect_visible" => ".chip" } ], [ "Open Reports", nil ]),
                                flag, "https://s.test", probe: false)
    results = [ { "index" => 0, "ok" => true }, { "index" => 1, "ok" => true },
                { "index" => 2, "ok" => false, "error" => "not visible" } ]
    text = ChangeQaFilm.checklist(entries: entries, labels: [ "goto /reports", "flag", "expect_visible .chip" ],
                                  results: results, flag: "new-reports", acceptance: "Counts match.",
                                  verdict: "pass", status: "fail")
    assert_match(/UAT checklist: FAIL/, text)
    assert_match(/\[x\] PASS: Flag `new-reports` is on/, text)
    assert_match(/\[x\] PASS: Open Reports/, text)
    assert_match(/\[ \] FAIL: expect_visible \.chip \(not visible\)/, text)
    assert_match(/PASS: Acceptance: Counts match\./, text)
  end

  def test_saved_suite_is_named_after_its_file
    assert_equal "reports", ChangeQaFilm.suite_id("qa/reports.cf-testcases.yml")
  end

  def test_snapshot_compiles_as_an_eval_step
    compiler = ChangeFlowCompiler.new([ { "eval" => { "script" => ChangeQaFilm::SNAPSHOT_JS } } ], base_url: "https://staging.example.test")
    assert compiler.uses_eval?
    refute_match(/\.value\b/, ChangeQaFilm::SNAPSHOT_JS, "the snapshot must never read input values")
    assert_includes ChangeQaFilm::SNAPSHOT_JS, '[aria-label="', "a labelled control gets an attribute selector"
    assert_includes(ChangeQaFilm::SNAPSHOT_JS, "const name = clean(el.innerText);", ":has-text is for visible text only")
  end

  def test_probe_view_hides_login_steps_and_lifts_the_snapshot
    result = { "login" => "ok", "steps" => [
      { "index" => 0, "label" => "goto /reports", "ok" => true },
      { "index" => 1, "label" => "eval", "ok" => true, "raw" => true, "value" => { "title" => "Reports" } }
    ] }
    view = ChangeQaFilm.probe_view(result)
    assert_equal "ok", view[:login]
    assert_equal [ 0 ], view[:steps].map { |step| step["index"] }
    assert_equal "Reports", view[:snapshot]["title"]
  end

  def test_parse_requires_a_url_and_rejects_unknown_flags
    assert_raises(ArgumentError) { ChangeQaFilm.parse(%w[--persona analyst]) }
    assert_raises(ArgumentError) { ChangeQaFilm.parse(%w[--url https://x.test --bogus 1]) }
    assert_equal "analyst", ChangeQaFilm.parse(%w[--url https://x.test --persona analyst])[:persona]
  end

  def test_unknown_persona_is_refused_before_any_browser_starts
    Dir.mktmpdir do |dir|
      change_md = File.join(dir, "CHANGE.md")
      File.write(change_md, <<~MD)
        ---
        change_schema_version: #{ChangeSchema::VERSION}
        change_config:
          project: demo
          lanes:
            testcases:
              enabled: true
              personas:
                analyst:
                  login_url: /login
                  email_env: QA_USER
                  password_env: QA_PASS
        ---
      MD
      _out, err = capture_io do
        assert_equal 1, ChangeQaFilm.main(%W[probe --url https://staging.example.test --persona ghost --change-md #{change_md}])
      end
      assert_match(/persona 'ghost' is not defined/, err)
    end
  end

  def test_summary_writes_the_checklist_from_the_run_records
    Dir.mktmpdir do |dir|
      attempt = File.join(dir, "cases", "film", "a", "attempt-1")
      FileUtils.mkdir_p(attempt)
      File.write(File.join(attempt, "result.json"),
                 JSON.generate("steps" => [ { "index" => 0, "ok" => true }, { "index" => 1, "ok" => true } ]))
      File.write(File.join(dir, ChangeTestcasesEvidence::RESULTS_FILE),
                 "#{JSON.generate('status' => 'pass', 'evidence_dir' => attempt, 'acceptance_verdict' => 'pass')}\n")
      File.write(File.join(dir, "exports.json"), JSON.generate("video" => { "film/a" => { "status" => "ok", "path" => "/x/out.mp4" } }))
      options = { url: "https://staging.example.test", flag: "new-reports", flag_selector: "#reports" }
      flag = ChangeQaFilm.flag_steps(flag: "new-reports", selector: "#reports")
      entries = ChangeQaFilm.plan(draft([ { "goto" => "/reports" } ], [ "Reports opens" ]), flag, options[:url], probe: false)
      summary = ChangeQaFilm.summarize(dir, options, entries, "Reports load.")
      assert_equal "pass", summary[:status]
      assert_equal "/x/out.mp4", summary[:video]
      assert_match(/PASS: Reports opens/, File.read(summary[:checklist]))
    end
  end
end
