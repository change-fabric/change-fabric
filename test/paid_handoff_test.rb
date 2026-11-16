# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "enroll_helpers"

# The paid-step handoff cf:enroll's SKILL.md describes, end to end against a
# real stub paid command: exit 4 with one cf_enroll line, that line handed to
# cf:enroll byte for byte, `cf_keys.rb status` read after the user enrolls,
# and the paid step re-run exactly once. A second exit 4 stops; never a
# third run. Uses a temp HOME and fake keys only.
class PaidHandoffTest < Minitest::Test
  include EnrollHelpers

  SCRIPTS = File.expand_path("../scripts", __dir__)
  STUB = <<~RUBY
    require #{File.join(SCRIPTS, 'walkthrough_env').inspect}
    begin
      WalkthroughEnv.openai_key!
      puts "paid step ok"
    rescue WalkthroughEnv::NeedsEnrollment => e
      WalkthroughEnv.enroll_exit!(e)
    end
  RUBY

  def setup
    @project = File.realpath(Dir.mktmpdir)
    @runs = 0
  end

  def teardown = FileUtils.remove_entry(@project)

  def env = { "HOME" => ENV.fetch("HOME") }

  def run_stub
    @runs += 1
    out, _err, status = Open3.capture3(env, RbConfig.ruby, "-e", STUB, chdir: @project)
    [ out, status.exitstatus ]
  end

  def status_text
    out, _err, = Open3.capture3(env, RbConfig.ruby, File.join(SCRIPTS, "cf_keys.rb"), "status", "--dir", @project)
    out
  end

  # The caller side of the protocol. `enroll` stands in for cf:enroll and the
  # user: it receives the cf_enroll line and returns once the user is done.
  def handoff(enroll)
    out, code = run_stub
    @first_out = out
    return [ out, code ] unless code == 4

    line = out.lines.find { |l| l.start_with?('{"cf_enroll"') }
    enroll.call(line)
    @status = status_text
    run_stub
  end

  def test_exit_4_line_passes_verbatim_then_one_rerun_succeeds
    with_enrolled do
      received = nil
      out, code = handoff(lambda do |line|
        received = line
        write_fake_keys([ "openai" ], @project)
      end)
      assert_equal 0, code
      assert_equal "paid step ok\n", out
      assert_equal 2, @runs
      assert_match(/openai: enrolled/, @status)
      assert_equal @first_out.lines.find { |l| l.include?("cf_enroll") }, received, "the handoff must pass the cf_enroll line byte for byte"
      assert_equal 1, enroll_lines(@first_out).size
      assert_equal "openai", JSON.parse(received).dig("cf_enroll", "provider")
    end
  end

  def test_second_exit_4_stops_without_a_third_run
    with_enrolled do
      out, code = handoff(->(_line) { })
      assert_equal 4, code
      assert_equal 2, @runs
      assert_match(/openai: missing/, @status)
      assert_equal 1, enroll_lines(out).size
    end
  end
end
