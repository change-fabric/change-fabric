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
end
