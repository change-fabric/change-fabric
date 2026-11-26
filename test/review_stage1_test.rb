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

    def call(command, root, _timeout)
      @calls << command
      case command
      when /eslint \./ then eslint(root)
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
  def test_missing_eslint_config_is_unavailable_not_passed
    dir = copy_fixture("js_var")
    File.delete(File.join(dir, "eslint.config.mjs"))
    row = result(run_stage1(dir), "javascript")
    assert_equal "unavailable", row.status
    assert_includes row.detail, "no-var"
    assert_includes row.detail, "eqeqeq"
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

  def test_each_status_is_one_of_the_five
    report = run_stage1(copy_fixture("js_var"))
    assert_empty report.results.map(&:status) - ReviewStage1::STATUSES
    assert_equal %w[failed unavailable timed_out], ReviewStage1::BLOCKING
  end

  def command_lane(run, timeout: nil)
    extra = timeout ? "\n        timeout_seconds: #{timeout}" : ""
    "---\nchange_config:\n  lanes:\n    command:\n      enabled: true\n      commands:\n      - name: unit\n        run: #{run}#{extra}\n---\nbody\n"
  end

  def test_a_real_subprocess_timeout_is_reported
    dir = tmpdir
    File.write(File.join(dir, "CHANGE.md"), command_lane("sleep 30"))
    row = ReviewStage1.run(dir, timeout: 1).results.find { |r| r.id.start_with?("tests") }
    assert_equal "timed_out", row.status
    assert_equal "sleep 30", row.command
  end

  # Test command resolution: the command lane first, then a manifest.
  def test_the_command_lane_supplies_the_test_command
    dir = tmpdir
    File.write(File.join(dir, "CHANGE.md"), command_lane("make check", timeout: 42))
    File.write(File.join(dir, "package.json"), '{ "scripts": { "test": "vitest" } }')
    tools = Tools.new
    ReviewStage1.run(dir, runner: tools)
    assert_includes tools.calls, "make check"
    refute_includes tools.calls, "npm test", "the lane wins over a manifest"
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
    File.write(File.join(dir, "CHANGE.md"), command_lane("make check"))
    failing = lambda do |command, _root, _timeout|
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
end
