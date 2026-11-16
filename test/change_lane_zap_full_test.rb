# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_zap"

# The active (full) zap scan: zap-full-scan.py in the pinned image, in a --rm
# cf-change-* container, and only when the run context carries the opt-in.
class ChangeLaneZapFullTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url, :health_url, :active_scan_allowed) do
    def log(_message) = nil
  end

  Status = Struct.new(:exitstatus)

  def lane(mode:, allowed:)
    config = ChangeConfig::LaneConfig.new("zap", { "mode" => mode }, "/repo")
    ChangeLaneZap.new(config, Ctx.new("cf-change-net", "http://app:3000", nil, allowed))
  end

  def capture_runs
    calls = []
    original = ChangeDocker.method(:run)
    ChangeDocker.define_singleton_method(:run) do |**kwargs|
      calls << kwargs
      [ "", Status.new(0) ]
    end
    yield
    calls
  ensure
    ChangeDocker.define_singleton_method(:run, original)
  end

  def test_full_mode_runs_zap_full_scan_when_allowed
    calls = capture_runs { lane(mode: "full", allowed: true).run }
    assert_equal 1, calls.size
    assert_equal "zap-full-scan.py", calls.first[:args].first
    assert_equal ChangeDocker::ZAP_IMAGE, calls.first[:image]
    assert_match(/\Acf-change-zap-/, calls.first[:name])
  end

  def test_the_full_scan_container_is_removed_and_prefixed
    calls = capture_runs { lane(mode: "full", allowed: true).run }
    argv = ChangeDocker.send(:run_command, network: "cf-change-net", image: calls.first[:image],
                                           args: calls.first[:args], env: {}, mounts: calls.first[:mounts],
                                           name: calls.first[:name], user: nil, workdir: nil, entrypoint: nil,
                                           inline_env: false)
    assert_includes argv, "--rm"
    assert_includes argv, "zap-full-scan.py"
    assert(argv.any? { |arg| arg.to_s.start_with?("cf-change-zap-") })
  end

  def test_full_mode_without_the_context_opt_in_never_reaches_docker
    calls = capture_runs do
      findings = lane(mode: "full", allowed: false).run
      assert_equal "fail", findings.first.status
    end
    assert_empty calls
  end

  def test_baseline_still_runs_zap_baseline
    calls = capture_runs { lane(mode: "baseline", allowed: false).run }
    assert_equal "zap-baseline.py", calls.first[:args].first
  end

  def test_an_unknown_mode_is_refused_even_with_the_opt_in
    calls = capture_runs { lane(mode: "aggressive", allowed: true).run }
    assert_empty calls
  end
end
