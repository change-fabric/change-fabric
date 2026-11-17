# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_config"
require_relative "../scripts/change_lane_zap"

# The zap lane's own #targets must delegate to ChangeConfig::LaneConfig#targets
# rather than resolve the list itself, so the lane and `doctor`'s resolved
# -target report can never disagree about what a scan is actually about to hit.
class ChangeLaneZapTargetsTest < Minitest::Test
  Ctx = Struct.new(:network, :target_url, :health_url) do
    def browserless = nil
    def log(_message) = nil
  end

  def lane(config_hash, target_url: "http://app:3000")
    config = ChangeConfig::LaneConfig.new("zap", config_hash, "/repo")
    ChangeLaneZap.new(config, Ctx.new("net", target_url))
  end

  def test_targets_delegates_to_the_config
    zap = lane({ "targets" => [ "/admin" ] }, target_url: "http://app:3000")
    assert_equal [ "http://app:3000/admin" ], zap.send(:targets)
  end

  def test_absent_targets_defaults_to_the_context_target_url
    zap = lane({}, target_url: "http://app:3000")
    assert_equal [ "http://app:3000" ], zap.send(:targets)
  end

  def test_mode_defaults_to_baseline
    assert_equal "baseline", lane({}).mode
  end

  # An active scan is refused before any container starts: the lane returns
  # one failing finding and never reaches ChangeDocker.run.
  def test_full_mode_is_refused_without_a_docker_call
    zap = lane({ "mode" => "full" })
    called = false
    original = ChangeDocker.method(:run)
    ChangeDocker.define_singleton_method(:run) { |**| called = true }
    findings = zap.run
    assert_equal 1, findings.size
    assert_equal "fail", findings.first.status
    assert_match(/refused mode 'full'/, findings.first.detail)
    refute called, "an active scan must never reach docker here"
  ensure
    ChangeDocker.define_singleton_method(:run, original) if original
  end
end
