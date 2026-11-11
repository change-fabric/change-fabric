# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/change_process"

# The shared host-step runner: exact environment, merged output, exit code,
# and a timeout that takes the whole process group down with it.
class ChangeProcessTest < Minitest::Test
  ENV_MIN = { "PATH" => "/usr/bin:/bin" }.freeze

  def setup
    skip "/bin/sh is not available" unless File.executable?("/bin/sh")
  end

  def test_captures_merged_output_and_exit_code
    result = ChangeProcess.run("echo out; echo err 1>&2; exit 3", env: ENV_MIN, chdir: Dir.tmpdir)
    assert_equal :fail, result.status
    assert_equal 3, result.exit_code
    assert_includes result.output, "out"
    assert_includes result.output, "err"
    refute result.timed_out
  end

  def test_runs_with_only_the_given_environment
    ENV["CF_PROCESS_TEST_LEAK"] = "leaked"
    result = ChangeProcess.run('echo "[$CF_PROCESS_TEST_LEAK][$ONLY]"', env: ENV_MIN.merge("ONLY" => "yes"), chdir: Dir.tmpdir)
    assert_equal :pass, result.status
    assert_includes result.output, "[][yes]"
  ensure
    ENV.delete("CF_PROCESS_TEST_LEAK")
  end

  def test_timeout_kills_the_whole_process_group
    result = ChangeProcess.run("sleep 30 & echo $!; sleep 30", env: ENV_MIN, chdir: Dir.tmpdir, timeout: 1, grace: 1)
    assert result.timed_out
    assert_equal :fail, result.status
    child = result.output.lines.first.to_i
    assert child.positive?
    deadline = Time.now + 5
    sleep 0.1 while alive?(child) && Time.now < deadline
    refute alive?(child), "background child #{child} survived the group kill"
  end

  def test_normal_exit_does_not_wait_for_a_background_child_holding_the_pipe
    started = Time.now
    result = ChangeProcess.run("sleep 30 & echo $!", env: ENV_MIN, chdir: Dir.tmpdir, timeout: 20)
    assert_equal :pass, result.status
    assert_operator Time.now - started, :<, 10
  ensure
    child = result&.output.to_s.to_i
    Process.kill("KILL", child) if child&.positive? && alive?(child)
  end

  private

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
