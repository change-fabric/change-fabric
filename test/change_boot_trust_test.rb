# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/change_boot"
require_relative "../scripts/change_process"

# boot.up and boot.down under 0.17.0: they run only when trusted, with the
# minimal declared environment, under boot.timeout_seconds, and with declared
# values masked in any output that reaches a log line. A fake runner stands in
# for ChangeProcess, so nothing here spawns a shell.
class ChangeBootTrustTest < Minitest::Test
  Aborted = Class.new(StandardError)

  Boot = Struct.new(:up, :down, :env_names, :env_file_entries, :timeout_seconds, :target_url, :health_url,
                    keyword_init: true) do
    def up? = !up.to_s.empty?
  end

  Verdict = Struct.new(:trusted) do
    def trusted?(step) = trusted.include?(step)
    def refusal(step) = "refusing to run #{step}: its definition differs from origin/main"
  end

  class FakeRunner
    attr_reader :calls

    def initialize(result) = (@result = result) && (@calls = [])

    def run(cmd, env:, chdir:, timeout: nil)
      @calls << { cmd: cmd, env: env, chdir: chdir, timeout: timeout }
      @result
    end
  end

  class Host
    include ChangeBoot

    attr_reader :logs

    def initialize(runner) = (@runner = runner) && (@logs = [])
    def repo_root = Dir.tmpdir
    def log(message) = @logs << message
    def abort_and_exit(message) = raise(Aborted, message)
    def boot_runner = @runner
    def boot_run_id = "run-1"
  end

  OK = ChangeProcess::Result.new(status: :pass, exit_code: 0, output: "", timed_out: false, duration: 0.1)

  def boot(**fields)
    Boot.new(up: "bin/up", down: "bin/down", env_names: [], env_file_entries: [], timeout_seconds: nil,
             target_url: "http://app", health_url: "http://app/health", **fields)
  end

  def all_trusted = Verdict.new(%w[boot.up boot.down])

  def test_untrusted_boot_up_aborts_before_running
    runner = FakeRunner.new(OK)
    error = assert_raises(Aborted) { Host.new(runner).boot_up(boot, trust: Verdict.new([])) }
    assert_match(/refusing to run boot\.up/, error.message)
    assert_empty runner.calls
  end

  def test_untrusted_boot_down_is_logged_and_skipped
    runner = FakeRunner.new(OK)
    host = Host.new(runner)
    host.boot_down(boot, trust: Verdict.new(%w[boot.up]))
    assert_empty runner.calls
    assert_match(/refusing to run boot\.down/, host.logs.join)
  end

  def test_app_prefix_names_the_step
    runner = FakeRunner.new(OK)
    Host.new(runner).boot_up(boot, trust: Verdict.new(%w[portal/boot.up]), prefix: "portal/")
    assert_equal 1, runner.calls.size
  end

  def test_runs_with_only_the_minimal_and_declared_environment
    ENV["CF_BOOT_TEST_DECLARED"] = "declared-value"
    ENV["CF_BOOT_TEST_SECRET"] = "not-declared"
    runner = FakeRunner.new(OK)
    Host.new(runner).boot_up(boot(env_names: %w[CF_BOOT_TEST_DECLARED], timeout_seconds: 60), trust: all_trusted)
    call = runner.calls.first
    assert_equal "declared-value", call[:env]["CF_BOOT_TEST_DECLARED"]
    refute call[:env].key?("CF_BOOT_TEST_SECRET")
    assert_equal "run-1", call[:env]["CF_CHANGE_RUN_ID"]
    assert_equal "http://app", call[:env]["CF_CHANGE_TARGET_URL"]
    assert_equal "http://app/health", call[:env]["CF_CHANGE_HEALTH_URL"]
    assert_equal 60, call[:timeout]
  ensure
    ENV.delete("CF_BOOT_TEST_DECLARED")
    ENV.delete("CF_BOOT_TEST_SECRET")
  end

  def test_missing_declared_variables_abort_naming_every_one
    error = assert_raises(Aborted) do
      Host.new(FakeRunner.new(OK)).boot_up(boot(env_names: %w[CF_NOPE_A CF_NOPE_B]), trust: all_trusted)
    end
    assert_equal "boot.env declares variables that are not set: CF_NOPE_A, CF_NOPE_B " \
                 "(set them in the environment or in boot.env_file)", error.message
  end

  def test_env_file_supplies_declared_values_only
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".env.local"), "CF_FILE_A=from-file\nCF_FILE_B=undeclared\n")
      runner = FakeRunner.new(OK)
      Host.new(runner).boot_up(boot(env_names: %w[CF_FILE_A], env_file_entries: [ ".env.local" ]),
                               trust: all_trusted, chdir: dir)
      env = runner.calls.first[:env]
      assert_equal "from-file", env["CF_FILE_A"]
      refute env.key?("CF_FILE_B")
      assert_equal dir, runner.calls.first[:chdir]
    end
  end

  def test_failure_output_is_masked
    ENV["CF_BOOT_TEST_TOKEN"] = "super-secret-token"
    failed = ChangeProcess::Result.new(status: :fail, exit_code: 1, output: "auth super-secret-token rejected\n",
                                       timed_out: false, duration: 1.0)
    error = assert_raises(Aborted) do
      Host.new(FakeRunner.new(failed)).boot_up(boot(env_names: %w[CF_BOOT_TEST_TOKEN]), trust: all_trusted)
    end
    assert_match(/boot command failed/, error.message)
    assert_match(/\*\*\*CF_BOOT_TEST_TOKEN\*\*\*/, error.message)
    refute_match(/super-secret-token/, error.message)
  ensure
    ENV.delete("CF_BOOT_TEST_TOKEN")
  end

  def test_timeout_is_named
    timed_out = ChangeProcess::Result.new(status: :fail, exit_code: nil, output: "", timed_out: true, duration: 5.0)
    error = assert_raises(Aborted) do
      Host.new(FakeRunner.new(timed_out)).boot_up(boot(timeout_seconds: 5), trust: all_trusted)
    end
    assert_match(/timed out after 5s; process group killed/, error.message)
  end

  def test_missing_variable_on_teardown_only_logs
    host = Host.new(FakeRunner.new(OK))
    host.boot_down(boot(env_names: %w[CF_NOPE_C]), trust: all_trusted)
    assert_match(/teardown skipped: boot\.env declares variables that are not set: CF_NOPE_C/, host.logs.join)
  end
end
