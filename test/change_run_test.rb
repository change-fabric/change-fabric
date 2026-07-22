# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../scripts/change_run"

# The dogfooding fix: a boot or health failure used to abort with nothing but
# the command line, hiding the one line of output that names the real cause.
# These exercise that the captured subprocess output actually reaches the
# abort message, via the same private methods change_run.rb's own flow calls.
class ChangeRunTest < Minitest::Test
  def runner = ChangeRun.new(%w[all])

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  Boot = Struct.new(:up, :down, :health_url, :health_status, :health_timeout, :network, :target_url) do
    def up? = !up.to_s.empty?
    def env_files = []
  end

  def test_boot_up_surfaces_captured_output_on_failure
    boot = Boot.new("sh -c 'echo BOOM 1>&2; exit 1'")
    output = capture_stderr { assert_raises(SystemExit) { runner.send(:boot_up, boot) } }
    assert_match(/BOOM/, output)
    assert_match(/boot command failed/, output)
  end

  def test_wait_healthy_surfaces_curl_output_on_timeout
    boot = Boot.new(nil, nil, "http://127.0.0.1:1/nope", 200, 0)
    output = capture_stderr { assert_raises(SystemExit) { runner.send(:wait_healthy, boot) } }
    assert_match(/never became healthy/, output)
    assert_match(/last health check output/, output)
  end

  def test_sweep_scope_is_a_valid_argument
    assert_equal [ "sweep", ChangeConfig::DEFAULT_PATH, nil ], runner.send(:parse_args, %w[sweep])
  end

  def test_profile_flag_is_parsed
    assert_equal [ "all", ChangeConfig::DEFAULT_PATH, "staging" ],
                 runner.send(:parse_args, %w[all --profile staging])
  end

  # boot.env_file: the compose build-arg trap fix. A KEY=VALUE file gets parsed
  # (not shell-sourced) and reaches the boot subprocess environment.
  def test_boot_up_sources_env_file_into_the_subprocess
    Dir.mktmpdir do |dir|
      env_path = File.join(dir, ".env.local")
      File.write(env_path, "export FOO=bar\n# a comment\n\nQUOTED=\"baz\"\n")
      out_path = File.join(dir, "out.txt")
      boot = Boot.new("sh -c 'echo $FOO-$QUOTED > #{out_path}'")
      boot.define_singleton_method(:env_files) { [ env_path ] }

      capture_stderr { runner.send(:boot_up, boot) }

      assert_equal "bar-baz\n", File.read(out_path)
    end
  end

  def test_boot_up_fails_fast_on_a_missing_env_file
    boot = Boot.new("true")
    boot.define_singleton_method(:env_files) { [ "/no/such/.env.local" ] }
    output = capture_stderr { assert_raises(SystemExit) { runner.send(:boot_up, boot) } }
    assert_match(%r{boot\.env_file not found: /no/such/\.env\.local}, output)
  end
end
